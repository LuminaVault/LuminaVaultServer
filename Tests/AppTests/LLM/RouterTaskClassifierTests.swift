import LuminaVaultShared
import Testing
@testable import App

@Suite("Cerberus task classification")
struct RouterTaskClassifierTests {
    @Test("Classifies representative prompts")
    func representativePrompts() {
        #expect(RouterTaskClassifier.classify("Debug this Swift function", surface: .chat) == .coding)
        #expect(RouterTaskClassifier.classify("Summarize these meeting notes", surface: .chat) == .summarization)
        #expect(RouterTaskClassifier.classify("Compare the trade-offs", surface: .chat) == .reasoning)
        #expect(RouterTaskClassifier.classify("What is the latest news?", surface: .chat) == .search)
        #expect(RouterTaskClassifier.classify("Hello there", surface: .chat) == .general)
    }

    @Test("Automation surfaces take precedence over prompt keywords")
    func automationSurfacePrecedence() {
        #expect(RouterTaskClassifier.classify("Summarize this", surface: .job) == .automation)
        #expect(RouterTaskClassifier.classify("Write Swift code", surface: .skill) == .automation)
    }
}
