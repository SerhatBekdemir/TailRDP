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
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], stdin: String? = nil) -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args

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
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return ProcessResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: proc.terminationStatus
        )
    }
}
