import Foundation

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var ok: Bool { exitCode == 0 }
}

/// Blocking process execution with captured output and optional stdin.
/// Call off the main thread for anything network-bound (ssh/scp/tailscale).
enum ProcessRunner {
    /// macOS GUI apps inherit a sparse environment (often no SHLVL/TERM).
    /// Some CLIs — notably `/Applications/Tailscale.app/.../Tailscale` — fail
    /// without a shell-like environment and print errors to stdout instead of JSON.
    static func cliEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["SHLVL"] == nil { env["SHLVL"] = "1" }
        if env["TERM"] == nil { env["TERM"] = "dumb" }
        if env["TMPDIR"] == nil {
            env["TMPDIR"] = FileManager.default.temporaryDirectory.path
        }
        return env
    }

    /// Without SIG_IGN, writing stdin to a child that exited before reading kills
    /// the whole app with SIGPIPE. Ignored disposition is not inherited by children
    /// (posix_spawn resets to default). With it ignored, the write throws EPIPE instead.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    @discardableResult
    static func run(_ launchPath: String, _ args: [String], stdin: String? = nil) -> ProcessResult {
        _ = ignoreSIGPIPE
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        proc.environment = cliEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        var inPipe: Pipe?
        if stdin != nil {
            inPipe = Pipe()
            proc.standardInput = inPipe
        }

        do { try proc.run() } catch {
            return ProcessResult(stdout: "", stderr: "launch failed: \(error.localizedDescription)", exitCode: -1)
        }

        if let stdin, let inPipe {
            // Throwing API: EPIPE from a fast-exiting child must not raise NSException.
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain both pipes concurrently — sequential reads deadlock if the
        // child fills the stderr pipe buffer while stdout is still open.
        var outData = Data()
        let outDone = DispatchSemaphore(value: 0)
        let outHandle = outPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            outData = outHandle.readDataToEndOfFile()
            outDone.signal()
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        outDone.wait()
        proc.waitUntilExit()

        return ProcessResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: proc.terminationStatus
        )
    }
}
