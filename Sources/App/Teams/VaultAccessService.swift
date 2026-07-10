import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent

enum VaultPermission: Sendable {
    case read, write, admin, ai
}

struct ResolvedVaultAccess: Sendable {
    let vaultID: UUID
    let teamID: UUID?
    let billingSponsorUserID: UUID
    let role: String
    let canUseAI: Bool
    let isPersonal: Bool

    var canWrite: Bool {
        role == "editor" || role == "admin"
    }

    var canAdmin: Bool {
        role == "admin"
    }
}

struct VaultAccessService: Sendable {
    static let vaultHeader = HTTPField.Name("X-Vault-ID")!

    let fluent: Fluent

    func resolve(request: Request, context: AppRequestContext,
                 requiring permission: VaultPermission = .read) async throws -> ResolvedVaultAccess
    {
        let requestedID: UUID
        if let raw = request.headers[Self.vaultHeader] {
            guard let parsed = UUID(uuidString: raw) else {
                throw HTTPError(.badRequest, message: "invalid X-Vault-ID")
            }
            requestedID = parsed
        } else {
            requestedID = try context.requireTenantID()
        }

        return try await resolve(vaultID: requestedID, context: context, requiring: permission)
    }

    func resolve(vaultID requestedID: UUID, context: AppRequestContext,
                 requiring permission: VaultPermission = .read) async throws -> ResolvedVaultAccess
    {
        let user = try context.requireIdentity()
        let userID = try user.requireID()

        guard let vault = try await Vault.find(requestedID, on: fluent.db()), vault.archivedAt == nil else {
            throw HTTPError(.notFound, message: "vault not found")
        }

        let access: ResolvedVaultAccess
        if vault.personalOwnerUserID == userID {
            access = .init(vaultID: requestedID, teamID: nil, billingSponsorUserID: userID,
                           role: "admin", canUseAI: true, isPersonal: true)
        } else if let membership = try await VaultMembership.query(on: fluent.db())
            .filter(\.$vaultID == requestedID)
            .filter(\.$userID == userID)
            .first()
        {
            guard let teamID = vault.teamID,
                  let team = try await Team.find(teamID, on: fluent.db()), team.archivedAt == nil
            else {
                throw HTTPError(.notFound, message: "team vault not found")
            }
            access = .init(vaultID: requestedID, teamID: teamID,
                           billingSponsorUserID: team.billingSponsorUserID,
                           role: membership.role, canUseAI: membership.canUseAI, isPersonal: false)
        } else {
            throw HTTPError(.forbidden, message: "vault access denied")
        }

        switch permission {
        case .read:
            break
        case .write where !access.canWrite:
            throw HTTPError(.forbidden, message: "vault write permission required")
        case .admin where !access.canAdmin:
            throw HTTPError(.forbidden, message: "vault admin permission required")
        case .ai where !access.canUseAI:
            throw HTTPError(.forbidden, message: "vault AI access required")
        case .ai:
            guard let sponsor = try await User.find(access.billingSponsorUserID, on: fluent.db()),
                  sponsor.entitled(for: .chat)
            else {
                throw HTTPError(.paymentRequired, message: "team owner subscription does not include AI access")
            }
        default:
            break
        }
        return access
    }
}
