import Foundation

struct SlashCommandInvocation: Equatable {
    enum Kind: Equatable {
        case kbCompile
        case skill(name: String)
        case help(markdown: String)
    }

    let kind: Kind
    let input: String?
    let arguments: [String: String]
}

enum SlashCommandParser {
    static func parse(_ raw: String) -> SlashCommandInvocation? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let withoutSlash = trimmed.dropFirst()
        let parts = withoutSlash.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let commandPart = parts.first else { return nil }

        let command = commandPart.lowercased()
        let input = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let normalizedInput = input.isEmpty ? nil : input

        switch command {
        case "kb-compile", "kb-ingest":
            return SlashCommandInvocation(kind: .kbCompile, input: normalizedInput, arguments: [:])
        case "patterns", "pattern-detector":
            return SlashCommandInvocation(
                kind: .skill(name: "pattern-detector"),
                input: normalizedInput,
                arguments: topicArguments(normalizedInput),
            )
        case "contradict", "contradiction-detector":
            return SlashCommandInvocation(
                kind: .skill(name: "contradiction-detector"),
                input: normalizedInput,
                arguments: topicArguments(normalizedInput),
            )
        case "beliefs", "belief-evolution":
            guard let normalizedInput else {
                return SlashCommandInvocation(
                    kind: .help(markdown: "Usage: `/beliefs <topic>`"),
                    input: nil,
                    arguments: [:],
                )
            }
            return SlashCommandInvocation(
                kind: .skill(name: "belief-evolution"),
                input: normalizedInput,
                arguments: topicArguments(normalizedInput),
            )
        default:
            let skillName = String(command)
            return SlashCommandInvocation(
                kind: .skill(name: skillName),
                input: normalizedInput,
                arguments: normalizedInput.map { ["input": $0] } ?? [:],
            )
        }
    }

    private static func topicArguments(_ topic: String?) -> [String: String] {
        topic.map { ["topic": $0] } ?? [:]
    }
}
