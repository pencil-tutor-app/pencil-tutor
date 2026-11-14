import OSLog
import PencilKit
import SwiftUI

/// Where the page is scrolled to. Its own small object (not part of `TutorSession`'s published state) so a scroll, which
/// changes it every frame, redraws only the marks overlay and not the whole problem screen.
@MainActor
final class CanvasViewport: ObservableObject {
    /// How far the page is scrolled: `contentOffset` of the canvas, in page points.
    @Published private(set) var offset = CGPoint.zero
    /// The whole page, not just the screen: as wide as the view, as tall as `PageGeometry.contentHeight`.
    @Published private(set) var contentSize = CGSize.zero

    func update(offset: CGPoint? = nil, contentSize: CGSize? = nil) {
        if let offset, offset != self.offset { self.offset = offset }
        if let contentSize, contentSize != self.contentSize { self.contentSize = contentSize }
    }
}

/// The PencilKit page. Follows the system setting: with a paired Apple Pencil only the Pencil draws, so a
/// resting palm leaves no marks; with no Pencil connected a finger draws. (On the first device run,
/// 2026-11-13, "the Pencil draws nothing" turned out to be a disconnected Pencil.) `--any-input` is for UI tests.
/// Marks from the tutor are NOT drawn here: they live on a separate overlay above this view.
/// Every touch type, the canvas size and the swipe-back blocking go to the session log, so a dead
/// page shows up in the log instead of failing silently.
///
/// The page is an endless sheet downward (2026-11-14): the canvas scrolls vertically only, no zoom, and the session keeps
/// `contentSize` about one screen taller than the lowest ink (`PageGeometry`). Drawing coordinates are content coordinates, so
/// the ink, the line boxes sent to the tutor and the tutor's marks all share one coordinate space; only the overlay has to
/// subtract the scroll offset (`CanvasViewport`). The tool picker's lasso selects, moves, cuts and deletes ink; every such edit
/// reaches the session through `canvasViewDrawingDidChange` like a written stroke.
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
        // Vertical scrolling only: the content is exactly as wide as the view, so there is nothing to scroll sideways, and
        // the zoom range is pinned to 1. Insets stay off so contentOffset is the distance from the top of the page.
        canvas.isScrollEnabled = true
        canvas.alwaysBounceVertical = true
        canvas.alwaysBounceHorizontal = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.isDirectionalLockEnabled = true
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        if LaunchOptions.anyInput {
            // UI tests draw with one finger; scrolling then takes two fingers so a drag is never both.
            canvas.panGestureRecognizer.minimumNumberOfTouches = 2
        }
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.accessibilityIdentifier = "drawingCanvas"
        canvas.delegate = context.coordinator
        canvas.onDiagnostic = { [weak session] type, fields in
            session?.noteCanvas(type, fields)
        }
        canvas.onResize = { [weak session] in
            session?.syncPageSize(reason: "view_resized")
        }

        if !LaunchOptions.anyInput {
            // The system tool picker (pens, eraser, lasso, undo). Skipped in UI tests, where it only gets in the way.
            let picker = Self.makeToolPicker(session: session)
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

    /// The default picker already carries a lasso (the header only says "default tool items", so this checks the real list at
    /// run time instead of trusting that). If an OS ever drops it, the lasso item is added back; either way the item list goes
    /// to the session log, so "where is the lasso" is answered from the log, not from a guess.
    @MainActor
    static func makeToolPicker(session: TutorSession) -> PKToolPicker {
        var picker = PKToolPicker()
        var addedLasso = false
        if !picker.toolItems.contains(where: { $0 is PKToolPickerLassoItem }) {
            picker = PKToolPicker(toolItems: picker.toolItems + [PKToolPickerLassoItem()])
            addedLasso = true
        }
        let kinds = picker.toolItems.map { String(describing: type(of: $0)) }
        session.noteCanvas("tool_picker_items", [
            "count": kinds.count, "kinds": kinds.joined(separator: ","),
            "has_lasso": picker.toolItems.contains { $0 is PKToolPickerLassoItem }, "lasso_added_by_app": addedLasso
        ])
        return picker
    }

    /// iPadOS 26 lets a swipe anywhere on screen pop the navigation stack, so a left-to-right
    /// pen stroke went "back" instead of writing (first real-device run, 2026-11-13).
    /// While the page is on screen both swipe-back gestures are off; the Back button still works.
    final class SwipeBackBlockingCanvas: PKCanvasView {
        private static let log = Logger(subsystem: "com.edwardtran.penciltutor", category: "canvas")
        private static let maxLoggedTouches = 30

        var onDiagnostic: ((String, [String: Any]) -> Void)?
        /// Called when the view's size changes (rotation, split view), so the page height can follow.
        var onResize: (() -> Void)?
        private var lastLaidOutSize = CGSize.zero
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

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != lastLaidOutSize else { return }
            lastLaidOutSize = bounds.size
            // Hop out of the layout pass before anyone touches contentSize.
            DispatchQueue.main.async { [weak self] in self?.onResize?() }
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
            session.penDidTouchDown(tool: Self.toolLabel(canvasView.tool))
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            session.penDidLiftOff()
        }

        /// Written strokes, eraser passes and every lasso edit (delete, cut, paste, move) all land here.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            session.drawingDidChange()
        }

        /// A lasso loop that only selects changes no ink, so it must not start a look; it is logged so a selection is visible.
        @objc func canvasViewSelectionDidChange(_ canvasView: PKCanvasView) {
            session.noteCanvas("lasso_selection_changed", [:])
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            session.viewportDidScroll(to: scrollView.contentOffset)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { session.viewportDidSettle(at: scrollView.contentOffset) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            session.viewportDidSettle(at: scrollView.contentOffset)
        }

        private static func toolLabel(_ tool: PKTool) -> String {
            if tool is PKLassoTool { return "lasso" }
            if tool is PKEraserTool { return "eraser" }
            if tool is PKInkingTool { return "ink" }
            return "other"
        }
    }
}
