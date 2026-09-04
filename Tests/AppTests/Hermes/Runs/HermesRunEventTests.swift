@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// SSE framing + event decoding. These two together decide what the watcher
/// persists, so every Hermes event name the gateway can emit is covered.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesRunEventTests {
    // MARK: - SSE framing

    @Test
    func `parser buffers partial records across feeds`() {
        var parser = SSEFrameParser()
        #expect(parser.feed("data: {\"a\":").isEmpty)
        let records = parser.feed("1}\n\n")
        #expect(records == [SSEFrameParser.Record(event: nil, data: #"{"a":1}"#)])
    }

    @Test
    func `parser drops keepalive comments and reads the event name`() {
        var parser = SSEFrameParser()
        let records = parser.feed(": keepalive\n\nevent: run.started\ndata: {}\n\n")
        #expect(records == [SSEFrameParser.Record(event: "run.started", data: "{}")])
    }

    @Test
    func `parser joins multi-line data and handles CRLF records`() {
        var parser = SSEFrameParser()
        let records = parser.feed("data: line1\r\ndata: line2\r\n\r\n")
        #expect(records == [SSEFrameParser.Record(event: nil, data: "line1\nline2")])
    }

    @Test
    func `parser flush surfaces a record the upstream never terminated`() {
        var parser = SSEFrameParser()
        #expect(parser.feed("data: {\"event\":\"error\"}").isEmpty)
        #expect(parser.flush() == SSEFrameParser.Record(event: nil, data: #"{"event":"error"}"#))
        // Flushing twice must not replay it.
        #expect(parser.flush() == nil)
    }

    // MARK: - Event decoding

    @Test
    func `approval request carries the redacted command, the choices and the extras`() throws {
        let frame = try #require(HermesRunEvent.decode(
            eventName: nil,
            data: #"""
            {"event":"approval.request","run_id":"run_1","command":"rm -rf ***",
             "choices":["once","always","deny"],"tool":"shell","timestamp":1000}
            """#
        ))
        #expect(frame.name == "approval.request")
        #expect(frame.at == Date(timeIntervalSince1970: 1000))
        guard case let .approvalRequest(command, choices, extra) = frame.event else {
            Issue.record("expected an approval request, got \(frame.event)")
            return
        }
        #expect(command == "rm -rf ***")
        #expect(choices == [.once, .always, .deny])
        // `event`, `run_id`, `timestamp`, `command` and `choices` are modelled
        // fields; everything else survives for clients that can show it.
        #expect(extra["tool"]?.stringValue == "shell")
        #expect(extra["run_id"] == nil)
    }

    @Test
    func `approval request with no choices falls back to the full set`() throws {
        let frame = try #require(HermesRunEvent.decode(eventName: nil, data: #"{"event":"approval.request"}"#))
        guard case let .approvalRequest(_, choices, _) = frame.event else {
            Issue.record("expected an approval request")
            return
        }
        #expect(choices == HermesApprovalChoice.allCases)
    }

    @Test
    func `every modelled hermes event name decodes to its case`() throws {
        func event(_ json: String) throws -> HermesRunEvent {
            try #require(HermesRunEvent.decode(eventName: nil, data: json)).event
        }
        #expect(try event(#"{"event":"run.started"}"#) == .runStarted)
        #expect(try event(#"{"event":"message.started"}"#) == .messageStarted)
        #expect(try event(#"{"event":"message.delta","delta":"hi"}"#) == .messageDelta("hi"))
        #expect(try event(#"{"event":"tool.completed","tool":"shell","duration":1.5}"#)
            == .toolCompleted(tool: "shell", durationSeconds: 1.5, isError: false))
        #expect(try event(#"{"event":"tool.failed","tool_name":"web","error":"boom"}"#)
            == .toolFailed(tool: "web", error: "boom"))
        #expect(try event(#"{"event":"hermes.tool.progress","text":"reading"}"#)
            == .toolProgress(tool: nil, text: "reading"))
        #expect(try event(#"{"event":"approval.responded","choice":"once"}"#) == .approvalResponded(choice: "once"))
        #expect(try event(#"{"event":"run.failed","error":"nope"}"#) == .runFailed(error: "nope"))
        #expect(try event(#"{"event":"run.cancelled"}"#) == .runCancelled)
        #expect(try event(#"{"event":"error","message":"bad"}"#) == .error(message: "bad"))
    }

    @Test
    func `an unknown event survives with its payload so replay is lossless`() throws {
        let frame = try #require(
            HermesRunEvent.decode(eventName: "brand.new", data: #"{"weird":true}"#)
        )
        #expect(frame.name == "brand.new")
        #expect(frame.event.impliedStatus == nil)
        guard case let .unknown(name, payload) = frame.event else {
            Issue.record("expected unknown")
            return
        }
        #expect(name == "brand.new")
        #expect(payload.objectValue?["weird"]?.boolValue == true)
    }

    @Test
    func `decode rejects a record that names no event`() {
        #expect(HermesRunEvent.decode(eventName: nil, data: #"{"no":"name"}"#) == nil)
        #expect(HermesRunEvent.decode(eventName: nil, data: "not json") == nil)
    }

    // MARK: - State machine

    @Test
    func `a pending approval survives stray deltas and clears on a tool event`() {
        var status = HermesRunStatus.running
        status = HermesRunWatcher.transition(from: status, on: .approvalRequest(command: nil, choices: [], extra: [:]))
        #expect(status == .waitingForApproval)
        // A late message delta must not hide the fact the run is blocked.
        status = HermesRunWatcher.transition(from: status, on: .messageDelta("thinking"))
        #expect(status == .waitingForApproval)
        status = HermesRunWatcher.transition(from: status, on: .toolStarted(tool: "shell", preview: nil))
        #expect(status == .running)
    }

    @Test
    func `terminal states are absorbing`() {
        let terminal = HermesRunWatcher.transition(from: .running, on: .runCompleted(summary: "ok"))
        #expect(terminal == .completed)
        #expect(HermesRunWatcher.transition(from: terminal, on: .runStarted) == .completed)
    }

    @Test
    func `a polled status change is synthesised as the event hermes would have sent`() {
        let snapshot = HermesRunStatusSnapshot(
            status: "completed",
            lastEvent: "run.completed",
            output: "finished",
            error: nil,
            sessionID: nil
        )
        let frame = HermesRunWatcher.synthesise(.completed, from: snapshot)
        #expect(frame.name == "run.completed")
        #expect(frame.event == .runCompleted(summary: "finished"))
        #expect(frame.payload.objectValue?["source"]?.stringValue == "poll")
    }

    // MARK: - Push bodies

    @Test
    func `push bodies are single line, redacted and capped`() {
        let body = try? #require(APNSHermesRunPushNotifier.bodyText("  first line \n\n second line  "))
        #expect(body == "first line second line")
        #expect(APNSHermesRunPushNotifier.bodyText("   \n  ") == nil)
        #expect(APNSHermesRunPushNotifier.bodyText(nil) == nil)

        let long = APNSHermesRunPushNotifier.bodyText(String(repeating: "x", count: 500))
        #expect(long?.count == APNSHermesRunPushNotifier.bodyLimit)
        #expect(long?.hasSuffix("…") == true)
    }
}
