import CryptoKit
import Foundation

/// A student's code: 8 characters from an alphabet with no look-alikes. It is the only credential the app holds, so it is
/// treated like an identifier: the log gets `shortHash` and never the code itself. No names anywhere.
///
/// The server uses the exact same alphabet (server contract, 2026-11-14): `ABCDEFGHJKMNPQRSTVWXYZ23456789`, 30 symbols,
/// no I, L, O, U, 0 or 1.
enum StudentCode {
    static let alphabet = "ABCDEFGHJKMNPQRSTVWXYZ23456789"
    static let length = 8

    private static let allowed = Set(alphabet)

    /// What the student typed, cleaned up: trimmed, uppercased, spaces and dashes dropped. Does not check the alphabet.
    static func normalize(_ typed: String) -> String {
        typed.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "\u{2013}" && $0 != "\u{2014}" }
    }

    /// True for exactly 8 characters, all from the alphabet. Pass a normalized code.
    static func isValid(_ code: String) -> Bool {
        code.count == length && code.allSatisfy { allowed.contains($0) }
    }

    /// Why a typed value is not a code yet, as a short label for the log. Nil when it is valid.
    static func problem(with normalized: String) -> String? {
        if normalized.isEmpty { return "empty" }
        if normalized.count < length { return "too_short" }
        if normalized.count > length { return "too_long" }
        if !normalized.allSatisfy({ allowed.contains($0) }) { return "characters_not_in_alphabet" }
        return nil
    }

    /// XXXX-XXXX for a full code; a partial code gets the dash after the fourth character.
    static func display(_ normalized: String) -> String {
        guard normalized.count > 4 else { return normalized }
        return String(normalized.prefix(4)) + "-" + String(normalized.dropFirst(4))
    }

    /// For Settings: the first four characters and bullets, e.g. `ABCD-••••`.
    static func masked(_ normalized: String) -> String {
        guard normalized.count == length else { return String(repeating: "•", count: min(normalized.count, length)) }
        return String(normalized.prefix(4)) + "-••••"
    }

    /// First 6 hex characters of the SHA-256 of the code. The only form of a code that goes into the session log.
    static func shortHash(_ normalized: String) -> String {
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(3).map { String(format: "%02x", $0) }.joined()
    }
}

/// Where the code is kept between launches.
protocol StudentCodeStoring: AnyObject {
    func load() -> String?
    func save(_ code: String) throws
    func clear()
}

/// Test and scripted-run store: nothing touches the Keychain.
final class InMemoryStudentCodeStore: StudentCodeStoring {
    private var code: String?
    var failsToSave = false

    init(code: String? = nil) {
        self.code = code
    }

    func load() -> String? { code }

    func save(_ code: String) throws {
        if failsToSave { throw KeychainFailure(status: -1, action: "save") }
        self.code = code
    }

    func clear() { code = nil }
}

struct KeychainFailure: Error {
    let status: Int32
    let action: String
}

/// The real store: one generic-password item in the Keychain, readable after the first unlock, this device only
/// (never synced to iCloud).
final class KeychainStudentCodeStore: StudentCodeStoring {
    static let service = "com.edwardtran.penciltutor.student-code"
    private let account = "student-code"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ code: String) throws {
        let data = Data(code.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainFailure(status: update, action: "update") }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainFailure(status: status, action: "add") }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// The code currently in use, shared by the network client and the speech player. Read on every request, so signing in
/// or out takes effect at once. The lock makes it safe to read from background tasks.
final class StudentCodeHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) {
        self.value = value
    }

    var current: String? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
