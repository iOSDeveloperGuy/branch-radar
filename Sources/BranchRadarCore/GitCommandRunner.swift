import Foundation

public struct GitCommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public enum GitCommandError: Error, CustomStringConvertible, Sendable {
    case launchFailed(String)
    case outputCaptureFailed(String)

    public var description: String {
        switch self {
        case .launchFailed(let message), .outputCaptureFailed(let message):
            return message
        }
    }
}

public protocol GitCommandRunning: Sendable {
    func run(arguments: [String], directory: URL) throws -> GitCommandResult
}

public struct GitCommandRunner: GitCommandRunning, Sendable {
    public init() {}

    public func run(arguments: [String], directory: URL) throws -> GitCommandResult {
        let process = Process()
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-radar-process")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stdoutURL = captureDirectory.appendingPathComponent("stdout")
        let stderrURL = captureDirectory.appendingPathComponent("stderr")

        do {
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        } catch {
            throw GitCommandError.outputCaptureFailed(
                "Unable to prepare Git output capture: \(error.localizedDescription)"
            )
        }

        defer { try? FileManager.default.removeItem(at: captureDirectory) }

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            throw GitCommandError.outputCaptureFailed(
                "Unable to open Git output capture: \(error.localizedDescription)"
            )
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw GitCommandError.launchFailed("Unable to launch git: \(error.localizedDescription)")
        }

        process.waitUntilExit()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        do {
            let stdoutData = try Data(contentsOf: stdoutURL)
            let stderrData = try Data(contentsOf: stderrURL)
            return GitCommandResult(
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self),
                exitCode: process.terminationStatus
            )
        } catch {
            throw GitCommandError.outputCaptureFailed(
                "Unable to read Git output: \(error.localizedDescription)"
            )
        }
    }
}
