@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// Nothing bounded a tenant's total stored bytes. Per-*file* limits existed —
/// 2 GiB per ingestion item, 5 GiB per batch — but a tenant could repeat a
/// 5 GiB batch indefinitely, and every byte lands in the nightly backup under
/// 7/4/6 retention as well.
struct StorageQuotaServiceTests {
    private let limits = StorageQuotaService.Limits.default

    @Test
    func `each tier gets its own ceiling`() {
        #expect(limits.bytes(for: .trial) == Int64(5 * 1024 * 1024 * 1024))
        #expect(limits.bytes(for: .pro) == Int64(100 * 1024 * 1024 * 1024))
        #expect(limits.bytes(for: .ultimate) == Int64(1024 * 1024 * 1024 * 1024))
    }

    /// A lapsed tenant keeps vault read and export — that is the entire
    /// content of the tier — so the ceiling only has to stop growth.
    @Test
    func `lapsed and archived cannot grow`() {
        #expect(limits.bytes(for: .lapsed) == Int64(0))
        #expect(limits.bytes(for: .archived) == Int64(0))
    }

    @Test
    func `sizes format at the unit a human would use`() {
        #expect(StorageQuotaService.format(0) == "0 B")
        #expect(StorageQuotaService.format(512) == "512 B")
        #expect(StorageQuotaService.format(2 * 1024 * 1024) == "2.0 MiB")
        #expect(StorageQuotaService.format(5 * 1024 * 1024 * 1024) == "5.0 GiB")
        #expect(StorageQuotaService.format(1024 * 1024 * 1024 * 1024) == "1.0 TiB")
    }

    /// The 413 says how much room is left, not just "no".
    @Test
    func `the denial message carries used and limit`() {
        let message = StorageQuotaService.message(
            used: 5 * 1024 * 1024 * 1024,
            limit: 100 * 1024 * 1024 * 1024
        )
        #expect(message == "storage quota exceeded: 5.0 GiB of 100.0 GiB used")
    }

    /// `nil` and `0` must stay distinct. Expressing "no growth" as a zero
    /// *ceiling* reads as no ceiling under any `limit > 0` guard, which would
    /// hand a lapsed tenant unlimited storage — the exact opposite of intent.
    @Test
    func `unlimited and no-growth are different values`() {
        let unlimited = StorageQuotaService.Limits(trial: nil, pro: nil, ultimate: nil, lapsed: nil)
        #expect(unlimited.bytes(for: .trial) == nil)
        #expect(limits.bytes(for: .lapsed) == Int64(0))
        #expect(limits.bytes(for: .lapsed) != nil)
    }

    /// Only a negative configured value opts out; 0 is taken literally.
    @Test
    func `configuration maps onto that sentinel`() {
        #expect(StorageQuotaService.limit(-1) == nil)
        #expect(StorageQuotaService.limit(0) == Int64(0))
        #expect(StorageQuotaService.limit(1024) == Int64(1024))
    }
}
