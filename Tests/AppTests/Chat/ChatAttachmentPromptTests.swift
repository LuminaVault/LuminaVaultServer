@testable import App
import Foundation
import LuminaVaultShared
import Testing

@Suite("Chat attachment prompt composition")
struct ChatAttachmentPromptTests {
    private typealias Prompt = ChatAttachmentPrompt

    /// The no-attachment path has to be byte-for-byte identical, because it
    /// is every turn anyone sends today.
    @Test("No attachments leaves the content untouched")
    func passthrough() {
        #expect(Prompt.compose(content: "hello", attachments: nil) == "hello")
        #expect(Prompt.compose(content: "hello", attachments: []) == "hello")
    }

    /// Matches the block shape iOS has been sending since before there was
    /// an attachment contract, so turns recorded either side of this change
    /// read the same in a transcript.
    @Test("A text attachment is wrapped in the iOS block shape")
    func textBlockShape() {
        let composed = Prompt.compose(
            content: "what does this say?",
            attachments: [ChatAttachmentDTO(kind: .text, name: "notes.txt", text: "the contents")]
        )
        #expect(composed == """
        [Attached: notes.txt]
        \"\"\"
        the contents
        \"\"\"

        what does this say?
        """)
    }

    @Test("Each kind gets its own label")
    func labels() {
        let text = Prompt.compose(content: "x", attachments: [
            ChatAttachmentDTO(kind: .text, name: "a", text: "1")
        ])
        let file = Prompt.compose(content: "x", attachments: [
            ChatAttachmentDTO(kind: .vaultFile, name: "b", text: "2")
        ])
        let link = Prompt.compose(content: "x", attachments: [
            ChatAttachmentDTO(kind: .link, name: "c", url: "https://example.com")
        ])
        #expect(text.contains("[Attached: a]"))
        #expect(file.contains("[Attached file: b]"))
        #expect(link.contains("[Attached link: c]"))
    }

    /// An attachment with no message is still a request. Handing the model a
    /// bare document and no instruction is not.
    @Test("An attachment with no typed message gets an instruction")
    func attachmentWithoutMessage() {
        let composed = Prompt.compose(
            content: "",
            attachments: [ChatAttachmentDTO(kind: .text, name: "a", text: "body")]
        )
        #expect(composed.hasSuffix("Please use the attached context."))
    }

    @Test("Multiple attachments are separated and ordered as given")
    func multipleAttachments() {
        let composed = Prompt.compose(content: "compare", attachments: [
            ChatAttachmentDTO(kind: .text, name: "first", text: "one"),
            ChatAttachmentDTO(kind: .text, name: "second", text: "two")
        ])
        let firstIndex = try! #require(composed.range(of: "first")).lowerBound
        let secondIndex = try! #require(composed.range(of: "second")).lowerBound
        #expect(firstIndex < secondIndex)
        #expect(composed.hasSuffix("compare"))
    }

    /// One oversized file must not crowd out the conversation it was
    /// attached to. Visible truncation beats silently blowing the window.
    @Test("An oversized attachment is truncated, not dropped")
    func perAttachmentCap() {
        let huge = String(repeating: "x", count: Prompt.maxCharactersPerAttachment + 5_000)
        let composed = Prompt.compose(
            content: "summarise",
            attachments: [ChatAttachmentDTO(kind: .text, name: "big", text: huge)]
        )
        #expect(composed.contains(Prompt.truncationNotice))
        #expect(composed.contains("[Attached: big]"))
        #expect(composed.count < huge.count)
    }

    @Test("A total budget bounds the whole turn, not just each attachment")
    func totalCap() {
        let each = String(repeating: "y", count: Prompt.maxCharactersPerAttachment)
        let many = (0 ..< 10).map { ChatAttachmentDTO(kind: .text, name: "f\($0)", text: each) }
        let composed = Prompt.compose(content: "go", attachments: many)
        // Blocks add framing, so allow headroom over the raw budget while
        // still proving ten full-size files did not all get through.
        #expect(composed.count < Prompt.maxTotalCharacters + 2_000)
    }

    /// A reference the caller never resolved carries nothing. An empty block
    /// is worse than no block: the model has to reason about why it is there.
    @Test("Attachments with nothing usable are skipped")
    func emptyAttachmentsSkipped() {
        let composed = Prompt.compose(content: "hello", attachments: [
            ChatAttachmentDTO(kind: .text, name: "empty", text: ""),
            ChatAttachmentDTO(kind: .text, name: "blank", text: "   "),
            ChatAttachmentDTO(kind: .link, name: "nolink")
        ])
        #expect(composed == "hello")
    }

    @Test("A vault reference falls back to its path when the text is absent")
    func vaultPathFallback() {
        let composed = Prompt.compose(content: "x", attachments: [
            ChatAttachmentDTO(kind: .vaultFile, name: "plan", vaultPath: "notes/plan.md")
        ])
        #expect(composed.contains("notes/plan.md"))
    }
}
