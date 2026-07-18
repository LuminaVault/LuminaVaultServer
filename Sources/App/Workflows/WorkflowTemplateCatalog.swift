import Foundation
import LuminaVaultShared

enum WorkflowTemplateCatalog {
    static let templates: [WorkflowTemplateDTO] = [
        researchBrief,
        memoryDigest,
        extractReviewSave,
        sequentialSynthesis,
    ]

    static func template(id: String) -> WorkflowTemplateDTO? {
        templates.first { $0.id == id }
    }

    private static let researchBrief = makeTemplate(
        id: "research-brief",
        name: "Research Brief",
        description: "Search your vault, analyze the evidence, and produce a concise cited brief.",
        category: "Research",
        nodes: [
            node("10000000-0000-0000-0000-000000000001", .trigger, "Start", 80, 180),
            node("10000000-0000-0000-0000-000000000002", .memorySearch, "Find evidence", 340, 180, ["query": "{{topic}}", "limit": "8"]),
            node("10000000-0000-0000-0000-000000000003", .llm, "Write brief", 600, 180, ["prompt": "Create a structured research brief about {{topic}} using only this vault evidence:\n\n{{nodes.10000000-0000-0000-0000-000000000002.text}}"]),
            node("10000000-0000-0000-0000-000000000004", .output, "Result", 860, 180, ["value": "{{nodes.10000000-0000-0000-0000-000000000003.text}}"]),
        ]
    )

    private static let memoryDigest = makeTemplate(
        id: "memory-digest",
        name: "Memory Digest",
        description: "Turn a focused memory search into a practical digest.",
        category: "Memory",
        nodes: [
            node("20000000-0000-0000-0000-000000000001", .trigger, "Start", 80, 180),
            node("20000000-0000-0000-0000-000000000002", .memorySearch, "Recall", 340, 180, ["query": "{{topic}}", "limit": "12"]),
            node("20000000-0000-0000-0000-000000000003", .llm, "Summarize", 600, 180, ["prompt": "Summarize the following memories into themes, decisions, and next actions:\n\n{{nodes.20000000-0000-0000-0000-000000000002.text}}"]),
            node("20000000-0000-0000-0000-000000000004", .output, "Digest", 860, 180, ["value": "{{nodes.20000000-0000-0000-0000-000000000003.text}}"]),
        ]
    )

    private static let extractReviewSave = makeTemplate(
        id: "extract-review-save",
        name: "Extract, Review & Save",
        description: "Extract durable knowledge, pause for your review, then save it to memory.",
        category: "Knowledge",
        nodes: [
            node("30000000-0000-0000-0000-000000000001", .trigger, "Start", 80, 180),
            node("30000000-0000-0000-0000-000000000002", .llm, "Extract knowledge", 340, 180, ["prompt": "Extract the durable facts, decisions, and follow-ups from:\n\n{{source}}"]),
            node("30000000-0000-0000-0000-000000000003", .approval, "Review extraction", 600, 180, ["message": "Review the extracted knowledge. You can attach memories before continuing."]),
            node("30000000-0000-0000-0000-000000000004", .memoryWrite, "Save memory", 860, 180, ["content": "{{nodes.30000000-0000-0000-0000-000000000002.text}}"]),
            node("30000000-0000-0000-0000-000000000005", .output, "Saved", 1120, 180, ["value": "{{nodes.30000000-0000-0000-0000-000000000004.text}}"]),
        ]
    )

    private static let sequentialSynthesis = makeTemplate(
        id: "sequential-multi-model-synthesis",
        name: "Sequential Multi-Model Synthesis",
        description: "Ask two models in sequence, then synthesize their perspectives.",
        category: "Multi-model",
        nodes: [
            node("40000000-0000-0000-0000-000000000001", .trigger, "Start", 80, 180),
            node("40000000-0000-0000-0000-000000000002", .llm, "First analysis", 340, 180, ["prompt": "Analyze this question carefully:\n\n{{question}}", "model": "auto"]),
            node("40000000-0000-0000-0000-000000000003", .llm, "Second perspective", 600, 180, ["prompt": "Offer an independent critical perspective on {{question}}. Consider this prior analysis:\n\n{{nodes.40000000-0000-0000-0000-000000000002.text}}", "model": "auto"]),
            node("40000000-0000-0000-0000-000000000004", .llm, "Synthesize", 860, 180, ["prompt": "Synthesize a final answer from these two analyses:\n\nA: {{nodes.40000000-0000-0000-0000-000000000002.text}}\n\nB: {{nodes.40000000-0000-0000-0000-000000000003.text}}", "model": "auto"]),
            node("40000000-0000-0000-0000-000000000005", .output, "Result", 1120, 180, ["value": "{{nodes.40000000-0000-0000-0000-000000000004.text}}"]),
        ]
    )

    private static func makeTemplate(id: String, name: String, description: String, category: String, nodes: [WorkflowNodeDTO]) -> WorkflowTemplateDTO {
        let edges = zip(nodes, nodes.dropFirst()).map { pair in
            WorkflowEdgeDTO(sourceNodeID: pair.0.id, targetNodeID: pair.1.id)
        }
        return WorkflowTemplateDTO(
            id: id,
            name: name,
            descriptionText: description,
            category: category,
            definition: WorkflowDefinitionDTO(trigger: .manual, nodes: nodes, edges: edges)
        )
    }

    private static func node(_ id: String, _ kind: WorkflowNodeKind, _ name: String, _ x: Double, _ y: Double, _ configuration: [String: String] = [:]) -> WorkflowNodeDTO {
        WorkflowNodeDTO(
            id: UUID(uuidString: id) ?? UUID(),
            kind: kind,
            name: name,
            x: x,
            y: y,
            configuration: configuration
        )
    }
}
