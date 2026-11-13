import OSLog
import PencilKit
import SwiftUI

/// The PencilKit page. Follows the system setting: with a paired Apple Pencil only the Pencil draws, so a
/// resting palm leaves no marks; with no Pencil connected a finger draws. (On the first device run,
/// 2026-11-13, "the Pencil draws nothing" turned out to be a disconnected Pencil.) `--any-input` is for UI tests.
/// Marks from the tutor are NOT drawn here: they live on a separate overlay above this view.
/// Every touch type, the canvas size and the swipe-back blocking go to the session log, so a dead
/// page shows up in the log instead of failing silently.
struct InkCanvas: UIViewRepresentable {
    let session: TutorSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = SwipeBackBlockingCanvas()
        canvas.drawingPolicy = LaunchOptions.anyInput ? .anyInput : .default
        canvas.overrideUserInterfaceStyle = .light
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.isScrollEnabled = false
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.accessibilityIdentifier = "drawingCanvas"
        canvas.delegate = context.coordinator
        canvas.onDiagnostic = { [weak session] type, fields in
            session?.noteCanvas(type, fields)
        }

        if !LaunchOptions.anyInput {
            // The system tool picker (pen, eraser, undo). Skipped in UI tests, where it only gets in the way.
            let picker = PKToolPicker()
            picker.addObserver(canvas)
            context.coordinator.toolPicker = picker
            DispatchQueue.main.async {
                picker.setVisible(true, forFirstResponder: canvas)
                let isFirstResponder = canvas.becomeFirstResponder()
                session.noteCanvas("tool_picker_shown", ["first_responder": isFirstResponder])
            }
        }

        session.attach(canvas: canvas)
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    /// iPadOS 26 lets a swipe anywhere on screen pop the navigation stack, so a left-to-right
    /// pen stroke went "back" instead of writing (first real-device run, 2026-11-13).
    /// While the page is on screen both swipe-back gestures are off; the Back button still works.
    final class SwipeBackBlockingCanvas: PKCanvasView {
        private static let log = Logger(subsystem: "com.edwardtran.penciltutor", category: "canvas")
        private static let maxLoggedTouches = 30

        var onDiagnostic: ((String, [String: Any]) -> Void)?
        private weak var blockedNavigation: UINavigationController?
        private var loggedTouches = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onDiagnostic?("canvas_on_screen", ["width": Int(bounds.width), "height": Int(bounds.height),
                                                   "policy": drawingPolicy == .anyInput ? "anyInput" : "default"])
                blockSwipeBack(attempt: 1)
            } else {
                restoreSwipeBack()
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            guard loggedTouches < Self.maxLoggedTouches, let touch = touches.first else { return }
            loggedTouches += 1
            let kind: String
            switch touch.type {
            case .pencil: kind = "pencil"
            case .direct: kind = "finger"
            default: kind = "other"
            }
            let toolName = (tool as? PKInkingTool).map { "ink:\($0.inkType.rawValue)" } ?? String(describing: type(of: tool))
            onDiagnostic?("touch_began", ["kind": kind, "tool": toolName, "n": loggedTouches,
                                          "width": Int(bounds.width), "height": Int(bounds.height)])
        }

        private func blockSwipeBack(attempt: Int) {
            guard let navigation = nearestNavigationController() else {
                // The hosting controller may not be in the stack yet on the first pass.
                if attempt < 3 {
                    DispatchQueue.main.async { [weak self] in self?.blockSwipeBack(attempt: attempt + 1) }
                } else {
                    Self.log.error("swipe-back not blocked: no navigation controller found after \(attempt) tries")
                    onDiagnostic?("swipe_back_not_blocked", ["why": "no navigation controller", "attempts": attempt])
                }
                return
            }
            navigation.interactivePopGestureRecognizer?.isEnabled = false
            navigation.interactiveContentPopGestureRecognizer?.isEnabled = false
            blockedNavigation = navigation
            Self.log.info("swipe-back blocked while the page is on screen (attempt \(attempt))")
            onDiagnostic?("swipe_back_blocked", ["attempt": attempt,
                                                 "content_pop_present": navigation.interactiveContentPopGestureRecognizer != nil])
        }

        private func restoreSwipeBack() {
            guard let navigation = blockedNavigation else { return }
            navigation.interactivePopGestureRecognizer?.isEnabled = true
            navigation.interactiveContentPopGestureRecognizer?.isEnabled = true
            blockedNavigation = nil
            Self.log.info("swipe-back restored")
        }

        private func nearestNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, let navigation = controller.navigationController {
                    return navigation
                }
                responder = current.next
            }
            return nil
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let session: TutorSession
        var toolPicker: PKToolPicker?

        init(session: TutorSession) {
            self.session = session
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            session.penDidTouchDown()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            session.penDidLiftOff()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            session.drawingDidChange()
        }
    }
}
