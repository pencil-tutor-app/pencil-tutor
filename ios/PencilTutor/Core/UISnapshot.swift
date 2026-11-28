#if DEBUG
import UIKit

/// Debug builds only. Takes pictures of the app's own window at set times after launch, so a screen can be checked on a real iPad
/// without tapping or a UI test: `--ui-snapshots "portrait@6,landscape@12"` (orientation, then seconds after launch). Each picture is
/// saved in the app's Documents folder as `ui-<n>-<orientation>.png` and logged as `ui_snapshot` (size only). Pull them with
/// `devicectl device copy from ... --source Documents`. Release builds do not contain this file's code.
enum UISnapshot {
    private struct Shot {
        let landscape: Bool
        let seconds: Double
    }

    private static func requested() -> [Shot] {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--ui-snapshots"), arguments.indices.contains(index + 1) else { return [] }
        return arguments[index + 1].split(separator: ",").compactMap { item in
            let parts = item.split(separator: "@")
            guard parts.count == 2, let seconds = Double(parts[1]) else { return nil }
            return Shot(landscape: parts[0].hasPrefix("l"), seconds: seconds)
        }
    }

    @MainActor
    static func scheduleIfRequested(log: SessionLog) {
        let shots = requested()
        guard !shots.isEmpty else { return }
        log.record("ui_snapshots_scheduled", ["count": shots.count])
        for (number, shot) in shots.enumerated() {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(shot.seconds * 1_000_000_000))
                guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
                    log.record("ui_snapshot_failed", ["n": number, "reason": "no_window_scene"])
                    return
                }
                let mask: UIInterfaceOrientationMask = shot.landscape ? .landscapeLeft : .portrait
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                    log.record("ui_orientation_error", ["n": number, "detail": String(describing: error)])
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // let the rotation and the layout settle
                guard let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
                    log.record("ui_snapshot_failed", ["n": number, "reason": "no_window"])
                    return
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                guard let png = image.pngData() else {
                    log.record("ui_snapshot_failed", ["n": number, "reason": "no_png"])
                    return
                }
                let name = "ui-\(number + 1)-\(shot.landscape ? "landscape" : "portrait").png"
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
                do {
                    try png.write(to: url)
                    log.record("ui_snapshot", ["n": number, "file": name, "bytes": png.count, "width": Int(window.bounds.width), "height": Int(window.bounds.height)])
                } catch {
                    log.record("ui_snapshot_failed", ["n": number, "reason": "write_failed", "detail": String(describing: error)])
                }
            }
        }
    }
}

/// Debug builds only. Presses Show me how and Try one like it on whatever problem page is open, at set times after launch, so the
/// flow can be checked on a real iPad with nobody tapping: `--qa-show-me "show@10,like@25,show@70"` (action, then seconds after
/// launch; actions: `show`, `like`). Each press is logged as `qa_show_me_pressed`, a press with no page open as `qa_show_me_skipped`.
@MainActor
enum QAShowMe {
    /// The page on screen now; set by the problem page when it appears, so a press after Try one like it reaches the new page.
    static weak var current: TutorSession?

    private static func requested() -> [(action: String, seconds: Double)] {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--qa-show-me"), arguments.indices.contains(index + 1) else { return [] }
        return arguments[index + 1].split(separator: ",").compactMap { item in
            let parts = item.split(separator: "@")
            guard parts.count == 2, let seconds = Double(parts[1]) else { return nil }
            return (String(parts[0]), seconds)
        }
    }

    static func scheduleIfRequested(log: SessionLog) {
        let presses = requested()
        guard !presses.isEmpty else { return }
        log.record("qa_show_me_scheduled", ["count": presses.count])
        for (number, press) in presses.enumerated() {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(press.seconds * 1_000_000_000))
                guard let session = current else {
                    log.record("qa_show_me_skipped", ["n": number, "action": press.action, "reason": "no_page_open"])
                    return
                }
                switch press.action {
                case "show": session.showMeHow()
                case "like": session.showMe.tryOneLikeIt()
                default:
                    log.record("qa_show_me_skipped", ["n": number, "action": press.action, "reason": "unknown_action"])
                    return
                }
                log.record("qa_show_me_pressed", ["n": number, "action": press.action, "problem_id": session.problem.id])
            }
        }
    }
}
#endif
