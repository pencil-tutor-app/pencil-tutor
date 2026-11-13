import Foundation

// The JSON the app exchanges with a GPT-Live session over the WebRTC data channel "oai-events".
// Event names and fields are the ones OpenAI documents (guides/live-conversations, guides/live-delegation) and that the
// deployed API was seen to send on 2026-11-13. Foundation only, so it is unit tested without WebRTC.

/// Events from the session that the app acts on. Anything else is `.other(type:)`, which still reaches the log so a new
/// event type shows up in the session log instead of vanishing.
enum LiveServerEvent: Equatable {
    case started(sessionID: String?)
    case inputTranscript(String)
    case outputTranscript(String)
    case delegationCreated(id: String, target: String?)
    case usage(seconds: Double)
    case muted(clientEventID: String?)
    case unmuted(clientEventID: String?)
    /// `kind` is "thinking", "commentary" or "instructions".
    case appended(kind: String, clientEventID: String?)
    case closed(reason: String?, seconds: Double?)
    case failure(type: String?, code: String?, message: String, clientEventID: String?)
    case other(type: String)

    /// Nil only when the text is not a JSON object with a string "type".
    static func decode(_ text: String) -> LiveServerEvent? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return nil }

        func string(_ key: String, in dict: [String: Any]? = nil) -> String? { (dict ?? object)[key] as? String }
        func number(_ key: String, in dict: [String: Any]?) -> Double? { (dict?[key] as? NSNumber)?.doubleValue }

        switch type {
        case "session.started":
            return .started(sessionID: string("id", in: object["session"] as? [String: Any]))
        case "session.input_transcript.delta":
            return .inputTranscript(string("delta") ?? "")
        case "session.output_transcript.delta":
            return .outputTranscript(string("delta") ?? "")
        case "session.delegation.created":
            let delegation = object["delegation"] as? [String: Any]
            guard let id = string("id", in: delegation) else { return .other(type: type) }
            return .delegationCreated(id: id, target: string("target", in: delegation))
        case "session.usage.updated":
            return .usage(seconds: number("seconds", in: object["usage"] as? [String: Any]) ?? 0)
        case "session.input_audio.muted":
            return .muted(clientEventID: string("client_event_id"))
        case "session.input_audio.unmuted":
            return .unmuted(clientEventID: string("client_event_id"))
        case "session.thinking.appended":
            return .appended(kind: "thinking", clientEventID: string("client_event_id"))
        case "session.commentary.appended":
            return .appended(kind: "commentary", clientEventID: string("client_event_id"))
        case "session.instructions.appended":
            return .appended(kind: "instructions", clientEventID: string("client_event_id"))
        case "session.closed":
            return .closed(reason: string("reason"), seconds: number("seconds", in: object["usage"] as? [String: Any]))
        case "error":
            let error = object["error"] as? [String: Any]
            return .failure(
                type: string("type", in: error), code: string("code", in: error),
                message: string("message", in: error) ?? "", clientEventID: string("client_event_id", in: error)
            )
        default:
            return .other(type: type)
        }
    }
}

/// Events the app sends. The server's allow-list lets exactly these five types through (server/lib/live.ts).
enum LiveClientEvent: Equatable {
    /// Facts for the model to know, not to say. Session wide.
    case thinking(eventID: String, text: String)
    /// Something for the model to say aloud (it may paraphrase). `delegationID` nil means session wide.
    case commentary(eventID: String, delegationID: String?, text: String)
    case mute(eventID: String)
    case unmute(eventID: String)
    case close(eventID: String)

    /// OpenAI limits each append to 500 tokens; this keeps well under it (about 4 characters per token).
    static let maxTextCharacters = 1_200

    var eventType: String {
        switch self {
        case .thinking: return "session.thinking.append"
        case .commentary: return "session.commentary.append"
        case .mute: return "session.input_audio.mute"
        case .unmute: return "session.input_audio.unmute"
        case .close: return "session.close"
        }
    }

    var eventID: String {
        switch self {
        case .thinking(let id, _), .commentary(let id, _, _), .mute(let id), .unmute(let id), .close(let id): return id
        }
    }

    static func clipped(_ text: String) -> String {
        text.count <= maxTextCharacters ? text : String(text.prefix(maxTextCharacters))
    }

    func json() -> String {
        var object: [String: Any] = ["type": eventType, "event_id": eventID]
        switch self {
        case .thinking(_, let text):
            object["delegation_id"] = NSNull()
            object["content"] = Self.clipped(text)
        case .commentary(_, let delegationID, let text):
            object["delegation_id"] = delegationID.map { $0 as Any } ?? NSNull()
            object["content"] = Self.clipped(text)
        case .mute, .unmute, .close:
            break
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// The plain-words context lines the app pushes into the session. Kept as pure functions so the wording is tested.
enum LiveContext {
    /// After a watch look. Facts only: the app knows line geometry and the watcher's verdict, not recognised equations.
    static func verdict(lineCount: Int, flaggedLine: Int?, hintWritten: String?) -> String {
        let lines = lineCount == 1 ? "1 line" : "\(lineCount) lines"
        if let flaggedLine {
            let note = (hintWritten ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let noteText = note.isEmpty ? "" : " with the note \"\(note)\""
            return "Page check just now: the student's page has \(lines). The page watcher circled line \(flaggedLine) in red\(noteText) and the student has been given a hint. The student may have written more since."
        }
        return "Page check just now: the page watcher looked at the student's page (\(lines)) and saw no problem. The student may have written more since."
    }

    static let checkLooksGood = "Looks good so far. Keep going."

    /// What GPT-Live is told to say when the page reader could not answer a delegation.
    static func consultFailed(reason: String) -> String {
        "You could not look at the student's page just now (\(reason)). Tell the student briefly that you could not look right then, and ask them to try again in a moment."
    }

    static let emptyPage = "The student's page is empty so far: nothing has been written yet. Tell them to write the first step and you will look."

    static let outOfDateNote = " Note: the student wrote more while the page was being read, so this may be slightly out of date."
}
