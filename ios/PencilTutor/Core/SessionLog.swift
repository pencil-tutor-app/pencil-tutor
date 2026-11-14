import Foundation
import os

/// On-device session log: one JSON object per line in the app's Documents folder.
///
/// What goes in: ids, counts, sizes, latencies, reason labels, and the hint text the tutor showed.
/// What never goes in: access tokens, keys, page images, audio.
final class SessionLog {
    let sessionID: String
    let fileURL: URL
    private let directory: URL
    private let queue = DispatchQueue(label: "pencil-tutor.session-log")
    private let logger = Logger(subsystem: "com.edwardtran.penciltutor", category: "session")

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = base
        self.sessionID = String(UUID().uuidString.prefix(8)).lowercased()
        let stamp = TimeText.iso(Date()).replacingOccurrences(of: ":", with: "-")
        self.fileURL = base.appendingPathComponent("session-\(stamp)-\(sessionID).jsonl")
    }

    func record(_ type: String, _ fields: [String: Any] = [:]) {
        var object = fields
        object["t"] = TimeText.iso(Date())
        object["session"] = sessionID
        object["type"] = type

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            logger.error("session log could not encode an event of type \(type, privacy: .public)")
            return
        }
        logger.info("\(type, privacy: .public) \(String(data: data, encoding: .utf8) ?? "", privacy: .public)")

        let url = fileURL
        queue.async { [logger] in
            var line = data
            line.append(0x0A)
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: url, options: .atomic)
                }
            } catch {
                logger.error("session log write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Debug builds only (the same gate as `TutorSession.logsWords`): keeps a copy of the page picture that was sent to the
    /// tutor, next to the session log, so Edward's real handwriting can be pulled off the iPad for model evals later.
    /// Release builds never write it. The file stays on the device: it is not uploaded, not part of the log export, and the
    /// log line names the file and its size only. Returns the file name, or nil when nothing was written.
    ///
    /// Pull with: xcrun devicectl device copy from --device <id> --domain-type appDataContainer
    ///   --domain-identifier com.edwardtran.penciltutor --source Documents/<file> --destination <folder>
    @discardableResult
    func savePageImage(_ png: Data, kind: String, lookID: String) -> String? {
        guard TutorSession.logsWords else { return nil }
        let safeKind = kind.filter { $0.isLetter || $0.isNumber }
        let safeLook = lookID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let name = fileURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "session-", with: "page-") + "-\(safeKind)-\(safeLook).png"
        let url = directory.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
            record("page_saved", ["kind": safeKind, "look": safeLook, "file": name, "bytes": png.count])
            return name
        } catch {
            record("page_save_failed", ["kind": safeKind, "look": safeLook, "bytes": png.count, "reason": String(describing: error)])
            return nil
        }
    }

    /// Waits for pending writes, then merges every session file into one temporary file for the share sheet.
    func exportURL() -> URL? {
        queue.sync {}
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            logger.error("export requested but there are no session files in \(self.directory.lastPathComponent, privacy: .public)")
            return nil
        }
        var merged = Data()
        for file in files {
            if let part = try? Data(contentsOf: file) { merged.append(part) }
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pencil-tutor-session-log.jsonl")
        do {
            try merged.write(to: out, options: .atomic)
            logger.info("exported \(files.count) session files, \(merged.count) bytes")
            return out
        } catch {
            logger.error("export write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
