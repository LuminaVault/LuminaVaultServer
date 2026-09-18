@testable import App
import Foundation
import Testing

/// The path guards on the workspace surface.
///
/// `validateRelative` is the one that matters. The diff endpoint takes a repo
/// path and a file path; without this, a file parameter that walks upward
/// would let a caller read anything the agent can reach by asking for a diff
/// of it.
@Suite("Hermes workspace path validation")
struct HermesWorkspacePathTests {
    @Test("A plain relative path is accepted and returned unchanged")
    func acceptsRelativePaths() throws {
        #expect(try HermesMirrorPath.validateRelative("Sources/App/main.swift") == "Sources/App/main.swift")
        #expect(try HermesMirrorPath.validateRelative("README.md") == "README.md")
        #expect(try HermesMirrorPath.validateRelative("  a/b.swift  ") == "a/b.swift")
    }

    /// The whole reason the function exists.
    @Test("Traversal segments are rejected")
    func rejectsTraversal() {
        for path in [
            "../etc/passwd",
            "a/../../etc/passwd",
            "a/./b",
            "..",
            ".",
            "a/..",
        ] {
            #expect(throws: (any Error).self, "accepted \(path)") {
                try HermesMirrorPath.validateRelative(path)
            }
        }
    }

    /// An absolute path is not relative. Accepting one would let a caller
    /// name a file outside the repo entirely.
    @Test("Absolute paths are rejected")
    func rejectsAbsolute() {
        for path in ["/etc/passwd", "/", "/a/b"] {
            #expect(throws: (any Error).self, "accepted \(path)") {
                try HermesMirrorPath.validateRelative(path)
            }
        }
    }

    @Test("Empty, blank and null-bearing paths are rejected")
    func rejectsEmptyAndNull() {
        for path in ["", "   ", "a\u{0}b", "a//b"] {
            #expect(throws: (any Error).self, "accepted \(String(reflecting: path))") {
                try HermesMirrorPath.validateRelative(path)
            }
        }
    }

    /// The absolute validator keeps its own contract: the two are not
    /// interchangeable, and swapping them would open the same hole.
    @Test("The absolute validator still demands a leading slash")
    func absoluteValidatorUnchanged() throws {
        #expect(try HermesMirrorPath.validate("/work/repo") == "/work/repo")
        #expect(throws: (any Error).self) { try HermesMirrorPath.validate("work/repo") }
        #expect(throws: (any Error).self) { try HermesMirrorPath.validate("/work/../etc") }
    }
}
