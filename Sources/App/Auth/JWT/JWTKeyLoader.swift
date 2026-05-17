import Foundation
import JWTKit

/// HER-33 JWT key rotation. `JWT_HMAC_SECRETS` carries an ordered csv of
/// `kid:secret` pairs. The first entry is the active signer; the remainder
/// stay loaded so in-flight tokens signed under a retiring kid still verify
/// during the rollover window.
///
/// Rotation procedure (zero downtime):
///   1. Add the new key as the FIRST entry (active), keep the old kid last.
///      Redeploy.
///   2. After the access-token TTL elapses, remove the old kid. Redeploy.
enum JWTKeyLoaderError: Error, Equatable, CustomStringConvertible {
    case malformedEntry(String)
    case emptyKid
    case shortSecret(kid: String, length: Int)
    case duplicateKid(String)

    var description: String {
        switch self {
        case let .malformedEntry(entry):
            "malformed JWT_HMAC_SECRETS entry (expected kid:secret): '\(entry)'"
        case .emptyKid:
            "JWT_HMAC_SECRETS entry has empty kid"
        case let .shortSecret(kid, length):
            "JWT_HMAC_SECRETS kid='\(kid)' secret length=\(length) (minimum 32)"
        case let .duplicateKid(kid):
            "JWT_HMAC_SECRETS contains duplicate kid '\(kid)'"
        }
    }
}

struct JWTKeyEntry: Equatable {
    let kid: JWKIdentifier
    let secret: String
}

/// HS256 secret length floor. Matches the warning in `docs/CONFIG.md` and
/// the runtime checks elsewhere in the codebase.
private let minSecretLength = 32

/// Parses `kid1:secret1,kid2:secret2` into ordered entries. Whitespace is
/// trimmed around kids and secrets. Empty/whitespace-only input returns an
/// empty array (the caller falls back to the legacy single-key env vars).
func parseJWTSecrets(_ csv: String) throws -> [JWTKeyEntry] {
    let trimmedInput = csv.trimmingCharacters(in: .whitespaces)
    guard !trimmedInput.isEmpty else { return [] }

    var entries: [JWTKeyEntry] = []
    var seen: Set<String> = []
    for raw in trimmedInput.split(separator: ",") {
        let entry = raw.trimmingCharacters(in: .whitespaces)
        guard let colon = entry.firstIndex(of: ":") else {
            throw JWTKeyLoaderError.malformedEntry(String(entry))
        }
        let kidString = entry[..<colon].trimmingCharacters(in: .whitespaces)
        let secret = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !kidString.isEmpty else {
            throw JWTKeyLoaderError.emptyKid
        }
        guard secret.count >= minSecretLength else {
            throw JWTKeyLoaderError.shortSecret(kid: kidString, length: secret.count)
        }
        guard seen.insert(kidString).inserted else {
            throw JWTKeyLoaderError.duplicateKid(kidString)
        }
        entries.append(JWTKeyEntry(kid: JWKIdentifier(string: kidString), secret: secret))
    }
    return entries
}

/// Adds every entry to `collection` as HS256. Order is preserved; JWTKit
/// chooses the verifying key by matching the token's `kid` header so the
/// presence of older keys is transparent to consumers.
func loadJWTKeys(into collection: JWTKeyCollection, secrets: [JWTKeyEntry]) async throws {
    for entry in secrets {
        await collection.add(
            hmac: HMACKey(stringLiteral: entry.secret),
            digestAlgorithm: .sha256,
            kid: entry.kid,
        )
    }
}
