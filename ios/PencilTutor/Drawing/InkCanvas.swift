import OSLog
import PencilKit
import SwiftUI

/// Where the page is scrolled to and how far it is zoomed. Its own small object (not part of `TutorSession`'s published state)
/// so a scroll or pinch, which changes it every frame, redraws only the marks overlay and not the whole problem screen.
@MainActor
final class CanvasViewport: ObservableObject {
    /// How far the page is scrolled: `contentOffset` of the canvas, in screen points (page points times `zoomScale`).
    @Published private(set) var offset = CGPoint.zero
    /// The whole page as the scroll view reports it: unzoomed `PageGeometry.contentSize` times `zoomScale`, in screen points.
    @Published private(set) var contentSize = CGSize.zero
    /// The pinch zoom, 0.5 to 3. A page point `p` is on screen at `p * zoomScale - offset`.
    @Published private(set) var zoomScale: CGFloat = 1

    func update(offset: CGPoint? = nil, contentSize: CGSize? = nil, zoomScale: CGFloat? = nil) {
        if let offset, offset != self.offset { self.offset = offset }
        if let contentSize, contentSize != self.contentSize { self.contentSize = contentSize }
        if let zoomScale, zoomScale != self.zoomScale { self.zoomScale = zoomScale }
    }
}

/// The PencilKit page. Follows the system setting: with a paired Apple Pencil only the Pencil draws, so a
/// resting palm leaves no marks; with no Pencil connected a finger draws. (On the first device run,
/// 2026-11-13, "the Pencil draws nothing" turned out to be a disconnected Pencil.) `--any-input` is for UI tests.
/// Marks from the tutor are NOT drawn here: they live on a separate overlay above this view.
/// Every touch type, the canvas size and the swipe-back blocking go to the session log, so a dead
/// page shows up in the log instead of failing silently.
///
/// The page is endless in every direction (2026-11-14): fingers pan it and pinch it between 0.5x and 3x, the Pencil writes, and
/// the session keeps `contentSize` about one screen past the ink on every side (`PageGeometry`). Drawing coordinates are
/// content coordinates and unzoomed, so the ink, the line boxes sent to the tutor and the tutor's marks all share one coordinate
/// space; only the overlay has to apply the zoom and subtract the scroll offset (`CanvasViewport`). The rail's lasso selects,
/// moves, cuts and deletes ink; every such edit reaches the session through `canvasViewDrawingDidChange` like a written stroke.
///
/// The tools come from the in-app tool rail (`ToolRailModel`, drawn by `ToolRailView`), not the system tool picker
/// (2026-11-14). The canvas only holds the tool the rail last set; the Pencil double-tap and squeeze come in here through
/// `UIPencilInteraction` because nothing else handles them once the system picker is gone. A two-finger tap on the page is undo
/// and a three-finger tap is redo (`RailGestureRules`); both recognisers accept finger touches only and run alongside the
/// canvas's own pan and pinch.
struct InkCanvas: UIViewRepresentable {
    let session: TutorSession
    let rail: ToolRailModel

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, rail: rail)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = SwipeBackBlockingCanvas()
        canvas.drawingPolicy = LaunchOptions.anyInput ? .anyInput : .default
        canvas.overrideUserInterfaceStyle = .light
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        // Pan in every direction and pinch to zoom. Fingers move the page, the Pencil writes (the default drawing policy).
        // Insets stay off so contentOffset is the distance from the top-left corner of the content.
        canvas.isScrollEnabled = true
        canvas.alwaysBounceVertical = true
        canvas.alwaysBounceHorizontal = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        canvas.isDirectionalLockEnabled = false
        canvas.minimumZoomScale = PageGeometry.minZoom
        canvas.maximumZoomScale = PageGeometry.maxZoom
        canvas.bouncesZoom = true
        canvas.contentInsetAdjustmentBehavior = .never
        if LaunchOptions.anyInput {
            // UI tests draw with one finger; scrolling then takes two fingers so a drag is never both.
            canvas.panGestureRecognizer.minimumNumberOfTouches = 2
        }
        canvas.accessibilityIdentifier = "drawingCanvas"
        canvas.delegate = context.coordinator
        canvas.onDiagnostic = { [weak session] type, fields in
            session?.noteCanvas(type, fields)
        }
        canvas.onResize = { [weak session] in
            session?.syncPageSize(reason: "view_resized")
        }

        // The rail shows in UI tests too (`--any-input`): it is a slim strip on the left edge, and showing it means the tests
        // exercise the same tool path as a real run.
        rail.attach(canvas: canvas) { [weak session] type, fields in session?.noteCanvas(type, fields) }
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        canvas.addInteraction(pencil)
        context.coordinator.installFingerTaps(on: canvas)
        DispatchQueue.main.async {
            // First responder so the canvas has an undo manager and shake-to-undo works, as it did under the system picker.
            let isFirstResponder = canvas.becomeFirstResponder()
            rail.reportReady(firstResponder: isFirstResponder)
        }

        session.attach(canvas: canvas)
        #if DEBUG
        InkReplay.startIfRequested(canvas: canvas, session: session)   // `--replay-ink <file>`; compiled out of Release
        #endif
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
        /// Called when the view's size changes (rotation, split view), so the page size can follow.
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

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        let session: TutorSession
        let rail: ToolRailModel

        init(session: TutorSession, rail: ToolRailModel) {
            self.session = session
            self.rail = rail
        }

        /// Two-finger tap = undo, three-finger tap = redo. Fingers only (`allowedTouchTypes`), no touch is cancelled, and the
        /// recognisers run alongside the canvas's pan and pinch: a tap that lifts quickly never moves far enough to start
        /// either. The two-finger tap waits for the three-finger one to fail, so a three-finger tap is never also an undo.
        func installFingerTaps(on canvas: UIView) {
            let three = makeTap(fingers: 3, action: #selector(threeFingerTap))
            let two = makeTap(fingers: 2, action: #selector(twoFingerTap))
            two.require(toFail: three)
            canvas.addGestureRecognizer(three)
            canvas.addGestureRecognizer(two)
        }

        private func makeTap(fingers: Int, action: Selector) -> UITapGestureRecognizer {
            let tap = UITapGestureRecognizer(target: self, action: action)
            tap.numberOfTouchesRequired = fingers
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            tap.cancelsTouchesInView = false
            tap.delegate = self
            return tap
        }

        @objc private func twoFingerTap() { fingerTap(fingers: 2) }
        @objc private func threeFingerTap() { fingerTap(fingers: 3) }

        private func fingerTap(fingers: Int) {
            guard let gesture = RailGestureRules.gesture(forTapWith: fingers, usingFingers: true) else { return }
            rail.fingerTap(gesture)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            session.penDidTouchDown(tool: Self.toolLabel(canvasView.tool))
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            session.penDidLiftOff()
        }

        /// Written strokes, eraser passes and every lasso edit (delete, cut, paste, move) all land here.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            rail.refreshUndoState()
            session.drawingDidChange()
        }

        /// A lasso loop that only selects changes no ink, so it must not start a look; it is logged so a selection is visible.
        @objc func canvasViewSelectionDidChange(_ canvasView: PKCanvasView) {
            session.noteCanvas("lasso_selection_changed", [:])
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            session.viewportDidScroll(to: scrollView.contentOffset)
        }

        /// Pinch in progress: the marks overlay follows the zoom every frame.
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            session.viewportDidScroll(to: scrollView.contentOffset)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            session.viewportDidZoomSettle(scale: scale)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { session.viewportDidSettle(at: scrollView.contentOffset) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            session.viewportDidSettle(at: scrollView.contentOffset)
        }

        /// Double-tap on the Pencil: do what the student chose in Settings > Apple Pencil (eraser and back by default).
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            rail.pencilGesture(.doubleTap,preferred: PencilPreference(UIPencilInteraction.preferredTapAction))
        }

        /// Squeeze (Pencil Pro): same idea, its own setting. Acts when the squeeze is released.
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            rail.pencilGesture(.squeeze,preferred: PencilPreference(UIPencilInteraction.preferredSqueezeAction))
        }

        private static func toolLabel(_ tool: PKTool) -> String {
            if tool is PKLassoTool { return "lasso" }
            if tool is PKEraserTool { return "eraser" }
            if tool is PKInkingTool { return "ink" }
            return "other"
        }
    }
}

// MARK: - The tool rail (2026-11-14, replaces the radial wheel the same day)
//
// Our own tool rail in place of the system tool picker: one slim capsule docked top-left, under the Back button, always on screen.
// It never opens or closes; every tap changes the tool and leaves everything where it was (Edward, after trying the wheel: it
// closed on every pick, so each tool or colour change cost a reopen). The picker needed no code for undo, Pencil double-tap or the
// lasso; the rail does it all explicitly, and logs every choice (labels only). The pure parts (`ToolRailStyle`, `PencilRules`,
// `RailGestureRules`) have no UI in them so they are unit tested; `ToolRailModel` ties them to the canvas; `ToolRailView`
// (ProblemScreen.swift) draws them.

enum RailTool: String, CaseIterable {
    case pen, marker, eraser, lasso

    var label: String {
        switch self {
        case .pen: return "Pen"
        case .marker: return "Highlighter"
        case .eraser: return "Eraser"
        case .lasso: return "Lasso"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }

    var isInk: Bool { self == .pen || self == .marker }
}

enum InkColour: String, CaseIterable {
    case black, blue, red, green

    var label: String { rawValue.capitalized }

    /// Fixed colours, not the dynamic system ones: the page is always light and the tutor reads a light rendering of it.
    var uiColor: UIColor {
        switch self {
        case .black: return .black
        case .blue: return UIColor(red: 0.05, green: 0.30, blue: 0.85, alpha: 1)
        case .red: return UIColor(red: 0.78, green: 0.12, blue: 0.12, alpha: 1)   // darker than the tutor's circle on purpose
        case .green: return UIColor(red: 0.08, green: 0.55, blue: 0.22, alpha: 1)
        }
    }

    /// The highlighter has no black: a black bar would hide the writing it is meant to mark, so black becomes yellow.
    var highlighterColor: UIColor {
        self == .black ? UIColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1) : uiColor
    }
}

enum InkWidth: String, CaseIterable {
    case thin, medium, thick

    var label: String { rawValue.capitalized }
    var penWidth: CGFloat {
        switch self {
        case .thin: return 2.5
        case .medium: return 4
        case .thick: return 7
        }
    }
    var highlighterWidth: CGFloat {
        switch self {
        case .thin: return 12
        case .medium: return 20
        case .thick: return 32
        }
    }
}

/// What the rail has chosen. Choosing a colour or width while the eraser or lasso is selected goes back to the last inking
/// tool, because that is what the tap means.
struct ToolRailStyle: Equatable {
    var tool: RailTool = .pen
    var colour: InkColour = .black
    var width: InkWidth = .medium
    var lastInk: RailTool = .pen

    mutating func select(_ tool: RailTool) {
        self.tool = tool
        if tool.isInk { lastInk = tool }
    }

    mutating func choose(colour: InkColour) {
        self.colour = colour
        if !tool.isInk { tool = lastInk }
    }

    mutating func choose(width: InkWidth) {
        self.width = width
        if !tool.isInk { tool = lastInk }
    }

    /// What the student hears and sees: "Pen, blue, thick" or "Eraser".
    var summary: String {
        tool.isInk ? "\(tool.label), \(colour.rawValue), \(width.rawValue)" : tool.label
    }

    /// The colour a swatch shows: the highlighter's own colour while the highlighter is on (black shows yellow), else the ink's.
    func swatchColour(_ colour: InkColour) -> UIColor {
        tool == .marker ? colour.highlighterColor : colour.uiColor
    }

    /// The tool for the canvas.
    func pkTool() -> PKTool {
        switch tool {
        case .pen:
            return PKInkingTool(.pen, color: colour.uiColor, width: Self.clamped(width.penWidth, for: .pen))
        case .marker:
            return PKInkingTool(.marker, color: colour.highlighterColor, width: Self.clamped(width.highlighterWidth, for: .marker))
        case .eraser:
            // Vector: a touch removes the whole stroke, which is what a student wants from "erase this" and what the line
            // grouper counts (`strokes_delta`).
            return PKEraserTool(.vector)
        case .lasso:
            return PKLassoTool()
        }
    }

    private static func clamped(_ width: CGFloat, for type: PKInk.InkType) -> CGFloat {
        let range = type.validWidthRange
        return min(max(width, range.lowerBound), range.upperBound)
    }
}

/// What the Pencil's double-tap or squeeze is set to do in Settings > Apple Pencil, reduced to what the rail can honour.
enum PencilPreference: String {
    case switchEraser, switchPrevious, openPalette, ignore
    /// A system shortcut or anything newer than this code: the system handles it, the rail does nothing.
    case system

    init(_ action: UIPencilPreferredAction) {
        switch action {
        case .switchEraser: self = .switchEraser
        case .switchPrevious: self = .switchPrevious
        case .showColorPalette, .showInkAttributes, .showContextualPalette: self = .openPalette
        case .ignore: self = .ignore
        default: self = .system
        }
    }
}

enum PencilOutcome: Equatable {
    case select(RailTool)
    /// "Show the palette" has nothing to show: the rail is always on screen. Logged as `rail_always_visible`.
    case railAlwaysVisible
    case nothing
}

enum PencilGesture: String {
    case doubleTap = "double_tap"
    case squeeze
}

enum PencilRules {
    /// "Switch to eraser" toggles: the first gesture goes to the eraser, the next returns to the tool before it.
    /// "Switch to previous" swaps the current and the previous tool.
    static func outcome(for preference: PencilPreference, current: RailTool, previous: RailTool) -> PencilOutcome {
        switch preference {
        case .switchEraser:
            if current == .eraser { return .select(previous == .eraser ? .pen : previous) }
            return .select(.eraser)
        case .switchPrevious:
            return previous == current ? .nothing : .select(previous)
        case .openPalette:
            return .railAlwaysVisible
        case .ignore, .system:
            return .nothing
        }
    }
}

/// Finger taps on the page that stand in for the undo and redo buttons (Concepts-style): two fingers undo, three fingers redo.
/// The Pencil never counts, and one finger is just a touch of the page.
enum RailTouchGesture: String, Equatable {
    case undo, redo
}

enum RailGestureRules {
    static func gesture(forTapWith fingers: Int, usingFingers: Bool) -> RailTouchGesture? {
        guard usingFingers else { return nil }
        switch fingers {
        case 2: return .undo
        case 3: return .redo
        default: return nil
        }
    }
}

/// What an undo or redo did, for the log: `done`, `nothing` (the stack was empty) or `no_undo_manager`.
enum UndoResult: String {
    case done, nothing
    case noUndoManager = "no_undo_manager"
}

/// The rail's state, and the one place that sets the canvas's tool. Every choice is logged with labels only.
@MainActor
final class ToolRailModel: ObservableObject {
    @Published private(set) var style: ToolRailStyle
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private weak var canvas: PKCanvasView?
    private var log: (String, [String: Any]) -> Void = { _, _ in }
    private var previousTool: RailTool = .eraser
    private let defaults: UserDefaults

    /// UserDefaults keys keep the names the wheel used, so a student's pen, colour and width survive the change.
    private enum Key {
        static let ink = "toolWheel.ink"
        static let colour = "toolWheel.colour"
        static let width = "toolWheel.width"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var style = ToolRailStyle()
        if let raw = defaults.string(forKey: Key.ink), let tool = RailTool(rawValue: raw), tool.isInk { style.select(tool) }
        if let raw = defaults.string(forKey: Key.colour), let colour = InkColour(rawValue: raw) { style.colour = colour }
        if let raw = defaults.string(forKey: Key.width), let width = InkWidth(rawValue: raw) { style.width = width }
        self.style = style
        previousTool = style.lastInk
    }

    func attach(canvas: PKCanvasView, log: @escaping (String, [String: Any]) -> Void) {
        self.canvas = canvas
        self.log = log
        canvas.tool = style.pkTool()
    }

    /// The rail is up, with this much of it working.
    func reportReady(firstResponder: Bool) {
        refreshUndoState()
        log("rail_ready", [
            "first_responder": firstResponder, "has_undo_manager": canvas?.undoManager != nil,
            "tools": RailTool.allCases.map(\.rawValue).joined(separator: ","),
            "tool": style.tool.rawValue, "colour": style.colour.rawValue, "width": style.width.rawValue,
            "tap_action": PencilPreference(UIPencilInteraction.preferredTapAction).rawValue,
            "squeeze_action": PencilPreference(UIPencilInteraction.preferredSqueezeAction).rawValue
        ])
    }

    // MARK: Choices (nothing here hides the rail)

    func select(_ tool: RailTool, source: String = "rail") {
        if tool != style.tool { previousTool = style.tool }
        style.select(tool)
        apply(source: source)
        persistStyle()
    }

    func choose(colour: InkColour) {
        if !style.tool.isInk { previousTool = style.tool }
        style.choose(colour: colour)
        apply(source: "rail")
        persistStyle()
    }

    func choose(width: InkWidth) {
        if !style.tool.isInk { previousTool = style.tool }
        style.choose(width: width)
        apply(source: "rail")
        persistStyle()
    }

    private func apply(source: String) {
        guard let canvas else {
            log("tool_selected_failed", ["why": "no canvas attached", "tool": style.tool.rawValue])
            return
        }
        canvas.tool = style.pkTool()
        log("tool_selected", ["tool": style.tool.rawValue, "colour": style.colour.rawValue, "width": style.width.rawValue,
                              "source": source])
    }

    private func persistStyle() {
        defaults.set(style.lastInk.rawValue, forKey: Key.ink)
        defaults.set(style.colour.rawValue, forKey: Key.colour)
        defaults.set(style.width.rawValue, forKey: Key.width)
    }

    // MARK: Undo and redo (the canvas's own undo manager: written strokes, erasing, lasso edits and Erase page)

    func undo() { runUndo(redo: false, event: "rail_undo") }
    func redo() { runUndo(redo: true, event: "rail_redo") }

    /// A two- or three-finger tap on the page.
    func fingerTap(_ gesture: RailTouchGesture) {
        switch gesture {
        case .undo: runUndo(redo: false, event: "gesture_undo")
        case .redo: runUndo(redo: true, event: "gesture_redo")
        }
    }

    @discardableResult
    private func runUndo(redo: Bool, event: String) -> UndoResult {
        let result: UndoResult
        if let manager = canvas?.undoManager {
            if redo ? manager.canRedo : manager.canUndo {
                if redo { manager.redo() } else { manager.undo() }
                result = .done
            } else {
                result = .nothing
            }
        } else {
            result = .noUndoManager
        }
        refreshUndoState()
        log(event, ["result": result.rawValue, "can_undo": canUndo, "can_redo": canRedo])
        return result
    }

    func refreshUndoState() {
        let manager = canvas?.undoManager
        let undo = manager?.canUndo ?? false
        let redo = manager?.canRedo ?? false
        if undo != canUndo { canUndo = undo }
        if redo != canRedo { canRedo = redo }
    }

    // MARK: Pencil double-tap and squeeze

    func pencilGesture(_ gesture: PencilGesture, preferred: PencilPreference) {
        let outcome = PencilRules.outcome(for: preferred, current: style.tool, previous: previousTool)
        let event = gesture == .doubleTap ? "pencil_double_tap" : "pencil_squeeze"
        switch outcome {
        case .select(let tool):
            log(event, ["action": preferred.rawValue, "result": "select_\(tool.rawValue)", "from": style.tool.rawValue])
            select(tool, source: gesture.rawValue)
        case .railAlwaysVisible:
            log(event, ["action": preferred.rawValue, "result": "rail_always_visible"])
        case .nothing:
            log(event, ["action": preferred.rawValue, "result": "nothing"])
        }
    }
}
