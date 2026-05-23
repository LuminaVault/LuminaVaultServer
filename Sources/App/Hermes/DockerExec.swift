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

    /// Long-running variant of `exec`. The returned `StreamingExecHandle`
    /// yields stdout line-by-line and exposes `wait()` for the eventual
    /// exit code. Used by `LiveXaiOAuthBackend` so it can read the
    /// `Authorize at: <URL>` line and return it to the caller while the
    /// underlying `hermes auth add xai-oauth --no-browser` subprocess
    /// keeps its loopback listener open until the iOS app POSTs the
    /// captured callback URL.
    func execStreaming(container: String, command: [String]) async throws -> any StreamingExecHandle
}

extension DockerExec {
    func exec(container: String, command: [String]) async throws -> DockerResult {
        try await exec(container: container, command: command, stdin: nil)
    }
}

/// Opaque handle to a long-running `docker exec` subprocess. Lines flow
/// over `lines`; the process exit code is observable via `wait()`. Always
/// `cancel()` if the handle is abandoned so the docker subprocess doesn't
/// leak.
protocol StreamingExecHandle: Sendable {
    /// Stdout line stream. Finishes once the subprocess exits.
    var lines: AsyncStream<String> { get }
    /// Await final exit code. Throws `DockerExecError.spawnFailed` if the
    /// subprocess never started.
    func wait() async throws -> Int32
    /// Best-effort terminate. Safe to call multiple times.
    func cancel() async
}

struct DockerResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var ok: Bool {
        exitCode == 0
    }
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

    func execStreaming(container: String, command: [String]) async throws -> any StreamingExecHandle {
        try await ProcessStreamingHandle.spawn(
            binaryPath: binaryPath,
            args: ["exec", "-i", container] + command,
            logger: logger,
        )
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

/// Live streaming handle backed by a `Process`. Stdout is read incrementally
/// through the pipe's `readabilityHandler`; whole lines are emitted into the
/// `AsyncStream`. Termination resolves `wait()`.
final class ProcessStreamingHandle: StreamingExecHandle, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let process: Process
    private let continuation: AsyncStream<String>.Continuation
    private let exitFuture: Task<Int32, Error>
    private let stderrCollector: StderrCollector

    private init(
        lines: AsyncStream<String>,
        continuation: AsyncStream<String>.Continuation,
        process: Process,
        exitFuture: Task<Int32, Error>,
        stderrCollector: StderrCollector,
    ) {
        self.lines = lines
        self.continuation = continuation
        self.process = process
        self.exitFuture = exitFuture
        self.stderrCollector = stderrCollector
    }

    func wait() async throws -> Int32 {
        try await exitFuture.value
    }

    func cancel() async {
        if process.isRunning {
            process.terminate()
        }
        continuation.finish()
    }

    static func spawn(
        binaryPath: String,
        args: [String],
        logger: Logger,
    ) async throws -> ProcessStreamingHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        let lineBuffer = LineBuffer { line in
            continuation.yield(line)
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                outPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                lineBuffer.append(data)
            }
        }
        let stderr = StderrCollector()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                errPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                stderr.append(data)
            }
        }

        let exitFuture = Task<Int32, Error> {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { proc in
                    lineBuffer.flush()
                    continuation.finish()
                    cont.resume(returning: proc.terminationStatus)
                }
            }
        }

        do {
            try process.run()
        } catch {
            continuation.finish()
            exitFuture.cancel()
            logger.warning("docker exec streaming spawn failed: \(error)")
            throw DockerExecError.spawnFailed(String(describing: error))
        }

        return ProcessStreamingHandle(
            lines: stream,
            continuation: continuation,
            process: process,
            exitFuture: exitFuture,
            stderrCollector: stderr,
        )
    }
}

/// Splits incoming byte chunks into newline-terminated UTF-8 lines.
private final class LineBuffer: @unchecked Sendable {
    private var carry = Data()
    private let lock = NSLock()
    private let emit: @Sendable (String) -> Void

    init(emit: @escaping @Sendable (String) -> Void) {
        self.emit = emit
    }

    func append(_ data: Data) {
        lock.lock()
        carry.append(data)
        while let nl = carry.firstIndex(of: 0x0A) {
            let lineData = carry[..<nl]
            carry.removeSubrange(..<carry.index(after: nl))
            if let line = String(data: lineData, encoding: .utf8) {
                emit(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            }
        }
        lock.unlock()
    }

    func flush() {
        lock.lock()
        if !carry.isEmpty, let line = String(data: carry, encoding: .utf8), !line.isEmpty {
            emit(line)
        }
        carry.removeAll()
        lock.unlock()
    }
}

/// Captures stderr bytes for surface-time diagnostics. Tiny critical
/// section so the readability handler stays non-blocking.
private final class StderrCollector: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock(); buffer.append(data); lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
