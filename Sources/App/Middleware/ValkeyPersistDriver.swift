import Foundation
import Hummingbird
import Logging
import ServiceLifecycle
import Valkey

struct ValkeyPersistConfiguration: Sendable {
    let address: ValkeyServerAddress
    let client: ValkeyClientConfiguration

    init(url rawURL: String) throws {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            throw RateLimitStorageConfigurationError.invalidRedisURL(rawURL)
        }
        guard scheme == "redis" || scheme == "valkey" else {
            throw RateLimitStorageConfigurationError.unsupportedRedisScheme(scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw RateLimitStorageConfigurationError.invalidRedisURL(rawURL)
        }

        let port = components.port ?? 6379
        var configuration = ValkeyClientConfiguration(
            commandTimeout: .seconds(3),
            blockingCommandTimeout: .seconds(10)
        )
        if let password = components.percentEncodedPassword?.removingPercentEncoding,
           !password.isEmpty
        {
            let username = components.percentEncodedUser?.removingPercentEncoding
            configuration.authentication = .init(
                username: (username?.isEmpty == false ? username! : "default"),
                password: password
            )
        }
        if components.path.count > 1 {
            let dbString = String(components.path.dropFirst())
            guard let database = Int(dbString), database >= 0 else {
                throw RateLimitStorageConfigurationError.invalidRedisDatabase(dbString)
            }
            configuration.databaseNumber = database
        }

        self.address = .hostname(host, port: port)
        self.client = configuration
    }
}

final class ValkeyPersistDriver: PersistDriver {
    private struct Envelope: Codable, Sendable {
        let payload: Data
        let expiresAt: Date?
    }

    private let client: ValkeyClient
    private let namespace: String
    private let logger: Logger

    init(client: ValkeyClient, namespace: String = "lv:persist", logger: Logger) {
        self.client = client
        self.namespace = namespace.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        self.logger = logger
    }

    convenience init(
        configuration: ValkeyPersistConfiguration,
        namespace: String = "lv:persist",
        logger: Logger
    ) {
        self.init(
            client: ValkeyClient(
                configuration.address,
                configuration: configuration.client,
                logger: logger
            ),
            namespace: namespace,
            logger: logger
        )
    }

    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [client] in
                await client.run()
            }
            do {
                try await verifyReady()
                try? await gracefulShutdown()
                group.cancelAll()
            } catch {
                group.cancelAll()
                logger.critical("Valkey rate-limit storage failed readiness check", metadata: ["error": .string("\(error)")])
                throw error
            }
        }
    }

    func shutdown() async throws {}

    func create<Object: Codable & Sendable>(key: String, value: Object, expires: Duration?) async throws {
        if try await readEnvelope(key: key) != nil {
            throw PersistError.duplicate
        }
        try await writeEnvelope(key: key, value: value, expiresAt: expires.map(expirationDate))
    }

    func set<Object: Codable & Sendable>(key: String, value: Object, expires: Duration?) async throws {
        let existing = try await readEnvelope(key: key)
        let expiresAt = expires.map(expirationDate) ?? existing?.expiresAt
        try await writeEnvelope(key: key, value: value, expiresAt: expiresAt)
    }

    func get<Object: Codable & Sendable>(key: String, as: Object.Type) async throws -> Object? {
        guard let envelope = try await readLiveEnvelope(key: key) else { return nil }
        do {
            return try JSONDecoder().decode(Object.self, from: envelope.payload)
        } catch {
            throw PersistError.invalidConversion
        }
    }

    func getWithTTL<Object: Codable & Sendable>(
        key: String,
        as: Object.Type
    ) async throws -> (object: Object, ttl: Duration?)? {
        guard let envelope = try await readLiveEnvelope(key: key) else { return nil }
        let object: Object
        do {
            object = try JSONDecoder().decode(Object.self, from: envelope.payload)
        } catch {
            throw PersistError.invalidConversion
        }
        let ttl = envelope.expiresAt.map { max(0, $0.timeIntervalSinceNow) }.map { Duration.milliseconds(Int($0 * 1_000)) }
        return (object, ttl)
    }

    func remove(key: String) async throws {
        _ = try await client.del(keys: [ValkeyKey(storageKey(key))])
    }

    private func verifyReady() async throws {
        let key = "health:\(UUID().uuidString)"
        try await set(key: key, value: "ok", expires: .seconds(5))
        _ = try await get(key: key, as: String.self)
        try await remove(key: key)
    }

    private func readLiveEnvelope(key: String) async throws -> Envelope? {
        guard let envelope = try await readEnvelope(key: key) else { return nil }
        if let expiresAt = envelope.expiresAt, expiresAt <= Date() {
            try? await remove(key: key)
            return nil
        }
        return envelope
    }

    private func readEnvelope(key: String) async throws -> Envelope? {
        guard let raw = try await client.get(ValkeyKey(storageKey(key))),
              let data = Data(base64Encoded: String(raw))
        else {
            return nil
        }
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    private func writeEnvelope<Object: Codable & Sendable>(
        key: String,
        value: Object,
        expiresAt: Date?
    ) async throws {
        let payload = try JSONEncoder().encode(value)
        let envelope = Envelope(payload: payload, expiresAt: expiresAt)
        let encoded = try JSONEncoder().encode(envelope).base64EncodedString()
        let expiration: SET<String>.Expiration? = expiresAt.map { .unixTimeMilliseconds($0) }
        try await client.set(ValkeyKey(storageKey(key)), value: encoded, expiration: expiration)
    }

    private func expirationDate(after duration: Duration) -> Date {
        Date().addingTimeInterval(timeInterval(from: duration))
    }

    private func timeInterval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func storageKey(_ key: String) -> String {
        "\(namespace):\(key)"
    }
}
