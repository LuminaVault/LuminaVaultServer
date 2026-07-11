import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent

private struct TeamCreateBody: Decodable { let name: String }
private struct VaultCreateBody: Decodable { let name: String }
private struct MembershipBody: Decodable { let role: String; let canUseAI: Bool }
private struct InviteGrant: Codable { let role: String; let canUseAI: Bool }
private struct InviteBody: Decodable { let email: String; let vaultGrants: [String: InviteGrant] }
private struct OwnershipTransferBody: Decodable { let userID: UUID }

struct TeamResponse: Codable, ResponseEncodable {
    let id: UUID
    let name: String
    let role: String
    let archivedAt: Date?
}

struct VaultResponse: Codable, ResponseEncodable {
    let id: UUID
    let teamID: UUID?
    let name: String
    let isPersonal: Bool
    let role: String
    let canUseAI: Bool
    let archivedAt: Date?
}

struct VaultMemberResponse: Codable, ResponseEncodable {
    let id: UUID
    let userID: UUID
    let username: String
    let email: String
    let role: String
    let canUseAI: Bool
}

struct InvitationResponse: Codable, ResponseEncodable {
    let id: UUID
    let teamID: UUID
    let email: String
    let expiresAt: Date
    let token: String?
}

struct ActivityResponse: Codable, ResponseEncodable {
    let id: UUID
    let vaultID: UUID
    let actorUserID: UUID?
    let actorName: String
    let action: String
    let targetType: String
    let targetID: UUID?
    let targetTitle: String?
    let createdAt: Date
}

struct TeamController {
    let fluent: Fluent
    let vaultPaths: VaultPathService
    let access: VaultAccessService
    let invitationSender: any TeamInvitationSending
    let activityPublisher: VaultActivityPublisher

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: listTeams)
        router.post("", use: createTeam)
        router.get("/:teamID/vaults", use: listTeamVaults)
        router.post("/:teamID/vaults", use: createVault)
        router.post("/:teamID/invitations", use: invite)
        router.get("/:teamID/invitations", use: listInvitations)
        router.post("/:teamID/invitations/:invitationID/resend", use: resendInvitation)
        router.delete("/:teamID/invitations/:invitationID", use: revokeInvitation)
        router.put("/:teamID/owner", use: transferOwnership)
        router.post("/:teamID/archive", use: archiveTeam)
        router.post("/:teamID/restore", use: restoreTeam)
        router.post("/:teamID/leave", use: leaveTeam)
    }

    func addVaultRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: listVaults)
        router.get("/:vaultID/members", use: listMembers)
        router.put("/:vaultID/members/:userID", use: updateMember)
        router.delete("/:vaultID/members/:userID", use: removeMember)
        router.get("/:vaultID/activity", use: activity)
        router.get("/:vaultID/activity/stream", use: activityStream)
    }

    func addInvitationRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/:token/accept", use: acceptInvitation)
    }

    @Sendable func listTeams(_: Request, ctx: AppRequestContext) async throws -> [TeamResponse] {
        try await purgeExpiredArchives()
        let userID = try ctx.requireTenantID()
        let memberships = try await TeamMembership.query(on: fluent.db())
            .filter(\.$userID == userID).all()
        var result: [TeamResponse] = []
        for membership in memberships {
            guard let team = try await Team.find(membership.teamID, on: fluent.db()) else { continue }
            try result.append(.init(id: team.requireID(), name: team.name,
                                    role: membership.role, archivedAt: team.archivedAt))
        }
        return result
    }

    @Sendable func createTeam(_ req: Request, ctx: AppRequestContext) async throws -> TeamResponse {
        let user = try ctx.requireIdentity()
        let userID = try user.requireID()
        let body = try await req.decode(as: TeamCreateBody.self, context: ctx)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 80).contains(name.count) else {
            throw HTTPError(.unprocessableContent, message: "team name must be 2-80 characters")
        }
        let team = Team(name: name, ownerUserID: userID)
        try await team.save(on: fluent.db())
        let teamID = try team.requireID()
        try await TeamMembership(teamID: teamID, userID: userID, role: "owner").save(on: fluent.db())
        return .init(id: teamID, name: name, role: "owner", archivedAt: nil)
    }

    @Sendable func listVaults(_: Request, ctx: AppRequestContext) async throws -> [VaultResponse] {
        let userID = try ctx.requireTenantID()
        let memberships = try await VaultMembership.query(on: fluent.db())
            .filter(\.$userID == userID).all()
        var result: [VaultResponse] = []
        for membership in memberships {
            guard let vault = try await Vault.find(membership.vaultID, on: fluent.db()) else { continue }
            try result.append(.init(id: vault.requireID(), teamID: vault.teamID, name: vault.name,
                                    isPersonal: vault.personalOwnerUserID != nil, role: membership.role,
                                    canUseAI: membership.canUseAI, archivedAt: vault.archivedAt))
        }
        return result.sorted { lhs, rhs in
            if lhs.isPersonal != rhs.isPersonal {
                return lhs.isPersonal
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    @Sendable func listTeamVaults(_: Request, ctx: AppRequestContext) async throws -> [VaultResponse] {
        let teamID = try uuidParameter(ctx, "teamID")
        _ = try await requireTeamRole(teamID: teamID, context: ctx, admin: false)
        let userID = try ctx.requireTenantID()
        let vaults = try await Vault.query(on: fluent.db()).filter(\.$teamID == teamID).all()
        var result: [VaultResponse] = []
        for vault in vaults {
            let vaultID = try vault.requireID()
            guard let membership = try await VaultMembership.query(on: fluent.db())
                .filter(\.$vaultID == vaultID).filter(\.$userID == userID).first() else { continue }
            result.append(.init(id: vaultID, teamID: teamID, name: vault.name, isPersonal: false,
                                role: membership.role, canUseAI: membership.canUseAI,
                                archivedAt: vault.archivedAt))
        }
        return result
    }

    @Sendable func createVault(_ req: Request, ctx: AppRequestContext) async throws -> VaultResponse {
        let teamID = try uuidParameter(ctx, "teamID")
        _ = try await requireTeamRole(teamID: teamID, context: ctx, admin: true)
        guard let team = try await Team.find(teamID, on: fluent.db()), team.archivedAt == nil else {
            throw HTTPError(.notFound, message: "team not found")
        }
        let user = try ctx.requireIdentity()
        let userID = try user.requireID()
        let body = try await req.decode(as: VaultCreateBody.self, context: ctx)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 80).contains(name.count) else {
            throw HTTPError(.unprocessableContent, message: "vault name must be 2-80 characters")
        }
        let vault = Vault(teamID: teamID, name: name)
        try await vault.save(on: fluent.db())
        let vaultID = try vault.requireID()
        try await VaultMembership(vaultID: vaultID, userID: userID, role: "admin",
                                  canUseAI: true, createdByUserID: userID).save(on: fluent.db())
        try vaultPaths.ensureTenantDirectories(for: vaultID)
        try await record(vaultID: vaultID, actor: user, action: "vault.created",
                         targetType: "vault", targetID: vaultID, targetTitle: name)
        return .init(id: vaultID, teamID: teamID, name: name, isPersonal: false,
                     role: "admin", canUseAI: true, archivedAt: nil)
    }

    @Sendable func listMembers(_: Request, ctx: AppRequestContext) async throws -> [VaultMemberResponse] {
        let vaultID = try uuidParameter(ctx, "vaultID")
        _ = try await access.resolve(vaultID: vaultID, context: ctx, requiring: .read)
        let maySeeEmail = await (try? access.resolve(vaultID: vaultID, context: ctx, requiring: .admin)) != nil
        let memberships = try await VaultMembership.query(on: fluent.db())
            .filter(\.$vaultID == vaultID).all()
        var result: [VaultMemberResponse] = []
        for membership in memberships {
            guard let user = try await User.find(membership.userID, on: fluent.db()) else { continue }
            try result.append(.init(id: membership.requireID(), userID: membership.userID,
                                    username: user.username, email: maySeeEmail ? user.email : "",
                                    role: membership.role, canUseAI: membership.canUseAI))
        }
        return result
    }

    @Sendable func updateMember(_ request: Request, ctx: AppRequestContext) async throws -> VaultMemberResponse {
        let vaultID = try uuidParameter(ctx, "vaultID")
        _ = try await access.resolve(vaultID: vaultID, context: ctx, requiring: .admin)
        let targetUserID = try uuidParameter(ctx, "userID")
        let actor = try ctx.requireIdentity()
        let body = try await request.decode(as: MembershipBody.self, context: ctx)
        guard ["viewer", "editor", "admin"].contains(body.role) else {
            throw HTTPError(.unprocessableContent, message: "invalid vault role")
        }
        guard let membership = try await VaultMembership.query(on: fluent.db())
            .filter(\.$vaultID == vaultID).filter(\.$userID == targetUserID).first(),
            let target = try await User.find(targetUserID, on: fluent.db())
        else {
            throw HTTPError(.notFound, message: "vault member not found")
        }
        membership.role = body.role
        membership.canUseAI = body.canUseAI
        try await membership.update(on: fluent.db())
        try await record(vaultID: vaultID, actor: actor, action: "membership.updated",
                         targetType: "member", targetID: targetUserID, targetTitle: target.username)
        return try .init(id: membership.requireID(), userID: targetUserID, username: target.username,
                         email: target.email, role: membership.role, canUseAI: membership.canUseAI)
    }

    @Sendable func removeMember(_: Request, ctx: AppRequestContext) async throws -> Response {
        let vaultID = try uuidParameter(ctx, "vaultID")
        _ = try await access.resolve(vaultID: vaultID, context: ctx, requiring: .admin)
        let targetUserID = try uuidParameter(ctx, "userID")
        guard let vault = try await Vault.find(vaultID, on: fluent.db()),
              let teamID = vault.teamID,
              let team = try await Team.find(teamID, on: fluent.db()),
              team.ownerUserID != targetUserID
        else {
            throw HTTPError(.conflict, message: "transfer team ownership before removing the owner")
        }
        guard let membership = try await VaultMembership.query(on: fluent.db())
            .filter(\.$vaultID == vaultID).filter(\.$userID == targetUserID).first()
        else {
            throw HTTPError(.notFound, message: "vault member not found")
        }
        let actor = try ctx.requireIdentity()
        let targetName = try await User.find(targetUserID, on: fluent.db())?.username ?? "Former member"
        try await membership.delete(on: fluent.db())
        try await record(vaultID: vaultID, actor: actor, action: "membership.removed",
                         targetType: "member", targetID: targetUserID, targetTitle: targetName)
        return Response(status: .noContent)
    }

    @Sendable func transferOwnership(_ request: Request, ctx: AppRequestContext) async throws -> TeamResponse {
        let teamID = try uuidParameter(ctx, "teamID")
        let actorID = try ctx.requireTenantID()
        let current = try await requireTeamRole(teamID: teamID, context: ctx, admin: true)
        guard current.role == "owner" else {
            throw HTTPError(.forbidden, message: "only the team owner can transfer ownership")
        }
        let body = try await request.decode(as: OwnershipTransferBody.self, context: ctx)
        guard body.userID != actorID,
              let target = try await TeamMembership.query(on: fluent.db())
              .filter(\.$teamID == teamID).filter(\.$userID == body.userID).first(),
              let team = try await Team.find(teamID, on: fluent.db())
        else {
            throw HTTPError(.unprocessableContent, message: "new owner must be an existing team member")
        }
        try await fluent.db().transaction { database in
            team.ownerUserID = body.userID
            team.billingSponsorUserID = body.userID
            current.role = "admin"
            target.role = "owner"
            try await team.update(on: database)
            try await current.update(on: database)
            try await target.update(on: database)
        }
        return .init(id: teamID, name: team.name, role: "admin", archivedAt: team.archivedAt)
    }

    @Sendable func archiveTeam(_: Request, ctx: AppRequestContext) async throws -> TeamResponse {
        let teamID = try uuidParameter(ctx, "teamID")
        let membership = try await requireTeamRole(teamID: teamID, context: ctx, admin: true)
        guard membership.role == "owner", let team = try await Team.find(teamID, on: fluent.db()) else {
            throw HTTPError(.forbidden, message: "only the team owner can archive the team")
        }
        let archivedAt = Date()
        team.archivedAt = archivedAt
        try await team.update(on: fluent.db())
        let vaults = try await Vault.query(on: fluent.db()).filter(\.$teamID == teamID).all()
        for vault in vaults {
            vault.archivedAt = archivedAt
            try await vault.update(on: fluent.db())
        }
        return .init(id: teamID, name: team.name, role: membership.role, archivedAt: archivedAt)
    }

    @Sendable func restoreTeam(_: Request, ctx: AppRequestContext) async throws -> TeamResponse {
        let teamID = try uuidParameter(ctx, "teamID")
        let membership = try await requireTeamRole(teamID: teamID, context: ctx, admin: true)
        guard membership.role == "owner", let team = try await Team.find(teamID, on: fluent.db()),
              let archivedAt = team.archivedAt,
              archivedAt > Date().addingTimeInterval(-30 * 24 * 60 * 60)
        else {
            throw HTTPError(.gone, message: "team is not restorable")
        }
        team.archivedAt = nil
        try await team.update(on: fluent.db())
        let vaults = try await Vault.query(on: fluent.db()).filter(\.$teamID == teamID).all()
        for vault in vaults {
            vault.archivedAt = nil
            try await vault.update(on: fluent.db())
        }
        return .init(id: teamID, name: team.name, role: membership.role, archivedAt: nil)
    }

    @Sendable func leaveTeam(_: Request, ctx: AppRequestContext) async throws -> Response {
        let teamID = try uuidParameter(ctx, "teamID")
        let userID = try ctx.requireTenantID()
        let membership = try await requireTeamRole(teamID: teamID, context: ctx, admin: false)
        guard membership.role != "owner" else {
            throw HTTPError(.conflict, message: "transfer ownership before leaving")
        }
        let vaults = try await Vault.query(on: fluent.db()).filter(\.$teamID == teamID).all()
        for vault in vaults {
            guard let vaultID = try? vault.requireID() else { continue }
            try await VaultMembership.query(on: fluent.db())
                .filter(\.$vaultID == vaultID).filter(\.$userID == userID).delete()
        }
        try await membership.delete(on: fluent.db())
        return Response(status: .noContent)
    }

    @Sendable func invite(_ request: Request, ctx: AppRequestContext) async throws -> InvitationResponse {
        let teamID = try uuidParameter(ctx, "teamID")
        _ = try await requireTeamRole(teamID: teamID, context: ctx, admin: true)
        guard let team = try await Team.find(teamID, on: fluent.db()), team.archivedAt == nil else {
            throw HTTPError(.notFound, message: "team not found")
        }
        let actor = try ctx.requireIdentity()
        let actorID = try actor.requireID()
        let body = try await request.decode(as: InviteBody.self, context: ctx)
        let email = body.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), !body.vaultGrants.isEmpty else {
            throw HTTPError(.unprocessableContent, message: "email and at least one vault grant are required")
        }
        if try await TeamInvitation.query(on: fluent.db())
            .filter(\.$teamID == teamID)
            .filter(\.$email == email)
            .filter(\.$acceptedAt == nil)
            .filter(\.$revokedAt == nil)
            .filter(\.$expiresAt > Date())
            .first() != nil
        {
            throw HTTPError(.conflict, message: "a pending invitation already exists for this email")
        }
        for (rawID, grant) in body.vaultGrants {
            guard let vaultID = UUID(uuidString: rawID),
                  let vault = try await Vault.find(vaultID, on: fluent.db()), vault.teamID == teamID,
                  ["viewer", "editor", "admin"].contains(grant.role)
            else {
                throw HTTPError(.unprocessableContent, message: "invalid invitation vault grant")
            }
        }
        let token = UUID().uuidString + UUID().uuidString
        let invitation = TeamInvitation()
        invitation.teamID = teamID
        invitation.email = email
        invitation.tokenHash = hash(token)
        invitation.vaultGrants = try String(decoding: JSONEncoder().encode(body.vaultGrants), as: UTF8.self)
        invitation.invitedByUserID = actorID
        invitation.expiresAt = Date().addingTimeInterval(7 * 24 * 60 * 60)
        try await invitation.save(on: fluent.db())
        do {
            try await invitationSender.send(to: email, teamName: team.name,
                                            inviterName: actor.username, token: token,
                                            expiresAt: invitation.expiresAt)
        } catch {
            try? await invitation.delete(on: fluent.db())
            throw error
        }
        return try .init(id: invitation.requireID(), teamID: teamID, email: email,
                         expiresAt: invitation.expiresAt, token: nil)
    }

    @Sendable func listInvitations(_: Request, ctx: AppRequestContext) async throws -> [InvitationResponse] {
        let teamID = try uuidParameter(ctx, "teamID")
        _ = try await requireTeamRole(teamID: teamID, context: ctx, admin: true)
        return try await TeamInvitation.query(on: fluent.db())
            .filter(\.$teamID == teamID)
            .filter(\.$acceptedAt == nil)
            .filter(\.$revokedAt == nil)
            .sort(\.$expiresAt, .descending)
            .all()
            .map { invitation in
                try .init(id: invitation.requireID(), teamID: teamID, email: invitation.email,
                          expiresAt: invitation.expiresAt, token: nil)
            }
    }

    @Sendable func resendInvitation(_: Request, ctx: AppRequestContext) async throws -> InvitationResponse {
        let teamID = try uuidParameter(ctx, "teamID")
        _ = try await requireTeamRole(teamID: teamID, context: ctx, admin: true)
        let invitationID = try uuidParameter(ctx, "invitationID")
        guard let invitation = try await TeamInvitation.find(invitationID, on: fluent.db()),
              invitation.teamID == teamID, invitation.acceptedAt == nil, invitation.revokedAt == nil,
              let team = try await Team.find(teamID, on: fluent.db()), team.archivedAt == nil
        else {
            throw HTTPError(.notFound, message: "pending invitation not found")
        }
        let actor = try ctx.requireIdentity()
        let token = UUID().uuidString + UUID().uuidString
        let previousHash = invitation.tokenHash
        let previousExpiry = invitation.expiresAt
        invitation.tokenHash = hash(token)
        invitation.expiresAt = Date().addingTimeInterval(7 * 24 * 60 * 60)
        try await invitation.update(on: fluent.db())
        do {
            try await invitationSender.send(to: invitation.email, teamName: team.name,
                                            inviterName: actor.username, token: token,
                                            expiresAt: invitation.expiresAt)
        } catch {
            invitation.tokenHash = previousHash
            invitation.expiresAt = previousExpiry
            try? await invitation.update(on: fluent.db())
            throw HTTPError(.serviceUnavailable, message: "invitation could not be resent")
        }
        return try .init(id: invitation.requireID(), teamID: teamID, email: invitation.email,
                         expiresAt: invitation.expiresAt, token: nil)
    }

    @Sendable func revokeInvitation(_: Request, ctx: AppRequestContext) async throws -> Response {
        let teamID = try uuidParameter(ctx, "teamID")
        _ = try await requireTeamRole(teamID: teamID, context: ctx, admin: true)
        let invitationID = try uuidParameter(ctx, "invitationID")
        guard let invitation = try await TeamInvitation.find(invitationID, on: fluent.db()),
              invitation.teamID == teamID, invitation.acceptedAt == nil, invitation.revokedAt == nil
        else {
            throw HTTPError(.notFound, message: "pending invitation not found")
        }
        invitation.revokedAt = Date()
        try await invitation.update(on: fluent.db())
        return Response(status: .noContent)
    }

    @Sendable func acceptInvitation(_: Request, ctx: AppRequestContext) async throws -> TeamResponse {
        guard let token = ctx.parameters.get("token") else { throw HTTPError(.badRequest) }
        let user = try ctx.requireIdentity()
        let userID = try user.requireID()
        guard user.isVerified else { throw HTTPError(.forbidden, message: "verify email before accepting") }
        guard let invitation = try await TeamInvitation.query(on: fluent.db())
            .filter(\.$tokenHash == hash(token)).first(),
            invitation.acceptedAt == nil, invitation.revokedAt == nil,
            invitation.expiresAt > Date(), invitation.email == user.email.lowercased(),
            let team = try await Team.find(invitation.teamID, on: fluent.db()), team.archivedAt == nil
        else {
            throw HTTPError(.gone, message: "invitation is invalid or expired")
        }
        if try await TeamMembership.query(on: fluent.db()).filter(\.$teamID == invitation.teamID)
            .filter(\.$userID == userID).first() == nil
        {
            try await TeamMembership(teamID: invitation.teamID, userID: userID, role: "member").save(on: fluent.db())
        }
        let grants = try JSONDecoder().decode([String: InviteGrant].self, from: Data(invitation.vaultGrants.utf8))
        for (rawID, grant) in grants {
            guard let vaultID = UUID(uuidString: rawID) else { continue }
            if let existing = try await VaultMembership.query(on: fluent.db())
                .filter(\.$vaultID == vaultID).filter(\.$userID == userID).first()
            {
                existing.role = grant.role
                existing.canUseAI = grant.canUseAI
                try await existing.update(on: fluent.db())
            } else {
                try await VaultMembership(vaultID: vaultID, userID: userID, role: grant.role,
                                          canUseAI: grant.canUseAI,
                                          createdByUserID: invitation.invitedByUserID).save(on: fluent.db())
            }
            try await record(vaultID: vaultID, actor: user, action: "member.joined",
                             targetType: "member", targetID: userID, targetTitle: user.username)
        }
        invitation.acceptedAt = Date()
        try await invitation.update(on: fluent.db())
        return try .init(id: team.requireID(), name: team.name, role: "member", archivedAt: team.archivedAt)
    }

    @Sendable func activity(_: Request, ctx: AppRequestContext) async throws -> [ActivityResponse] {
        let vaultID = try uuidParameter(ctx, "vaultID")
        _ = try await access.resolve(vaultID: vaultID, context: ctx, requiring: .read)
        let rows = try await VaultActivityEvent.query(on: fluent.db())
            .filter(\.$vaultID == vaultID).sort(\.$createdAt, .descending).limit(100).all()
        return try rows.map {
            try ActivityResponse(id: $0.requireID(), vaultID: vaultID, actorUserID: $0.actorUserID,
                                 actorName: $0.actorName, action: $0.action, targetType: $0.targetType,
                                 targetID: $0.targetID, targetTitle: $0.targetTitle,
                                 createdAt: $0.createdAt ?? .distantPast)
        }
    }

    @Sendable func activityStream(_: Request, ctx: AppRequestContext) async throws -> VaultActivitySSEResponse {
        let vaultID = try uuidParameter(ctx, "vaultID")
        _ = try await access.resolve(vaultID: vaultID, context: ctx, requiring: .read)
        return await VaultActivitySSEResponse(events: activityPublisher.subscribe(vaultID: vaultID))
    }

    private func requireTeamRole(teamID: UUID, context: AppRequestContext, admin: Bool) async throws -> TeamMembership {
        let userID = try context.requireTenantID()
        guard let membership = try await TeamMembership.query(on: fluent.db())
            .filter(\.$teamID == teamID).filter(\.$userID == userID).first(),
            !admin || membership.role == "owner" || membership.role == "admin"
        else {
            throw HTTPError(.forbidden, message: "team access denied")
        }
        return membership
    }

    private func record(vaultID: UUID, actor: User, action: String, targetType: String,
                        targetID: UUID?, targetTitle: String?) async throws
    {
        let row = try VaultActivityEvent(vaultID: vaultID, actorUserID: actor.requireID(),
                                         actorName: actor.username, action: action, targetType: targetType,
                                         targetID: targetID, targetTitle: targetTitle)
        try await row.save(on: fluent.db())
        let response = try ActivityResponse(id: row.requireID(), vaultID: vaultID,
                                            actorUserID: row.actorUserID, actorName: row.actorName,
                                            action: action, targetType: targetType, targetID: targetID,
                                            targetTitle: targetTitle, createdAt: row.createdAt ?? Date())
        await activityPublisher.publish(response)
    }

    private func uuidParameter(_ context: AppRequestContext, _ name: String) throws -> UUID {
        guard let raw = context.parameters.get(name), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid \(name)")
        }
        return id
    }

    private func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func purgeExpiredArchives() async throws {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let teams = try await Team.query(on: fluent.db()).filter(\.$archivedAt < cutoff).all()
        for team in teams {
            let teamID = try team.requireID()
            let vaults = try await Vault.query(on: fluent.db()).filter(\.$teamID == teamID).all()
            for vault in vaults {
                guard let vaultID = try? vault.requireID() else { continue }
                try? FileManager.default.removeItem(at: vaultPaths.tenantRoot(for: vaultID))
            }
            try await team.delete(on: fluent.db())
        }
    }
}
