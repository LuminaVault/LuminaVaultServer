@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// Dynamic model listing — provider-specific parsers behind
/// `GET /v1/me/providers/{provider}/models`, plus the credential-target
/// registration regression (gemini was missing from the set).
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct ProviderModelListingTests {
    @Test("every ProviderID maps into userCredentialTargets")
    func credentialTargetsCoverWireProviders() {
        // Every wire-facing provider the client can store a credential for
        // must be a user-credential routing target — `.gemini` regressed
        // out of this set once.
        for id in ProviderID.allCases {
            let kind = ProviderKind(rawValue: id.rawValue)
            #expect(kind != nil, "ProviderID.\(id.rawValue) has no ProviderKind twin")
            if let kind {
                #expect(
                    ProviderKind.userCredentialTargets.contains(kind),
                    "\(kind) missing from userCredentialTargets"
                )
            }
        }
    }

    @Test("OpenAI-shape parser falls back to display_name (Anthropic)")
    func parseModelsAnthropicDisplayName() {
        let body = """
        {"data":[
            {"id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5"},
            {"id":"claude-opus-4-1"}
        ]}
        """.data(using: .utf8)!
        let models = ProvidersController.parseModels(body)
        #expect(models?.count == 2)
        #expect(models?.first?.displayName == "Claude Sonnet 4.5")
        #expect(models?.last?.displayName == "claude-opus-4-1")
    }

    @Test("Gemini parser strips prefix and filters non-chat models")
    func parseGeminiModels() {
        let body = """
        {"models":[
            {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash",
             "supportedGenerationMethods":["generateContent","countTokens"]},
            {"name":"models/text-embedding-004","displayName":"Embedding",
             "supportedGenerationMethods":["embedContent"]},
            {"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent"]}
        ]}
        """.data(using: .utf8)!
        let models = ProvidersController.parseGeminiModels(body)
        #expect(models?.map(\.id) == ["gemini-2.5-flash", "gemini-2.5-pro"])
        #expect(models?.first?.displayName == "Gemini 2.5 Flash")
        #expect(models?.last?.displayName == "gemini-2.5-pro")
    }

    @Test("Ollama parser reads /api/tags names")
    func parseOllamaModels() {
        let body = """
        {"models":[{"name":"llama3:8b","size":123},{"name":"qwen2.5:14b"}]}
        """.data(using: .utf8)!
        let models = ProvidersController.parseOllamaModels(body)
        #expect(models?.map(\.id) == ["llama3:8b", "qwen2.5:14b"])
    }

    @Test("parsers return nil on unexpected shapes")
    func parsersRejectGarbage() {
        let garbage = "{\"unexpected\":true}".data(using: .utf8)!
        #expect(ProvidersController.parseGeminiModels(garbage) == nil)
        #expect(ProvidersController.parseOllamaModels(garbage) == nil)
        #expect(ProvidersController.parseModels(garbage) == nil)
    }
}
