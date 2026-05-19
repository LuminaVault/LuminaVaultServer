import Foundation
import Logging

/// HER-240a — minimal async wrapper around the host `docker` CLI. We do **not**
/// reach for a Swift Docker SDK because (a) every operation we need maps to
/// one shell verb and (b) the protocol-shaped surface is much easier to stub
/// in tests than a real Docker SDK client.
///
/// Protocol abstraction is here, the `ProcessDockerExec` implementation runs
/// the actual binary. Tests inject a stub that records invocations + returns
/// canned (stdout, stderr, exit code) tuples.
protocol DockerExec: Sendable {
    /// Execute `docker <args...>` and return the captured output. Throws
    /// `DockerExecError.spawnFailed` if the binary cannot be launched.
    func run(args: [String]) async throws -> DockerResult

    /// Execute a command inside a running container: `docker exec <container> <command...>`.
    /// `stdin`, when provided, is piped to the child process and the pipe is
    /// closed before reading stdout/stderr.
    func exec(container: String, command: [String], stdin: Data?) async throws -> DockerResult

    /// `docker inspect --format='{{.State.Running}}' <container>` returns
    /// `true` when the container exists and is up. Anything else (including
    /// a non-zero exit) returns `false` rather than throwing — callers
    /// treat "missing" and "stopped" identically.
    func isRunning(container: String) async throws -> Bool

    /// `docker network create --driver=bridge <name>` once; subsequent calls
    /// are no-ops. Caller is responsible for picking a stable name.
    func ensureNetworkExists(_ name: String) async throws
}

extension DockerExec {
    func exec(container: String, command: [String]) async throws -> DockerResult {
        try await exec(container: container, command: command, stdin: nil)
    }
}

struct DockerResult: Sendable, Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    var ok: Bool { exitCode == 0 }
}

enum DockerExecError: Error, Equatable {
    case spawnFailed(String)
    case nonZeroExit(args: [String], stderr: String, exitCode: Int32)
}

/// Production implementation: forks the `docker` binary.
struct ProcessDockerExec: DockerExec {
    private let binaryPath: String
    private let logger: Logger

    init(binaryPath: String, logger: Logger) {
        self.binaryPath = binaryPath
        self.logger = logger
    }

    func run(args: [String]) async throws -> DockerResult {
        try await runProcess(args: args, stdin: nil)
    }

    func exec(container: String, command: [String], stdin: Data? = nil) async throws -> DockerResult {
        let args = ["exec", "-i", container] + command
        return try await runProcess(args: args, stdin: stdin)
    }

    func isRunning(container: String) async throws -> Bool {
        let result = try await runProcess(
            args: ["inspect", "--format={{.State.Running}}", container],
            stdin: nil,
        )
        guard result.ok else { return false }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    func ensureNetworkExists(_ name: String) async throws {
        // `docker network inspect` returns 0 when the network exists, non-zero
        // otherwise. Only call `create` when inspect fails so re-runs are
        // idempotent and don't log a spurious "already exists" error.
        let inspect = try await runProcess(args: ["network", "inspect", name], stdin: nil)
        if inspect.ok { return }
        let create = try await runProcess(
            args: ["network", "create", "--driver=bridge", name],
            stdin: nil,
        )
        guard create.ok else {
            throw DockerExecError.nonZeroExit(
                args: ["network", "create", name],
                stderr: create.stderr,
                exitCode: create.exitCode,
            )
        }
    }

    private func runProcess(args: [String], stdin: Data?) async throws -> DockerResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DockerResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            if stdin != nil {
                process.standardInput = Pipe()
            }

            process.terminationHandler = { proc in
                let outData = (try? outPipe.fileHandleForReading.readToEnd() ?? Data()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd() ?? Data()) ?? Data()
                continuation.resume(returning: DockerResult(
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self),
                    exitCode: proc.terminationStatus,
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: DockerExecError.spawnFailed(String(describing: error)))
                return
            }

            if let stdin, let inputPipe = process.standardInput as? Pipe {
                try? inputPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inputPipe.fileHandleForWriting.close()
            }
        }
    }
}
