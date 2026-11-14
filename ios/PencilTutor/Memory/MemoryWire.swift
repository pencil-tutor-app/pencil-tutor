import Foundation

// The shapes of /api/memory (server/lib/record/endpoint.ts). Field names on the wire are snake_case, written out explicitly.

struct MemoryNoticeSection: Codable, Equatable, Identifiable {
    var heading: String
    var body: String
    var id: String { heading }
}

/// The consent text, owned by the server. The app shows exactly this and sends back `version`, so what was agreed to is on record.
struct MemoryNotice: Codable, Equatable {
    var version: String
    var title: String
    var intro: String
    var sections: [MemoryNoticeSection]
    var policyUrl: String

    private enum CodingKeys: String, CodingKey {
        case version, title, intro, sections
        case policyUrl = "policy_url"
    }
}

struct MemoryConsent: Codable, Equatable {
    var granted: Bool
    /// True only for a grant of the notice version the server offers now. Anything else means memory is off.
    var current: Bool
    var givenBy: String?
    var recordedVia: String
    var noticeVersion: String
    var at: String

    private enum CodingKeys: String, CodingKey {
        case granted, current, at
        case givenBy = "given_by"
        case recordedVia = "recorded_via"
        case noticeVersion = "notice_version"
    }
}

struct MemoryRecentAttempt: Codable, Equatable, Identifiable {
    var problemId: String
    var looks: Int
    var asks: Int
    var interrupts: Int
    var lastAt: String
    var id: String { problemId + lastAt }

    private enum CodingKeys: String, CodingKey {
        case looks, asks, interrupts
        case problemId = "problem_id"
        case lastAt = "last_at"
    }
}

struct MemoryRecord: Codable, Equatable {
    var notes: Int
    var recent: [MemoryRecentAttempt]
}

/// GET /api/memory. `feature` is "on" or "off"; when off with no record the server sends nothing else.
struct MemoryStatusResponse: Codable, Equatable {
    var feature: String
    var notice: MemoryNotice?
    var consent: MemoryConsent?
    var record: MemoryRecord?
    var requestId: String?
    var allowance: Allowance? = nil

    private enum CodingKeys: String, CodingKey {
        case feature, notice, consent, record, allowance
        case requestId = "request_id"
    }
}

/// Who is agreeing. The only two answers the server accepts; no name is asked or sent.
enum MemoryAttestation: String, CaseIterable, Identifiable {
    case parentGuardian = "parent_guardian"
    case adultStudent = "adult_student"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .parentGuardian: return "I am the parent or legal guardian of the student who uses this iPad"
        case .adultStudent: return "I am the adult student, and this is my own learning"
        }
    }
}

/// POST /api/memory: one body type for the three actions; unused fields are left out of the JSON.
struct MemoryActionRequest: Codable, Equatable {
    var action: String
    var givenBy: String?
    var noticeVersion: String?
    var attested: Bool?
    var erase: Bool?

    private enum CodingKeys: String, CodingKey {
        case action, attested, erase
        case givenBy = "given_by"
        case noticeVersion = "notice_version"
    }

    static func consent(_ who: MemoryAttestation, version: String) -> Self {
        Self(action: "consent", givenBy: who.rawValue, noticeVersion: version, attested: true, erase: nil)
    }
    static func withdraw(erase: Bool) -> Self { Self(action: "withdraw", givenBy: nil, noticeVersion: nil, attested: nil, erase: erase) }
    static var erase: Self { Self(action: "erase", givenBy: nil, noticeVersion: nil, attested: nil, erase: nil) }
}

struct MemoryDeleted: Codable, Equatable {
    var hints: Int
    var attempts: Int
    var notes: Int
}

struct MemoryActionResponse: Codable, Equatable {
    var ok: Bool
    var withdrawn: Bool?
    var deleted: MemoryDeleted?
    var requestId: String?
    var allowance: Allowance? = nil

    private enum CodingKeys: String, CodingKey {
        case ok, withdrawn, deleted, allowance
        case requestId = "request_id"
    }
}

/// What the memory screens need from the network. Split out of `TutorClient` so the store and its tests do not depend on the rest.
/// Defaults refuse, so a client that knows nothing about memory simply reports "not available".
protocol MemoryAPI {
    func memoryStatus() async throws -> MemoryStatusResponse
    func memoryAct(_ request: MemoryActionRequest) async throws -> MemoryActionResponse
}

extension MemoryAPI {
    func memoryStatus() async throws -> MemoryStatusResponse {
        throw TutorError.notConfigured(reason: "this client has no memory")
    }
    func memoryAct(_ request: MemoryActionRequest) async throws -> MemoryActionResponse {
        throw TutorError.notConfigured(reason: "this client has no memory")
    }
}
