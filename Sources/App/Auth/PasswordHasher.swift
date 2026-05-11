import HummingbirdBcrypt

protocol PasswordHasher: Sendable {
    func hash(_ password: String) async -> String
    func verify(_ password: String, hash: String) async -> Bool
}

struct BcryptPasswordHasher: PasswordHasher {
    let cost: UInt8

    init(cost: UInt8 = 12) {
        self.cost = cost
    }

    func hash(_ password: String) async -> String {
        Bcrypt.hash(password, cost: cost)
    }

    func verify(_ password: String, hash: String) async -> Bool {
        Bcrypt.verify(password, hash: hash)
    }
}
