import Foundation
import Logging
import LuminaVaultShared

/// HER-240 / spec ticket #4 — pre-process chat messages so the LLM sees
/// enriched content for any HTTP(S) URLs the user pasted. Without this,
/// bare URLs in a chat completion force the gateway to fetch + reason
/// about them server-side, which is what produced the original
/// `NSURLErrorTimedOut` repro on `https://www.youtube.com/...` payloads.
///
/// For each user-role message containing URLs, runs the enricher chain
/// (YouTube, X, GenericOG, plus jina tier-2 if configured) and prepends
/// a `<context>` block per URL to the message content. The original
/// user text is preserved verbatim after the context blocks.
///
/// Failures (SSRF, network, jina rate-limit) silently skip the URL so
/// the chat still goes through with whatever enrichment succeeded.
struct ChatURLPreEnricher {
    let urlEnrichmentService: URLEnrichmentService
    let logger: Logger

    /// Returns the messages with `<context>` blocks prepended to any
    /// user-role message that contains http(s) URLs. Non-user messages
    /// (system, assistant, tool) pass through unchanged.
    func enrich(messages: [ChatMessage]) async -> [ChatMessage] {
        var out: [ChatMessage] = []
        out.reserveCapacity(messages.count)
        for message in messages {
            guard message.role == "user" else {
                out.append(message)
                continue
            }
            let urls = URLExtractor.extract(from: message.content)
            if urls.isEmpty {
                out.append(message)
                continue
            }
            let contextBlocks = await urls.asyncCompactMap { await contextBlock(for: $0) }
            if contextBlocks.isEmpty {
                out.append(message)
                continue
            }
            let rewritten = contextBlocks.joined(separator: "\n") + "\n\n" + message.content
            out.append(ChatMessage(
                role: message.role,
                content: rewritten,
                tool_calls: message.tool_calls,
            ))
        }
        return out
    }

    private func contextBlock(for url: URL) async -> String? {
        guard let metadata = await urlEnrichmentService.enrichURL(url.absoluteString) else {
            return nil
        }
        let source = escapeXMLAttribute(url.absoluteString)
        var block = "<context source=\"\(source)\">"
        if let title = metadata.title, !title.isEmpty {
            block += "\n  <title>\(escapeXML(title))</title>"
        }
        if let description = metadata.description, !description.isEmpty {
            block += "\n  <description>\(escapeXML(description))</description>"
        }
        if let transcript = metadata.transcript, !transcript.isEmpty {
            block += "\n  <transcript>\(escapeXML(transcript))</transcript>"
        }
        // HER-240 ticket #3 — full page body from the jina tier-2 enricher
        // (keyless r.jina.ai). Without this the LLM only saw title/description
        // for a pasted link and couldn't reason about the article contents.
        if let body = metadata.body, !body.isEmpty {
            block += "\n  <body>\(escapeXML(body))</body>"
        }
        block += "\n</context>"
        return block
    }

    private func escapeXML(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeXMLAttribute(_ s: String) -> String {
        escapeXML(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension Sequence {
    /// Sequential async compactMap. Keeps order stable; serializes the
    /// underlying enrichment fetches so we don't fan out N concurrent
    /// jina calls per chat turn.
    func asyncCompactMap<T>(_ transform: (Element) async -> T?) async -> [T] {
        var out: [T] = []
        for element in self {
            if let value = await transform(element) {
                out.append(value)
            }
        }
        return out
    }
}
