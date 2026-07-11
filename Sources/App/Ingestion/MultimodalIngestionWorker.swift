import Logging
import ServiceLifecycle

actor MultimodalIngestionWorker: Service {
    let service: MultimodalIngestionService
    let logger: Logger
    let idleInterval: Duration

    init(
        service: MultimodalIngestionService,
        logger: Logger = Logger(label: "lv.ingestion.worker"),
        idleInterval: Duration = .seconds(2)
    ) {
        self.service = service
        self.logger = logger
        self.idleInterval = idleInterval
    }

    func run() async throws {
        logger.info("multimodal ingestion worker started")
        while !Task.isCancelled {
            do {
                let processed = try await service.processNext()
                if !processed {
                    try await Task.sleep(for: idleInterval)
                }
            } catch is CancellationError {
                return
            } catch {
                logger.warning("multimodal ingestion tick failed: \(error)")
                try? await Task.sleep(for: idleInterval)
            }
        }
    }
}
