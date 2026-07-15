import Foundation

struct CommandResult {
    let exit: Int32
    let out: String
    let err: String
}

enum ShellRunner {
    static let safePath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    @discardableResult
    static func run(_ launchPath: String, _ args: [String], stdinNull: Bool = false, timeout: TimeInterval? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = safePath
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if stdinNull { process.standardInput = FileHandle.nullDevice }

        do {
            try process.run()
        } catch {
            NSLog("Sleepless: failed to launch %@: %@", launchPath, error.localizedDescription)
            return CommandResult(exit: -1, out: "", err: "launch failed: \(error.localizedDescription)")
        }

        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            exit: process.terminationStatus,
            out: String(data: outData, encoding: .utf8) ?? "",
            err: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    @discardableResult
    static func capture(_ launchPath: String, _ args: [String], timeout: TimeInterval? = nil) -> String {
        run(launchPath, args, timeout: timeout).out
    }
}
