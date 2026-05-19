@testable import App
import Foundation

/// HER-240a — in-memory DockerExec stub for tests. Records every `run`,
/// `exec`, `isRunning`, and `ensureNetworkExists` invocation; returns canned
/// results queued via `enqueue(_:for:)` or a global default.
actor StubDockerExec: DockerExec {
    struct Invocation: Sendable, Equatable {
        let kind: String // "run" | "exec" | "isRunning" | "ensureNetwork"
        let args: [String]
        let container: String?
    }

    private(set) var invocations: [Invocation] = []
    /// Containers that should report `isRunning == true`. Pre-populate to
    /// model an already-up container.
    var running: Set<String> = []
    /// Per-arg-prefix canned results. The first prefix that matches the
    /// args (in insertion order) returns its DockerResult. Falls back to
    /// `defaultResult` when no prefix matches.
    private var queued: [(prefix: [String], result: DockerResult)] = []
    var defaultResult = DockerResult(stdout: "", stderr: "", exitCode: 0)

    func enqueue(_ result: DockerResult, forArgsStartingWith prefix: [String]) {
        queued.append((prefix, result))
    }

    func setRunning(_ container: String, _ value: Bool) {
        if value { running.insert(container) } else { running.remove(container) }
    }

    func run(args: [String]) async throws -> DockerResult {
        invocations.append(Invocation(kind: "run", args: args, container: nil))
        if args.first == "run", let nameIdx = args.firstIndex(of: "--name"),
           args.indices.contains(nameIdx + 1)
        {
            running.insert(args[nameIdx + 1])
        }
        if args.first == "rm", let target = args.last { running.remove(target) }
        return matchOrDefault(args: args)
    }

    func exec(container: String, command: [String], stdin _: Data?) async throws -> DockerResult {
        invocations.append(Invocation(kind: "exec", args: command, container: container))
        return matchOrDefault(args: command)
    }

    func isRunning(container: String) async throws -> Bool {
        invocations.append(Invocation(kind: "isRunning", args: [], container: container))
        return running.contains(container)
    }

    func ensureNetworkExists(_ name: String) async throws {
        invocations.append(Invocation(kind: "ensureNetwork", args: [name], container: nil))
    }

    /// HER-240c — pre-loaded streaming handle returned by the next
    /// `execStreaming` call. Tests inject a `StubStreamingHandle` here.
    var nextStreamingHandle: (any StreamingExecHandle)?

    func setNextStreamingHandle(_ handle: any StreamingExecHandle) {
        nextStreamingHandle = handle
    }

    func execStreaming(container: String, command: [String]) async throws -> any StreamingExecHandle {
        invocations.append(Invocation(kind: "execStreaming", args: command, container: container))
        if let handle = nextStreamingHandle {
            nextStreamingHandle = nil
            return handle
        }
        return StubStreamingHandle(lines: [], exitCode: 0)
    }

    private func matchOrDefault(args: [String]) -> DockerResult {
        for entry in queued where args.starts(with: entry.prefix) {
            return entry.result
        }
        return defaultResult
    }
}
