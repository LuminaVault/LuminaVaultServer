@testable import App
import Foundation

/// HER-240c — scripted `StreamingExecHandle` fake. The test seeds a fixed
/// sequence of stdout lines + an exit code; the handle replays the lines
/// then resolves `wait()` with the code.
final class StubStreamingHandle: StreamingExecHandle, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let exitCode: Int32
    private(set) var cancelled = false

    init(lines: [String], exitCode: Int32 = 0) {
        var capturedContinuation: AsyncStream<String>.Continuation!
        self.lines = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
        self.exitCode = exitCode
        // Drain initial lines synchronously so consumers can iterate
        // without yielding to the runloop first.
        for line in lines {
            continuation.yield(line)
        }
        // Leave the stream OPEN: tests close it explicitly via
        // `finishLines` so the consumer can choose when to terminate.
    }

    func finishLines() {
        continuation.finish()
    }

    func wait() async throws -> Int32 {
        // Mirror real behaviour — wait until stream is finished, then
        // return the canned exit code.
        for await _ in lines {}
        return exitCode
    }

    func cancel() async {
        cancelled = true
        continuation.finish()
    }
}
