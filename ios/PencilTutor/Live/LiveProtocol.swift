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
    /// After a watch look. Facts only: the app knows line geometry and the verdict, not recognised equations. Never says who looked: the
    /// voice speaks as if it looks itself.
    static func verdict(lineCount: Int, flaggedLine: Int?, hintWritten: String?) -> String {
        let lines = lineCount == 1 ? "1 line" : "\(lineCount) lines"
        if let flaggedLine {
            let note = (hintWritten ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let noteText = note.isEmpty ? "" : " with the note \"\(note)\""
            return "Page check just now: the student's page has \(lines). A red circle was put round line \(flaggedLine)\(noteText) and the student has been given a hint. The student may have written more since."
        }
        return "Page check just now: the student's page (\(lines)) looks fine so far. The student may have written more since."
    }

    static let checkLooksGood = "Looks good so far. Keep going."

    /// The student pressed Check my work and the page is exactly what it was at the last look, with nothing wrong: "looks good" would
    /// say nothing true, so it offers the way out instead.
    static let checkNothingNew = "Nothing new since I last looked. Want me to show you how?"

    /// The student tapped "Not a mistake" on the circle round `line`. Quiet context, never to be said. The hint's own words are left
    /// out on purpose: the model must not have them handed to it again.
    static func notAMistake(line: Int) -> String {
        "The student marked line \(line) as not a mistake: the red circle there was wrong and the student dismissed it. Do not repeat or paraphrase that hint, do not say line \(line) is wrong, and if you were in the middle of saying it, stop. If the student asks about that line, look at the page again."
    }

    /// Added to a page report that was being read when the student dismissed a circle, so the report cannot bring the dismissed hint back.
    static func disputedNote(lines: [Int]) -> String {
        let named = lines.count == 1 ? "line \(lines[0])" : "lines " + lines.map(String.init).joined(separator: ", ")
        return " Note: while the page was being read, the student marked \(named) as not a mistake. Do not tell them \(named) is wrong."
    }

    /// What GPT-Live is told to say when the page could not be looked at for a delegation.
    static func consultFailed(reason: String) -> String {
        "You could not look at the student's page just now (\(reason)). Tell the student briefly that you could not look right then, and ask them to try again in a moment."
    }

    /// Pushed when a practice problem opens and again whenever the answer changes. The server's live instructions already say this once
    /// (the reference tells it the problem is a practice problem); this line keeps the voice right as the student writes, and covers
    /// the turns where the voice answers without looking at the page.
    static func practice(attempted: Bool) -> String {
        if attempted {
            return "The student has now written real work on the practice problem, so the rule about not stating the answer before a try no longer applies. Still prefer a hint, and let them do the working. Their work may have changed since."
        }
        return "The student has not tried the practice problem yet: there is no finished line of their own work on the page. Do not state the final answer or any line that contains it, and do not work the steps for them, even if they ask, say they give up or ask you to just tell them. Say you will check each line as they write, and give a hint about where to start. The one exception: if you are told the worked solution is on the student's screen, walk them through it."
    }

    // MARK: Show me how

    /// Said to the live voice once the worked solution is on the student's screen: the answer to the delegation on the voice path, and a
    /// line of commentary on the button path. Never sent while the solution loads, or if it could not be checked.
    static let showMeWalkthrough = "The worked solution is on the student's screen now, and you have its steps. Walk them through it one step at a time in plain words: say the idea first, then the step, and check they follow before you go on. Do not read it all out at once. At the end, offer a similar problem for them to try."

    /// The solution could not be worked out with confidence for a problem the student typed, so nothing is on the screen.
    static let showMeNotChecked = "You could not work this problem out with enough confidence to show it, so nothing is on the student's screen. Tell them so in one short sentence, and offer to try again."

    static let showMeFailed = "You could not put the worked solution on the student's screen just now. Tell them briefly and ask them to try again in a moment."

    /// With no live voice, the base voice says this once, when the steps are on screen.
    static let showMeBaseVoiceLine = "Here is how it goes. The steps are on your screen. Read along, then tap Try one like it."

    /// The shown solution for the voice to know, as quiet context: one string per append, split between steps so none passes the clip
    /// (`LiveClientEvent.maxTextCharacters`), each saying which part it is.
    static func solution(steps: [String], finalAnswer: String, limit: Int = LiveClientEvent.maxTextCharacters) -> [String] {
        let lines = steps.enumerated().map { "Step \($0.offset + 1): \($0.element)" } + ["Answer: \(finalAnswer)"]
        let headerRoom = 160
        let budget = max(200, limit - headerRoom)
        var parts: [[String]] = [[]]
        var used = 0
        for line in lines {
            let kept = String(line.prefix(budget))
            let cost = kept.count + 1
            if used + cost > budget, !(parts.last ?? []).isEmpty {
                parts.append([])
                used = 0
            }
            parts[parts.count - 1].append(kept)
            used += cost
        }
        return parts.enumerated().map { index, part in
            "Worked solution now on the student's screen, part \(index + 1) of \(parts.count). Quiet context for you to walk through, not to read out in one go:\n" + part.joined(separator: "\n")
        }
    }

    static let outOfDateNote = " Note: the student wrote more while the page was being read, so this may be slightly out of date."
}
