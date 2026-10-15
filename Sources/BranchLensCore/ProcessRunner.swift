import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutText: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrText: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

/// Runs an executable with an explicit URL and argument array. No shell is involved.
public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        if let currentDirectory {
            let path = currentDirectory.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                throw GitError.commandFailed("Worktree folder is gone:\n\(path)")
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = subprocessEnvironment(environment ?? ProcessInfo.processInfo.environment)
            if let currentDirectory {
                process.currentDirectoryURL = currentDirectory
            }
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let state = OutputState()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    state.appendStdout(chunk)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    state.appendStderr(chunk)
                }
            }

            process.terminationHandler = { proc in
                let remainingOut = try? stdoutPipe.fileHandleForReading.readToEnd()
                let remainingErr = try? stderrPipe.fileHandleForReading.readToEnd()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let (out, err) = state.finish(
                    trailingStdout: remainingOut ?? Data(),
                    trailingStderr: remainingErr ?? Data()
                )
                continuation.resume(returning: ProcessResult(
                    status: proc.terminationStatus, stdout: out, stderr: err
                ))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Desktop launches often omit Homebrew from PATH. Git's filters and hooks
    /// need it too, even when Git itself is launched by an absolute path.
    static func subprocessEnvironment(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited
        var paths = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if environment["PATH"] == nil { paths = [] }
        for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            if !paths.contains(path) { paths.append(path) }
        }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }

    private final class OutputState: @unchecked Sendable {
        private var stdout = Data()
        private var stderr = Data()
        private let lock = NSLock()

        func appendStdout(_ d: Data) {
            lock.lock(); stdout.append(d); lock.unlock()
        }

        func appendStderr(_ d: Data) {
            lock.lock(); stderr.append(d); lock.unlock()
        }

        func finish(trailingStdout: Data, trailingStderr: Data) -> (Data, Data) {
            lock.lock(); defer { lock.unlock() }
            stdout.append(trailingStdout)
            stderr.append(trailingStderr)
            return (stdout, stderr)
        }
    }
}
