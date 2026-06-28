import SwiftUI
import UniformTypeIdentifiers

struct FileTransferView: View {
    @Binding var profile: HostProfile

    struct LocalEntry: Identifiable, Equatable {
        let name: String
        let isDirectory: Bool
        let path: String
        let size: Int64
        var id: String { path }
    }

    @State private var localDir = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var localEntries: [LocalEntry] = []
    @State private var localSel = Set<String>()

    @State private var remoteDir = ""
    @State private var remoteEntries: [RemoteEntry] = []
    @State private var remoteSel = Set<String>()
    @State private var remoteError: String?

    @State private var busy = false
    @State private var status = ""
    @State private var statusIsError = false
    @State private var remoteLoadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                localPane
                Divider()
                transferControls
                Divider()
                remotePane
            }
            Divider()
            statusBar
        }
        .onAppear {
            if remoteDir.isEmpty {
                if !profile.lastRemoteDir.isEmpty {
                    remoteDir = profile.lastRemoteDir
                } else {
                    resolveRemoteHome()
                }
            }
            loadLocal()
            if !remoteDir.isEmpty { loadRemote() }
        }
    }

    // MARK: Local pane

    private var localPane: some View {
        VStack(spacing: 0) {
            paneHeader(
                title: "This Mac",
                path: localDir,
                onUp: { navigateLocal(to: (localDir as NSString).deletingLastPathComponent) },
                onHome: { navigateLocal(to: FileManager.default.homeDirectoryForCurrentUser.path) },
                onReload: loadLocal
            )
            List(selection: $localSel) {
                ForEach(localEntries) { entry in
                    fileRow(name: entry.name, isDir: entry.isDirectory, size: entry.size)
                        .tag(entry.path)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if entry.isDirectory { navigateLocal(to: entry.path) }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Remote pane

    private var remotePane: some View {
        VStack(spacing: 0) {
            paneHeader(
                title: profile.displayName,
                path: remoteDir,
                onUp: { navigateRemote(to: parentPath(remoteDir)) },
                onHome: { navigateRemote(to: remoteHomeFallback()) },
                onReload: loadRemote
            )
            if let remoteError {
                ContentUnavailableView {
                    Label("Can't list folder", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(remoteError).font(.caption)
                } actions: {
                    Button("Retry") { loadRemote() }
                }
            } else {
                List(selection: $remoteSel) {
                    ForEach(remoteEntries) { entry in
                        fileRow(name: entry.name, isDir: entry.isDirectory, size: entry.size)
                            .tag(entry.name)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                if entry.isDirectory { navigateRemote(to: joinPath(remoteDir, entry.name)) }
                            }
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers); return true
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Middle controls

    private var transferControls: some View {
        VStack(spacing: 16) {
            Spacer()
            Button {
                push()
            } label: {
                Image(systemName: "arrow.right.circle.fill").font(.title)
            }
            .help("Push selected → \(profile.displayName)")
            .disabled(localSel.isEmpty || busy)

            Button {
                pull()
            } label: {
                Image(systemName: "arrow.left.circle.fill").font(.title)
            }
            .help("Pull selected → this Mac")
            .disabled(remoteSel.isEmpty || busy)

            if busy { ProgressView().controlSize(.small) }
            Spacer()
        }
        .buttonStyle(.plain)
        .frame(width: 60)
        .padding(.horizontal, 4)
    }

    private var statusBar: some View {
        HStack {
            if !status.isEmpty {
                Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(statusIsError ? .orange : .green)
                Text(status).font(.caption).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Drag files onto the remote pane, or select and use the arrows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    // MARK: Reusable subviews

    private func paneHeader(title: String, path: String, onUp: @escaping () -> Void,
                            onHome: @escaping () -> Void, onReload: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(action: onHome) { Image(systemName: "house") }.help("Home")
                Button(action: onUp) { Image(systemName: "arrow.up") }.help("Parent folder")
                Button(action: onReload) { Image(systemName: "arrow.clockwise") }.help("Reload")
            }
            .buttonStyle(.borderless)
            Text(path).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
    }

    private func fileRow(name: String, isDir: Bool, size: Int64) -> some View {
        HStack {
            Image(systemName: isDir ? "folder.fill" : "doc")
                .foregroundStyle(isDir ? Color.accentColor : .secondary)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer()
            if !isDir {
                Text(byteString(size)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Local FS

    private func navigateLocal(to path: String) {
        guard !path.isEmpty else { return }
        localDir = path
        localSel.removeAll()
        loadLocal()
    }

    private func loadLocal() {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: localDir)
        guard let items = try? fm.contentsOfDirectory(at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else {
            localEntries = []; return
        }
        localEntries = items.map { u in
            let vals = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return LocalEntry(name: u.lastPathComponent,
                              isDirectory: vals?.isDirectory ?? false,
                              path: u.path,
                              size: Int64(vals?.fileSize ?? 0))
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    // MARK: Remote FS

    private func remoteHomeFallback() -> String {
        if remoteDir.hasPrefix("/home/") || remoteDir.hasPrefix("/Users/") {
            return remoteDir.split(separator: "/").prefix(3).joined(separator: "/")
        }
        return "/home/\(profile.sshUsername)"
    }

    private func resolveRemoteHome() {
        let p = profile
        Task.detached(priority: .userInitiated) {
            let home = SFTPService.remoteHomeDirectory(p)
            await MainActor.run {
                remoteDir = home ?? "/home/\(p.sshUsername)"
                loadRemote()
            }
        }
    }

    private func navigateRemote(to path: String) {
        remoteDir = path
        remoteSel.removeAll()
        profile.lastRemoteDir = path
        loadRemote()
    }

    private func loadRemote() {
        remoteLoadTask?.cancel()
        busy = true
        remoteError = nil
        let p = profile
        let dir = remoteDir
        remoteLoadTask = Task {
            let result = SFTPService.listRemote(p, path: dir)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                busy = false
                switch result {
                case .success(let entries): remoteEntries = entries; remoteError = nil
                case .failure(let err):      remoteEntries = []; remoteError = err.message
                }
            }
        }
    }

    // MARK: Transfers

    private func push() {
        let paths = Array(localSel)
        guard !paths.isEmpty else { return }
        runTransfer { SFTPService.push(profile, localPaths: paths, remoteDir: remoteDir) } onDone: {
            loadRemote()
        }
    }

    private func pull() {
        let paths = remoteSel.map { joinPath(remoteDir, $0) }
        guard !paths.isEmpty else { return }
        runTransfer { SFTPService.pull(profile, remotePaths: paths, localDir: localDir) } onDone: {
            loadLocal()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [String] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); paths.append(url.path); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !paths.isEmpty else { return }
            runTransfer { SFTPService.push(profile, localPaths: paths, remoteDir: remoteDir) } onDone: {
                loadRemote()
            }
        }
    }

    private func runTransfer(_ work: @escaping () -> Result<String, AppError>,
                             onDone: @escaping () -> Void) {
        busy = true
        status = "Transferring…"
        statusIsError = false
        Task.detached(priority: .userInitiated) {
            let result = work()
            await MainActor.run {
                busy = false
                switch result {
                case .success(let msg): status = msg; statusIsError = false; onDone()
                case .failure(let err): status = err.message; statusIsError = true
                }
            }
        }
    }

    // MARK: Helpers

    private func parentPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func joinPath(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
