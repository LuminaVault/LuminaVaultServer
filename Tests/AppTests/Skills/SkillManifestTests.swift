@testable import App
import Foundation
import Testing

/// HER-167 — `SkillManifestParser` real coverage. Every built-in SKILL.md
/// must parse cleanly, expose the expected required-field invariants,
/// and strip frontmatter from the body. Malformed cases must surface a
/// descriptive `SkillManifestError` rather than partially load.
struct SkillManifestTests {
    /// Built-in skill names shipped via `Resources/Skills/<name>/SKILL.md`.
    /// Adding a new built-in means adding it here too.
    private static let builtinSkillNames = [
        "daily-brief",
        "kb-compile",
        "weekly-memo",
        "health-correlate",
        "capture-enrich",
        "belief-evolution",
        "pattern-detector",
        "contradiction-detector",
        "lapse-archiver",
    ]

    private static func loadBuiltin(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: "SKILL",
                withExtension: "md",
                subdirectory: "Skills/\(name)",
            ),
            "missing built-in SKILL.md for \(name)",
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test
    func `builtin resources are present and non empty`() throws {
        for name in Self.builtinSkillNames {
            let contents = try Self.loadBuiltin(name)
            #expect(contents.hasPrefix("---\n"), "frontmatter must lead \(name)/SKILL.md")
            #expect(contents.contains("name: \(name)"), "frontmatter name must match dir for \(name)")
        }
    }

    @Test
    func `parser succeeds on every builtin manifest`() throws {
        let parser = SkillManifestParser()
        for name in Self.builtinSkillNames {
            let contents = try Self.loadBuiltin(name)
            let manifest: SkillManifest
            do {
                manifest = try parser.parse(source: .builtin, contents: contents)
            } catch {
                Issue.record("\(name) failed to parse: \(error)")
                continue
            }
            #expect(manifest.source == .builtin)
            #expect(manifest.name == name)
            #expect(!manifest.description.isEmpty)
            // Capability must decode to one of the three valid cases.
            #expect([.low, .medium, .high].contains(manifest.capability))
            // Frontmatter must be stripped from the body — the body never
            // contains the closing `---` delimiter.
            #expect(!manifest.body.contains("---\nname: \(name)"))
            #expect(!manifest.body.contains("metadata:"))
        }
    }

    @Test
    func `allowed-tools accepts space separated string`() throws {
        let yaml = """
        ---
        name: tool-string
        description: Test allowed-tools as space-separated string.
        allowed-tools: session_search vault_read memory_upsert
        metadata:
          capability: low
        ---
        body
        """
        let manifest = try SkillManifestParser().parse(source: .builtin, contents: yaml)
        #expect(manifest.allowedTools == ["session_search", "vault_read", "memory_upsert"])
    }

    @Test
    func `allowed-tools accepts yaml array`() throws {
        let yaml = """
        ---
        name: tool-array
        description: Test allowed-tools as YAML array.
        allowed-tools: [session_search, vault_read]
        metadata:
          capability: medium
        ---
        body
        """
        let manifest = try SkillManifestParser().parse(source: .builtin, contents: yaml)
        #expect(manifest.allowedTools == ["session_search", "vault_read"])
    }

    @Test
    func `outputs and daily run cap decode correctly`() throws {
        let yaml = """
        ---
        name: full-meta
        description: All optional metadata populated.
        allowed-tools: session_search
        metadata:
          capability: high
          schedule: "0 7 * * *"
          on_event: [vault_file_created, memory_upserted]
          outputs:
            - kind: memo
              path: memos/{date}/full.md
            - kind: apns_digest
            - kind: vault_rewrite
              category: reflection
          daily_run_cap:
            trial: 1
            pro: 3
            ultimate: 0
        ---
        body
        """
        let manifest = try SkillManifestParser().parse(source: .vault, contents: yaml)
        #expect(manifest.source == .vault)
        #expect(manifest.capability == .high)
        #expect(manifest.schedule == "0 7 * * *")
        #expect(manifest.onEvent == ["vault_file_created", "memory_upserted"])
        #expect(manifest.outputs.count == 3)
        #expect(manifest.outputs[0].kind == .memo)
        #expect(manifest.outputs[0].path == "memos/{date}/full.md")
        #expect(manifest.outputs[1].kind == .apnsDigest)
        #expect(manifest.outputs[2].kind == .vaultRewrite)
        #expect(manifest.outputs[2].category == "reflection")
        #expect(manifest.dailyRunCap?.trial == 1)
        #expect(manifest.dailyRunCap?.pro == 3)
        #expect(manifest.dailyRunCap?.ultimate == 0)
    }

    @Test
    func `missing frontmatter is rejected`() throws {
        let yaml = "no frontmatter at all\njust body"
        #expect(throws: SkillManifestError.missingFrontmatter) {
            _ = try SkillManifestParser().parse(source: .builtin, contents: yaml)
        }
    }

    @Test
    func `unclosed frontmatter is rejected with descriptive error`() throws {
        let yaml = """
        ---
        name: dangling
        description: never closed
        """
        do {
            _ = try SkillManifestParser().parse(source: .builtin, contents: yaml)
            Issue.record("expected throw")
        } catch let SkillManifestError.malformedFrontmatter(reason) {
            #expect(reason.contains("closing"), "reason should mention the missing closing delimiter, got: \(reason)")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test
    func `missing required name is rejected`() throws {
        let yaml = """
        ---
        description: no name field
        metadata:
          capability: low
        ---
        body
        """
        #expect(throws: SkillManifestError.missingRequiredField("name")) {
            _ = try SkillManifestParser().parse(source: .builtin, contents: yaml)
        }
    }

    @Test
    func `missing required description is rejected`() throws {
        let yaml = """
        ---
        name: no-desc
        metadata:
          capability: low
        ---
        body
        """
        #expect(throws: SkillManifestError.missingRequiredField("description")) {
            _ = try SkillManifestParser().parse(source: .builtin, contents: yaml)
        }
    }

    @Test
    func `missing required capability is rejected`() throws {
        let yaml = """
        ---
        name: no-cap
        description: missing metadata.capability
        ---
        body
        """
        #expect(throws: SkillManifestError.missingRequiredField("metadata.capability")) {
            _ = try SkillManifestParser().parse(source: .builtin, contents: yaml)
        }
    }

    @Test
    func `invalid capability value is rejected`() throws {
        let yaml = """
        ---
        name: bad-cap
        description: capability outside the enum
        metadata:
          capability: extreme
        ---
        body
        """
        #expect(throws: SkillManifestError.invalidCapability("extreme")) {
            _ = try SkillManifestParser().parse(source: .builtin, contents: yaml)
        }
    }

    @Test
    func `invalid output kind is rejected`() throws {
        let yaml = """
        ---
        name: bad-output
        description: output kind outside the enum
        metadata:
          capability: low
          outputs:
            - kind: telegram_message
        ---
        body
        """
        #expect(throws: SkillManifestError.invalidOutputKind("telegram_message")) {
            _ = try SkillManifestParser().parse(source: .builtin, contents: yaml)
        }
    }

    @Test
    func `body strips frontmatter and trims surrounding whitespace`() throws {
        let yaml = """
        ---
        name: body-test
        description: Body capture sanity.
        metadata:
          capability: low
        ---


        First body line.

        Second body line.

        """
        let manifest = try SkillManifestParser().parse(source: .builtin, contents: yaml)
        #expect(manifest.body == "First body line.\n\nSecond body line.")
    }
}
