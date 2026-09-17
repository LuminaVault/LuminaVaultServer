import Foundation
import Hummingbird

/// What the calling client has told us it can cope with.
///
/// The chat SSE stream is a discriminated union, and until LuminaVaultShared
/// 5.16.0 the iOS decoder threw on a `type` it did not know — a throw that
/// `BaseHTTPClient.executeStream` turns into a dead stream, so one unknown
/// frame ended the whole chat turn. Shipped builds older than that are
/// therefore permanently intolerant, and the server cannot tell them apart
/// from new ones by looking at the wire.
///
/// So the client declares itself. A client that knows how to skip an unknown
/// frame sends the capability; the server withholds anything new from
/// everyone else and they keep getting the classic stream.
///
/// Deliberately **not** an app-version check. Version strings drift across
/// TestFlight builds, web deploys and future clients, and they say nothing
/// about what a given build actually understands. A capability token says
/// exactly one thing and means it.
struct ClientCapabilities: Sendable, Equatable {
    /// The request header clients declare through. Comma-separated, order
    /// irrelevant, unknown tokens ignored so new ones are always safe to add.
    static let headerName = "x-lv-client-caps"

    /// A single declared capability.
    enum Capability: String, Sendable, CaseIterable {
        /// The client tolerates an unknown `type` on the chat SSE stream and
        /// will skip the frame rather than abort. Required before the server
        /// may emit the chat run-pointer event.
        case chatHermesRun = "chat.hermes_run"
    }

    private let declared: Set<Capability>

    init(declared: Set<Capability> = []) {
        self.declared = declared
    }

    func supports(_ capability: Capability) -> Bool {
        declared.contains(capability)
    }

    /// Parses the header value. Absent, empty or unparseable all mean
    /// "declares nothing", because the default must be the safe one: an old
    /// client that never heard of this header would otherwise be handed
    /// frames that kill its stream.
    static func parse(_ headerValue: String?) -> ClientCapabilities {
        guard let headerValue else { return ClientCapabilities() }
        let tokens = headerValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return ClientCapabilities(declared: Set(tokens.compactMap(Capability.init(rawValue:))))
    }
}

extension Request {
    /// Capabilities declared by this request's client. Fails closed.
    var clientCapabilities: ClientCapabilities {
        ClientCapabilities.parse(headers[.init(ClientCapabilities.headerName)!])
    }
}
