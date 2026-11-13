import Foundation

// The request and response shapes for the tutor server (plan "Contract" plus amendment 5).
// Field names on the wire are snake_case, written out explicitly so a rename cannot slip in unnoticed.

struct BoxWire: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct LineWire: Codable, Equatable {
    var index: Int
    var box: BoxWire
    var lastStrokeAt: String

    private enum CodingKeys: String, CodingKey {
        case index, box
        case lastStrokeAt = "last_stroke_at"
    }
}

struct HistoryWire: Codable, Equatable {
    var at: String
    var action: String
    var line: Int?
    var hintWritten: String?

    private enum CodingKeys: String, CodingKey {
        case at, action, line
        case hintWritten = "hint_written"
    }
}

struct WatchRequest: Codable, Equatable {
    var sessionId: String
    var problemId: String
    var drawingRevision: Int
    var imagePngBase64: String
    var imageWidth: Int
    var imageHeight: Int
    var lines: [LineWire]
    /// Last 10 decisions only (plan amendment 5).
    var history: [HistoryWire]
    var clientTime: String

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case problemId = "problem_id"
        case drawingRevision = "drawing_revision"
        case imagePngBase64 = "image_png_base64"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case lines, history
        case clientTime = "client_time"
    }
}

struct WatchResponse: Codable, Equatable {
    var action: String
    var line: Int?
    var reason: String?
    var hintSpoken: String?
    var hintWritten: String?
    var drawingRevision: Int?
    var requestId: String?
    var model: String?
    var latencyMs: Int?

    private enum CodingKeys: String, CodingKey {
        case action, line, reason, model
        case hintSpoken = "hint_spoken"
        case hintWritten = "hint_written"
        case drawingRevision = "drawing_revision"
        case requestId = "request_id"
        case latencyMs = "latency_ms"
    }
}

/// Exactly the fields server/README.md lists for POST /api/ask, no more.
struct AskRequest: Codable, Equatable {
    var sessionId: String
    var problemId: String
    var drawingRevision: Int
    var audioBase64: String
    var imagePngBase64: String

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case problemId = "problem_id"
        case drawingRevision = "drawing_revision"
        case audioBase64 = "audio_base64"
        case imagePngBase64 = "image_png_base64"
    }
}

struct AskResponse: Codable, Equatable {
    var transcript: String?
    var answerText: String
    var requestId: String?
    var model: String?
    var latencyMs: Int?

    private enum CodingKeys: String, CodingKey {
        case transcript, model
        case answerText = "answer_text"
        case requestId = "request_id"
        case latencyMs = "latency_ms"
    }
}

/// POST /api/speak: text 1 to 600 characters, `purpose` a short lowercase label. The reply is audio/mpeg bytes, not JSON.
struct SpeakRequest: Codable, Equatable {
    var sessionId: String
    var text: String
    var purpose: String

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case text, purpose
    }
}

/// One earlier turn of the live conversation, sent with a consult so the page reader can resolve "that one".
struct ConsultTurnWire: Codable, Equatable {
    var role: String   // "student" or "tutor"
    var text: String
}

/// POST /api/consult: the page reader GPT-Live delegates to. `question` is what the student just said, from Live's own transcript.
struct ConsultRequest: Codable, Equatable {
    var sessionId: String
    var problemId: String
    var drawingRevision: Int
    var imagePngBase64: String
    var question: String
    var recent: [ConsultTurnWire]

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case problemId = "problem_id"
        case drawingRevision = "drawing_revision"
        case imagePngBase64 = "image_png_base64"
        case question, recent
    }
}

struct ConsultResponse: Codable, Equatable {
    var answerText: String
    var drawingRevision: Int?
    var requestId: String?
    var model: String?
    var latencyMs: Int?

    private enum CodingKeys: String, CodingKey {
        case model
        case answerText = "answer_text"
        case drawingRevision = "drawing_revision"
        case requestId = "request_id"
        case latencyMs = "latency_ms"
    }
}

/// POST /api/live-session: our WebRTC offer in, OpenAI's answer out. The OpenAI key never reaches the app.
struct LiveSessionRequest: Codable, Equatable {
    var sessionId: String
    var problemId: String
    var sdp: String

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case problemId = "problem_id"
        case sdp
    }
}

struct LiveSessionResponse: Codable, Equatable {
    var sessionId: String
    var sdp: String
    var model: String?
    var voice: String?
    var latencyMs: Int?
    var requestId: String?

    private enum CodingKeys: String, CodingKey {
        case sdp, model, voice
        case sessionId = "session_id"
        case latencyMs = "latency_ms"
        case requestId = "request_id"
    }
}

/// `{error, reason}` body the server sends with a 401, 422 or 503.
struct ServerErrorBody: Codable {
    var error: String?
    var reason: String?
}

enum TimeText {
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
