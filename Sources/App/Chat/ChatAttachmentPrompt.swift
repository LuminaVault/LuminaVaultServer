import Foundation
import LuminaVaultShared

/// Folds a turn's attachments into the prompt text.
///
/// Server-side on purpose. iOS has done this client-side since before there
/// was an attachment contract (`ChatViewModel.wireText`), and web was about to
/// grow its own copy — at which point the same attached file would reach the
/// model in two different shapes depending on which app the user happened to
/// open. One flattener, one shape, one place to change it.
///
/// The block format matches what iOS already sends, so turns recorded before
/// and after this change read the same in a transcript.
enum ChatAttachmentPrompt {
    /// Per-attachment cap. An attachment is context, not the message: one
    /// oversized file should not crowd out the conversation it was attached
    /// to, and silently blowing the context window is worse than visibly
    /// truncating. Generous enough that ordinary notes and source files pass
    /// through whole.
    static let maxCharactersPerAttachment = 20000

    /// Total cap across all attachments on one turn, for the same reason.
    static let maxTotalCharacters = 60000

    static let truncationNotice = "\n… (truncated)"

    /// Returns the content to send upstream. With no attachments this is the
    /// typed text unchanged, byte for byte.
    static func compose(content: String, attachments: [ChatAttachmentDTO]?) -> String {
        guard let attachments, !attachments.isEmpty else { return content }

        var budget = maxTotalCharacters
        var blocks: [String] = []

        for attachment in attachments {
            guard budget > 0 else { break }
            guard let body = body(of: attachment) else { continue }
            let allowance = min(maxCharactersPerAttachment, budget)
            let (text, truncated) = clip(body, to: allowance)
            budget -= text.count
            blocks.append("""
            [\(label(for: attachment)): \(attachment.name)]
            \"\"\"
            \(text)\(truncated ? truncationNotice : "")
            \"\"\"
            """)
        }

        guard !blocks.isEmpty else { return content }
        let joined = blocks.joined(separator: "\n\n")
        let typed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // An attachment with no message is still a request — say so, rather
        // than handing the model a bare document and no instruction.
        return typed.isEmpty
            ? "\(joined)\n\nPlease use the attached context."
            : "\(joined)\n\n\(content)"
    }

    private static func label(for attachment: ChatAttachmentDTO) -> String {
        switch attachment.kind {
        case .text: "Attached"
        case .vaultFile: "Attached file"
        case .link: "Attached link"
        }
    }

    /// The text a given attachment contributes, or nil when it carries
    /// nothing usable — a vault reference whose contents the caller did not
    /// resolve, for instance, which is better skipped than rendered as an
    /// empty block the model has to reason about.
    private static func body(of attachment: ChatAttachmentDTO) -> String? {
        let candidate: String? = switch attachment.kind {
        case .text: attachment.text
        case .vaultFile: attachment.text ?? attachment.vaultPath
        case .link: attachment.url
        }
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Clips on a character count. Deliberately not a token count: the exact
    /// boundary does not matter here, only that one attachment cannot consume
    /// the whole window, and a character cap needs no tokenizer and no
    /// per-model knowledge.
    private static func clip(_ text: String, to limit: Int) -> (String, Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }
}
