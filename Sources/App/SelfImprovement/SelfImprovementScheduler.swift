import Foundation
import Logging
import ServiceLifecycle

actor SelfImprovementScheduler: Service {
    private let service: SelfImprovementService
    private let logger: Logger
    private let interval: Duration

    init(service: SelfImprovementService, logger: Logger, interval: Duration = .seconds(15)) {
        self.service = service
        self.logger = logger
        self.interval = interval
    }

    func run() async throws {
        logger.info("self_improvement.scheduler_started")
        while !Task.isCancelled, !Task.isShuttingDownGracefully {
            await service.tick()
            try? await Task.sleep(for: interval)
        }
    }
}
