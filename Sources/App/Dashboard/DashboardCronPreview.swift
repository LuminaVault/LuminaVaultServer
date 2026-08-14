import Foundation
import LuminaVaultShared

protocol DashboardCronPreviewing: Sendable {
    func cronPreview(tenantID: UUID) async -> [DashboardCronJobDTO]
}

struct CronBridgePreview: DashboardCronPreviewing, @unchecked Sendable {
    let bridge: CronBridgeService

    func cronPreview(tenantID: UUID) async -> [DashboardCronJobDTO] {
        do {
            let list = try await bridge.list(tenantID: tenantID)
            return list.jobs.prefix(5).map { job in
                DashboardCronJobDTO(
                    id: job.id,
                    name: job.name,
                    schedule: job.schedule,
                    lastRun: job.lastRun,
                    status: job.status
                )
            }
        } catch {
            return []
        }
    }
}
