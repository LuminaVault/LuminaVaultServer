import Foundation
import NIOCore
import NIOPosix

/// The `kb-*` skills LuminaVault ships (`Sources/App/Resources/HermesSkills/`,
/// declared `.copy` so the per-skill tree survives). One source of truth for
/// the Hermes image (`docker/hermes.Dockerfile`) and for installing the
/// skills onto a user's own Hermes when a vault is created there.
struct HermesBundledSkills: Sendable {
    struct Skill: Sendable, Equatable {
        let name: String
        let content: String
    }

    let root: URL?
    let threadPool: NIOThreadPool

    init(root: URL? = Bundle.module.resourceURL?.appendingPathComponent("HermesSkills", isDirectory: true), threadPool: NIOThreadPool = .singleton) {
        self.root = root
        self.threadPool = threadPool
    }

    /// The compile skill the nightly cron invokes.
    static let compileSkillName = "kb-compile"

    /// Every bundled `kb-*` skill's `SKILL.md`, sorted by name.
    func kbSkills() async throws -> [Skill] {
        guard let root else { return [] }
        return try await threadPool.runIfActive {
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else { return [] }
            return try fm.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix("kb-") }
                .sorted()
                .compactMap { name in
                    let file = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("SKILL.md")
                    guard let data = fm.contents(atPath: file.path), let content = String(data: data, encoding: .utf8) else { return nil }
                    return Skill(name: name, content: content)
                }
        }
    }
}
