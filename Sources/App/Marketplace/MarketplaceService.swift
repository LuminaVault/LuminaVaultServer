import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

struct MarketplaceListingCreateRequest: Codable {
    let slug: String
    let name: String
    let summary: String
    let description: String
    let category: PluginCategory
    let iconURL: String?
    let screenshots: [String]?
}

struct MarketplaceVersionCreateRequest: Codable {
    let version: String
    let runtimeKind: MarketplaceRuntimeKind
    let permissions: [PluginPermission]
    let networkHosts: [String]?
    let configFields: [PluginConfigField]?
    let changelog: String?
    let artifactKey: String?
    let artifactSHA256: String?
    let manifestJSON: String?
}

struct MarketplaceSubmissionsResponse: Codable {
    let items: [MarketplaceSubmissionDTO]
}

struct MarketplaceService {
    let fluent: Fluent
    let logger: Logger
    let runner: any PluginRunnerClienting
    let artifactRoot: String

    init(
        fluent: Fluent,
        logger: Logger,
        runner: any PluginRunnerClienting = DisabledPluginRunnerClient(),
        artifactRoot: String = "/tmp/luminavault-plugin-artifacts"
    ) {
        self.fluent = fluent
        self.logger = logger
        self.runner = runner
        self.artifactRoot = artifactRoot
    }

    private var db: any Database {
        fluent.db()
    }

    func list(query: String?, category: PluginCategory?, featured: Bool?, cursor: String?, limit: Int) async throws -> MarketplaceListResponse {
        try await ensureFirstPartyCatalog()
        let rows = try await MarketplaceListing.query(on: db)
            .filter(\.$status == MarketplacePluginStatus.published.rawValue)
            .sort(\.$featured, .descending)
            .sort(\.$name, .ascending)
            .all()
        let normalized = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = rows.filter { row in
            (category == nil || row.category == category?.rawValue)
                && (featured == nil || row.featured == featured)
                && (normalized == nil || normalized!.isEmpty
                    || row.name.lowercased().contains(normalized!)
                    || row.summary.lowercased().contains(normalized!))
        }
        let offset = Int(cursor ?? "0") ?? 0
        let page = Array(filtered.dropFirst(max(0, offset)).prefix(limit))
        let items = try await page.asyncMap { try await detail(row: $0) }
        let next = offset + page.count < filtered.count ? String(offset + page.count) : nil
        return MarketplaceListResponse(items: items, nextCursor: next)
    }

    func detail(slug: String) async throws -> MarketplacePluginDTO {
        try await ensureFirstPartyCatalog()
        guard let row = try await MarketplaceListing.query(on: db)
            .filter(\.$slug == slug)
            .filter(\.$status == MarketplacePluginStatus.published.rawValue)
            .first()
        else { throw HTTPError(.notFound, message: "marketplace_plugin_not_found") }
        return try await detail(row: row)
    }

    func reviews(slug: String) async throws -> MarketplaceReviewsResponse {
        let listing = try await requireListing(slug: slug)
        let listingID = try listing.requireID()
        let rows = try await MarketplaceRating.query(on: db)
            .filter(\.$listingID == listingID)
            .filter(\.$moderationStatus == "published")
            .sort(\.$createdAt, .descending)
            .all()
        var items: [MarketplaceReviewDTO] = []
        for row in rows {
            guard let user = try await User.find(row.userID, on: db) else { continue }
            try items.append(MarketplaceReviewDTO(
                id: row.requireID(), rating: row.rating, body: row.body,
                authorUsername: user.username, verifiedInstall: true,
                createdAt: row.createdAt, updatedAt: row.updatedAt
            ))
        }
        return MarketplaceReviewsResponse(items: items)
    }

    func rate(slug: String, userID: UUID, request: MarketplaceRatingRequest) async throws -> MarketplaceReviewDTO {
        guard (1 ... 5).contains(request.rating) else {
            throw HTTPError(.unprocessableContent, message: "rating_must_be_1_to_5")
        }
        let body = request.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body?.count ?? 0 <= 2000 else {
            throw HTTPError(.init(code: 413, reasonPhrase: "Payload Too Large"), message: "review_too_long")
        }
        let listing = try await requireListing(slug: slug)
        let listingID = try listing.requireID()
        guard try await PluginInstall.query(on: db)
            .filter(\.$tenantID == userID)
            .filter(\.$pluginSlug == slug)
            .first() != nil
        else { throw HTTPError(.forbidden, message: "verified_install_required") }
        guard let publisher = try await MarketplacePublisher.find(listing.publisherID, on: db), publisher.ownerUserID != userID else {
            throw HTTPError(.forbidden, message: "publishers_cannot_rate_own_plugin")
        }
        let row = try await MarketplaceRating.query(on: db)
            .filter(\.$listingID == listingID)
            .filter(\.$userID == userID)
            .first() ?? MarketplaceRating()
        row.listingID = listingID
        row.userID = userID
        row.rating = request.rating
        row.body = body?.isEmpty == true ? nil : body
        row.moderationStatus = "published"
        try await row.save(on: db)
        let user = try await requireUser(id: userID)
        return try MarketplaceReviewDTO(
            id: row.requireID(), rating: row.rating, body: row.body,
            authorUsername: user.username, verifiedInstall: true,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }

    func applyPublisher(userID: UUID, request: PublisherApplicationRequest) async throws -> MarketplacePublisherDTO {
        let handle = try Self.normalizedSlug(request.handle)
        guard request.displayName.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            throw HTTPError(.unprocessableContent, message: "publisher_display_name_required")
        }
        if let existing = try await MarketplacePublisher.query(on: db).filter(\.$ownerUserID == userID).first() {
            return try Self.publisherDTO(existing)
        }
        let row = try MarketplacePublisher(
            ownerUserID: userID, handle: handle,
            displayName: request.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            bio: request.bio, websiteURL: Self.validHTTPSURL(request.websiteURL)
        )
        do { try await row.create(on: db) }
        catch { throw HTTPError(.conflict, message: "publisher_handle_unavailable") }
        return try Self.publisherDTO(row)
    }

    func publisher(userID: UUID) async throws -> MarketplacePublisherDTO {
        guard let row = try await MarketplacePublisher.query(on: db).filter(\.$ownerUserID == userID).first() else {
            throw HTTPError(.notFound, message: "publisher_application_not_found")
        }
        return try Self.publisherDTO(row)
    }

    func createListing(userID: UUID, request: MarketplaceListingCreateRequest) async throws -> MarketplacePluginDTO {
        let publisher = try await requireApprovedPublisher(userID: userID)
        let slug = try Self.normalizedSlug(request.slug)
        let row = MarketplaceListing()
        row.publisherID = try publisher.requireID()
        row.slug = slug
        row.name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        row.summary = request.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        row.descriptionText = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
        row.category = request.category.rawValue
        row.iconURL = try Self.validHTTPSURL(request.iconURL)
        row.screenshots = try (request.screenshots ?? []).map { try Self.requireHTTPSURL($0) }
        row.status = MarketplacePluginStatus.draft.rawValue
        row.featured = false
        guard !row.name.isEmpty, !row.summary.isEmpty, !row.descriptionText.isEmpty else {
            throw HTTPError(.unprocessableContent, message: "listing_metadata_required")
        }
        do { try await row.create(on: db) }
        catch { throw HTTPError(.conflict, message: "plugin_slug_unavailable") }
        let placeholder = MarketplaceVersion()
        placeholder.id = UUID()
        placeholder.listingID = try row.requireID()
        placeholder.version = "0.0.0"
        placeholder.status = MarketplaceVersionStatus.draft.rawValue
        placeholder.runtimeKind = MarketplaceRuntimeKind.declarative.rawValue
        placeholder.permissions = []
        placeholder.networkHosts = []
        placeholder.configFields = []
        return try await detail(row: row, versionOverride: placeholder)
    }

    func createVersion(userID: UUID, slug: String, request: MarketplaceVersionCreateRequest) async throws -> MarketplaceVersionDTO {
        let (listing, _) = try await requireOwnedListing(userID: userID, slug: slug)
        guard Self.isSemver(request.version) else {
            throw HTTPError(.unprocessableContent, message: "invalid_semver")
        }
        guard request.runtimeKind != .native else {
            throw HTTPError(.forbidden, message: "native_runtime_reserved_for_first_party_plugins")
        }
        if let manifestJSON = request.manifestJSON {
            guard let data = manifestJSON.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
            else { throw HTTPError(.unprocessableContent, message: "invalid_plugin_manifest") }
        }
        let permissions = Array(Set(request.permissions.map(\.rawValue))).sorted()
        let hosts = try (request.networkHosts ?? []).map(Self.validHost).sorted()
        guard permissions.contains(PluginPermission.networkFetch.rawValue) || hosts.isEmpty else {
            throw HTTPError(.unprocessableContent, message: "network_hosts_require_network_fetch")
        }
        if request.runtimeKind == .wasm {
            guard let digest = request.artifactSHA256, digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let artifactKey = request.artifactKey, !artifactKey.isEmpty
            else { throw HTTPError(.unprocessableContent, message: "wasm_artifact_required") }
            try verifyArtifact(key: artifactKey, expectedSHA256: digest)
        }
        let row = MarketplaceVersion()
        row.listingID = try listing.requireID()
        row.version = request.version
        row.status = MarketplaceVersionStatus.draft.rawValue
        row.runtimeKind = request.runtimeKind.rawValue
        row.permissions = permissions
        row.networkHosts = hosts
        row.configFields = request.configFields ?? []
        row.changelog = request.changelog
        row.artifactKey = request.artifactKey
        row.artifactSHA256 = request.artifactSHA256
        row.manifestJSON = request.manifestJSON.map { Data($0.utf8) }
        do { try await row.create(on: db) }
        catch { throw HTTPError(.conflict, message: "version_already_exists") }
        return try Self.versionDTO(row)
    }

    func uploadArtifact(userID: UUID, slug: String, request: MarketplaceArtifactUploadRequest) async throws -> MarketplaceArtifactUploadResponse {
        let (_, publisher) = try await requireOwnedListing(userID: userID, slug: slug)
        guard request.fileName.lowercased().hasSuffix(".wasm"),
              !request.fileName.contains("/"), !request.fileName.contains("\\")
        else { throw HTTPError(.unprocessableContent, message: "wasm_file_required") }
        guard let data = Data(base64Encoded: request.bytesBase64), !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
            throw HTTPError(.init(code: 413, reasonPhrase: "Payload Too Large"), message: "wasm_artifact_too_large")
        }
        guard data.starts(with: [0x00, 0x61, 0x73, 0x6D]) else {
            throw HTTPError(.unprocessableContent, message: "invalid_wasm_artifact")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = "\(publisher.handle)/\(slug)/\(digest).wasm"
        let root = URL(fileURLWithPath: artifactRoot, isDirectory: true).standardizedFileURL
        let url = root.appendingPathComponent(key).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw HTTPError(.unprocessableContent, message: "invalid_artifact_key") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return MarketplaceArtifactUploadResponse(artifactKey: key, sha256: digest, sizeBytes: data.count)
    }

    func submit(userID: UUID, slug: String, versionID: UUID) async throws -> MarketplaceSubmissionDTO {
        let (listing, _) = try await requireOwnedListing(userID: userID, slug: slug)
        guard let version = try await MarketplaceVersion.query(on: db)
            .filter(\.$id == versionID).filter(\.$listingID == listing.requireID()).first()
        else { throw HTTPError(.notFound, message: "marketplace_version_not_found") }
        guard version.status == MarketplaceVersionStatus.draft.rawValue || version.status == MarketplaceVersionStatus.rejected.rawValue else {
            throw HTTPError(.conflict, message: "version_not_submittable")
        }
        let errors = Self.validate(version: version)
        version.status = errors.isEmpty ? MarketplaceVersionStatus.inReview.rawValue : MarketplaceVersionStatus.draft.rawValue
        try await version.save(on: db)
        let row = try await MarketplaceSubmission.query(on: db).filter(\.$versionID == versionID).first() ?? MarketplaceSubmission()
        row.versionID = versionID
        row.publisherUserID = userID
        row.status = version.status
        row.validationErrors = errors
        row.submittedAt = errors.isEmpty ? Date() : nil
        row.reviewNote = nil
        row.reviewedAt = nil
        row.reviewedByUserID = nil
        try await row.save(on: db)
        return try Self.submissionDTO(row, slug: slug)
    }

    func submissions(userID: UUID, admin: Bool) async throws -> MarketplaceSubmissionsResponse {
        let rows: [MarketplaceSubmission] = if admin {
            try await MarketplaceSubmission.query(on: db).sort(\.$createdAt, .descending).all()
        } else {
            try await MarketplaceSubmission.query(on: db)
                .filter(\.$publisherUserID == userID).sort(\.$createdAt, .descending).all()
        }
        var items: [MarketplaceSubmissionDTO] = []
        for row in rows {
            guard let version = try await MarketplaceVersion.find(row.versionID, on: db),
                  let listing = try await MarketplaceListing.find(version.listingID, on: db)
            else { continue }
            try items.append(Self.submissionDTO(row, slug: listing.slug))
        }
        return MarketplaceSubmissionsResponse(items: items)
    }

    func moderate(submissionID: UUID, adminUserID: UUID, request: MarketplaceModerationRequest) async throws -> MarketplaceSubmissionDTO {
        guard let admin = try await User.find(adminUserID, on: db), admin.isAdmin else {
            throw HTTPError(.forbidden, message: "admin_required")
        }
        guard let submission = try await MarketplaceSubmission.find(submissionID, on: db),
              let version = try await MarketplaceVersion.find(submission.versionID, on: db),
              let listing = try await MarketplaceListing.find(version.listingID, on: db)
        else { throw HTTPError(.notFound, message: "submission_not_found") }
        guard submission.status == MarketplaceVersionStatus.inReview.rawValue else {
            throw HTTPError(.conflict, message: "submission_not_in_review")
        }
        let status: MarketplaceVersionStatus = request.approved ? .approved : .rejected
        submission.status = status.rawValue
        submission.reviewNote = request.note
        submission.reviewedByUserID = adminUserID
        submission.reviewedAt = Date()
        version.status = status.rawValue
        if request.approved {
            version.publishedAt = Date()
            listing.status = MarketplacePluginStatus.published.rawValue
        }
        try await submission.save(on: db)
        try await version.save(on: db)
        try await listing.save(on: db)
        return try Self.submissionDTO(submission, slug: listing.slug)
    }

    func approvePublisher(ownerUserID: UUID, adminUserID: UUID, approved: Bool) async throws -> MarketplacePublisherDTO {
        guard let admin = try await User.find(adminUserID, on: db), admin.isAdmin else {
            throw HTTPError(.forbidden, message: "admin_required")
        }
        guard let row = try await MarketplacePublisher.query(on: db).filter(\.$ownerUserID == ownerUserID).first() else {
            throw HTTPError(.notFound, message: "publisher_application_not_found")
        }
        row.status = approved ? "approved" : "rejected"
        row.verified = approved
        try await row.save(on: db)
        return try Self.publisherDTO(row)
    }

    func runTool(slug: String, toolName: String, tenantID: UUID, input: [String: String]) async throws -> PluginToolRunResponse {
        guard input.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 1_048_576 else {
            throw HTTPError(.init(code: 413, reasonPhrase: "Payload Too Large"), message: "plugin_input_too_large")
        }
        guard let install = try await PluginInstall.query(on: db)
            .filter(\.$tenantID == tenantID).filter(\.$pluginSlug == slug)
            .filter(\.$status == PluginInstallState.enabled).first(),
            let versionID = install.marketplaceVersionID,
            let version = try await MarketplaceVersion.find(versionID, on: db),
            version.status == MarketplaceVersionStatus.approved.rawValue,
            version.runtimeKind == MarketplaceRuntimeKind.wasm.rawValue,
            let artifactKey = version.artifactKey
        else { throw HTTPError(.conflict, message: "installed_wasm_version_required") }
        guard !artifactKey.contains(".."), !artifactKey.hasPrefix("/"), artifactKey.range(of: "^[a-zA-Z0-9/_-]+\\.wasm$", options: .regularExpression) != nil else {
            throw HTTPError(.unprocessableContent, message: "invalid_artifact_key")
        }
        let root = URL(fileURLWithPath: artifactRoot, isDirectory: true).standardizedFileURL
        let url = root.appendingPathComponent(artifactKey).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: url), data.count <= 10 * 1024 * 1024 else {
            throw HTTPError(.serviceUnavailable, message: "plugin_artifact_unavailable")
        }
        guard let expected = version.artifactSHA256,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected
        else { throw HTTPError(.unprocessableContent, message: "plugin_artifact_digest_mismatch") }

        let row = MarketplaceExecution()
        row.id = UUID()
        row.tenantID = tenantID
        row.installID = try install.requireID()
        row.versionID = versionID
        row.toolName = toolName
        row.status = "running"
        try await row.create(on: db)
        let started = ContinuousClock.now
        do {
            let result = try await runner.execute(module: data, input: input)
            row.status = "succeeded"
            row.durationMS = Int(started.duration(to: .now).components.seconds * 1000)
            try await row.save(on: db)
            return try PluginToolRunResponse(runId: row.requireID(), output: result.output, fuelConsumed: result.fuelConsumed)
        } catch {
            row.status = "failed"
            row.errorCode = "runner_failed"
            row.durationMS = Int(started.duration(to: .now).components.seconds * 1000)
            try? await row.save(on: db)
            throw error
        }
    }

    private func detail(row: MarketplaceListing, versionOverride: MarketplaceVersion? = nil) async throws -> MarketplacePluginDTO {
        guard let publisher = try await MarketplacePublisher.find(row.publisherID, on: db) else {
            throw HTTPError(.internalServerError, message: "marketplace_publisher_missing")
        }
        let version: MarketplaceVersion? = if let versionOverride {
            versionOverride
        } else {
            try await MarketplaceVersion.query(on: db)
                .filter(\.$listingID == row.requireID())
                .filter(\.$status == MarketplaceVersionStatus.approved.rawValue)
                .sort(\.$publishedAt, .descending)
                .first()
        }
        guard let version else { throw HTTPError(.notFound, message: "marketplace_version_not_found") }
        let ratings = try await MarketplaceRating.query(on: db)
            .filter(\.$listingID == row.requireID()).filter(\.$moderationStatus == "published").all()
        let installCount = try await PluginInstall.query(on: db).filter(\.$pluginSlug == row.slug).count()
        let average = ratings.isEmpty ? 0 : Double(ratings.reduce(0) { $0 + $1.rating }) / Double(ratings.count)
        return try MarketplacePluginDTO(
            slug: row.slug, name: row.name, summary: row.summary, description: row.descriptionText,
            category: PluginCategory(rawValue: row.category) ?? .skill,
            iconURL: row.iconURL, screenshots: row.screenshots,
            publisher: Self.publisherDTO(publisher), latestVersion: Self.versionDTO(version),
            featured: row.featured, ratingAverage: average, ratingCount: ratings.count,
            installCount: installCount, configFields: version.configFields
        )
    }

    /// Migrations usually run before the first admin is bootstrapped. Seed the
    /// built-in catalog on first read once a stable system owner exists.
    private func ensureFirstPartyCatalog() async throws {
        if try await MarketplacePublisher.query(on: db).filter(\.$handle == "luminavault").first() != nil {
            return
        }
        guard let admin = try await User.query(on: db).filter(\.$isAdmin == true).first() else {
            return
        }

        let publisher = MarketplacePublisher()
        publisher.id = UUID(uuidString: "00000000-0000-4000-8000-000000000043")!
        publisher.ownerUserID = try admin.requireID()
        publisher.handle = "luminavault"
        publisher.displayName = "LuminaVault"
        publisher.status = "approved"
        publisher.verified = true
        do {
            try await publisher.create(on: db)
        } catch {
            guard try await MarketplacePublisher.query(on: db).filter(\.$handle == "luminavault").first() != nil else {
                throw error
            }
            return
        }

        for entry in PluginCatalog.entries.values.sorted(by: { $0.dto.slug < $1.dto.slug }) {
            let dto = entry.dto
            let listing = MarketplaceListing()
            listing.id = UUID()
            listing.publisherID = try publisher.requireID()
            listing.slug = dto.slug
            listing.name = dto.name
            listing.summary = dto.summary
            listing.descriptionText = dto.description
            listing.category = dto.category.rawValue
            listing.screenshots = []
            listing.status = MarketplacePluginStatus.published.rawValue
            listing.featured = entry.featured
            try await listing.create(on: db)

            let version = MarketplaceVersion()
            version.id = UUID()
            version.listingID = try listing.requireID()
            version.version = dto.version
            version.status = MarketplaceVersionStatus.approved.rawValue
            version.runtimeKind = MarketplaceRuntimeKind.native.rawValue
            version.permissions = []
            version.networkHosts = []
            version.configFields = dto.configFields
            version.publishedAt = Date()
            try await version.create(on: db)
        }
    }

    private func requireListing(slug: String) async throws -> MarketplaceListing {
        guard let row = try await MarketplaceListing.query(on: db).filter(\.$slug == slug).first() else {
            throw HTTPError(.notFound, message: "marketplace_plugin_not_found")
        }
        return row
    }

    private func requireOwnedListing(userID: UUID, slug: String) async throws -> (MarketplaceListing, MarketplacePublisher) {
        let publisher = try await requireApprovedPublisher(userID: userID)
        guard let listing = try await MarketplaceListing.query(on: db)
            .filter(\.$slug == slug).filter(\.$publisherID == publisher.requireID()).first()
        else { throw HTTPError(.notFound, message: "marketplace_plugin_not_found") }
        return (listing, publisher)
    }

    private func requireApprovedPublisher(userID: UUID) async throws -> MarketplacePublisher {
        guard let row = try await MarketplacePublisher.query(on: db).filter(\.$ownerUserID == userID).first(), row.status == "approved" else {
            throw HTTPError(.forbidden, message: "approved_publisher_required")
        }
        return row
    }

    private func requireUser(id: UUID) async throws -> User {
        guard let user = try await User.find(id, on: db) else { throw HTTPError(.notFound, message: "user_not_found") }
        return user
    }

    private static func publisherDTO(_ row: MarketplacePublisher) throws -> MarketplacePublisherDTO {
        try MarketplacePublisherDTO(id: row.requireID(), handle: row.handle, displayName: row.displayName, bio: row.bio, websiteURL: row.websiteURL, verified: row.verified)
    }

    private static func versionDTO(_ row: MarketplaceVersion) throws -> MarketplaceVersionDTO {
        try MarketplaceVersionDTO(
            id: row.requireID(), version: row.version,
            status: MarketplaceVersionStatus(rawValue: row.status) ?? .draft,
            runtimeKind: MarketplaceRuntimeKind(rawValue: row.runtimeKind) ?? .declarative,
            permissions: row.permissions.compactMap(PluginPermission.init(rawValue:)),
            networkHosts: row.networkHosts, changelog: row.changelog, publishedAt: row.publishedAt
        )
    }

    private static func submissionDTO(_ row: MarketplaceSubmission, slug: String) throws -> MarketplaceSubmissionDTO {
        try MarketplaceSubmissionDTO(
            id: row.requireID(), pluginSlug: slug, versionId: row.versionID,
            status: MarketplaceVersionStatus(rawValue: row.status) ?? .draft,
            validationErrors: row.validationErrors, reviewNote: row.reviewNote,
            submittedAt: row.submittedAt, reviewedAt: row.reviewedAt
        )
    }

    private static func normalizedSlug(_ input: String) throws -> String {
        let normalized = input.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard (2 ... 64).contains(normalized.count), normalized.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw HTTPError(.unprocessableContent, message: "invalid_slug")
        }
        return normalized
    }

    private static func isSemver(_ value: String) -> Bool {
        value.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$", options: .regularExpression) != nil
    }

    private static func validHost(_ value: String) throws -> String {
        let host = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("/"), !host.contains(":"), URL(string: "https://\(host)")?.host == host else {
            throw HTTPError(.unprocessableContent, message: "invalid_network_host")
        }
        return host
    }

    private static func validHTTPSURL(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        return try requireHTTPSURL(value)
    }

    private static func requireHTTPSURL(_ value: String) throws -> String {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil else {
            throw HTTPError(.unprocessableContent, message: "https_url_required")
        }
        return value
    }

    private static func validate(version: MarketplaceVersion) -> [String] {
        var errors: [String] = []
        if !isSemver(version.version) {
            errors.append("invalid_semver")
        }
        if version.runtimeKind == MarketplaceRuntimeKind.wasm.rawValue,
           version.artifactKey == nil || version.artifactSHA256 == nil
        {
            errors.append("wasm_artifact_required")
        }
        if !version.networkHosts.isEmpty, !version.permissions.contains(PluginPermission.networkFetch.rawValue) {
            errors.append("network_hosts_require_network_fetch")
        }
        return errors
    }

    private func verifyArtifact(key: String, expectedSHA256: String) throws {
        guard !key.contains(".."), !key.hasPrefix("/"), key.range(of: "^[a-zA-Z0-9/_-]+\\.wasm$", options: .regularExpression) != nil else {
            throw HTTPError(.unprocessableContent, message: "invalid_artifact_key")
        }
        let root = URL(fileURLWithPath: artifactRoot, isDirectory: true).standardizedFileURL
        let url = root.appendingPathComponent(key).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: url), data.count <= 10 * 1024 * 1024 else {
            throw HTTPError(.unprocessableContent, message: "plugin_artifact_unavailable")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else {
            throw HTTPError(.unprocessableContent, message: "plugin_artifact_digest_mismatch")
        }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
