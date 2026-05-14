@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// HER-200 L2 — `Memory.savedID` typed accessor + non-throwing
/// `MemoryDTO.fromMemory`.
struct MemorySavedIDTests {
    @Test
    func `savedID returns id when memory was fetched (id set)`() {
        let id = UUID()
        let memory = Memory(id: id, tenantID: UUID(), content: "x")
        #expect(memory.savedID == id)
    }

    @Test
    func `fromMemory builds DTO non-throwing on hydrated model`() {
        let memID = UUID()
        let tenantID = UUID()
        let memory = Memory(id: memID, tenantID: tenantID, content: "hello", tags: ["tag1", "tag2"])
        let dto = MemoryDTO.fromMemory(memory)
        #expect(dto.id == memID)
        #expect(dto.content == "hello")
        #expect(dto.tags == ["tag1", "tag2"])
    }

    @Test
    func `fromMemory normalizes nil tags to empty array`() {
        let memory = Memory(id: UUID(), tenantID: UUID(), content: "x", tags: nil)
        let dto = MemoryDTO.fromMemory(memory)
        #expect(dto.tags.isEmpty)
    }

    @Test
    func `fromMemory preserves createdAt when populated`() {
        let memory = Memory(id: UUID(), tenantID: UUID(), content: "x")
        let now = Date()
        memory.createdAt = now
        let dto = MemoryDTO.fromMemory(memory)
        #expect(dto.createdAt == now)
    }
}
