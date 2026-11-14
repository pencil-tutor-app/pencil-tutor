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
/// space; only the overlay has to apply the zoom and subtract the scroll offset (`CanvasViewport`). The wheel's lasso selects,
/// moves, cuts and deletes ink; every such edit reaches the session through `canvasViewDrawingDidChange` like a written stroke.
///
/// The tools come from the in-app radial wheel (`ToolWheelModel`, drawn by `ToolWheelView`), not the system tool picker
/// (2026-11-14). The canvas only holds the tool the wheel last set; the Pencil double-tap and squeeze come in here through
/// `UIPencilInteraction` because nothing else handles them once the system picker is gone.
struct InkCanvas: UIViewRepresentable {
    let session: TutorSession
    let wheel: ToolWheelModel

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, wheel: wheel)
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

        // The wheel shows in UI tests too (`--any-input`): it is one closed 56 pt handle in the bottom-right corner, outside
        // the area the tests draw in, and showing it means the tests exercise the same tool path as a real run.
        wheel.attach(canvas: canvas) { [weak session] type, fields in session?.noteCanvas(type, fields) }
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        canvas.addInteraction(pencil)
        DispatchQueue.main.async {
            // First responder so the canvas has an undo manager and shake-to-undo works, as it did under the system picker.
            let isFirstResponder = canvas.becomeFirstResponder()
            wheel.reportReady(firstResponder: isFirstResponder)
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

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        let session: TutorSession
        let wheel: ToolWheelModel

        init(session: TutorSession, wheel: ToolWheelModel) {
            self.session = session
            self.wheel = wheel
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            // Writing again puts the open wheel away.
            wheel.close(reason: "pen_down")
            session.penDidTouchDown(tool: Self.toolLabel(canvasView.tool))
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            session.penDidLiftOff()
        }

        /// Written strokes, eraser passes and every lasso edit (delete, cut, paste, move) all land here.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            wheel.refreshUndoState()
            session.drawingDidChange()
        }

        /// A lasso loop that only selects changes no ink, so it must not start a look; it is logged so a selection is visible.
        @objc func canvasViewSelectionDidChange(_ canvasView: PKCanvasView) {
            session.noteCanvas("lasso_selection_changed", [:])
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            wheel.close(reason: "scroll")
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
            wheel.pencilGesture(.doubleTap, preferred: PencilPreference(UIPencilInteraction.preferredTapAction))
        }

        /// Squeeze (Pencil Pro): same idea, its own setting. Acts when the squeeze is released.
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            wheel.pencilGesture(.squeeze, preferred: PencilPreference(UIPencilInteraction.preferredSqueezeAction))
        }

        private static func toolLabel(_ tool: PKTool) -> String {
            if tool is PKLassoTool { return "lasso" }
            if tool is PKEraserTool { return "eraser" }
            if tool is PKInkingTool { return "ink" }
            return "other"
        }
    }
}

// MARK: - The tool wheel (2026-11-14)
//
// Our own radial wheel in place of the system tool picker. A small round handle floats over the page; tapping it opens a ring
// of tools around it. The picker needed no code for undo, Pencil double-tap or the lasso; the wheel does it all explicitly, and
// logs every choice (labels only). The pure parts (`ToolWheelGeometry`, `ToolWheelStyle`, `PencilPreference`) have no UI in
// them so they are unit tested; `ToolWheelModel` ties them to the canvas; `ToolWheelView` (ProblemScreen.swift) draws them.

enum WheelTool: String, CaseIterable {
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

/// What the wheel has chosen. Choosing a colour or width while the eraser or lasso is selected goes back to the last inking
/// tool, because that is what the tap means.
struct ToolWheelStyle: Equatable {
    var tool: WheelTool = .pen
    var colour: InkColour = .black
    var width: InkWidth = .medium
    var lastInk: WheelTool = .pen

    mutating func select(_ tool: WheelTool) {
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

/// What the Pencil's double-tap or squeeze is set to do in Settings > Apple Pencil, reduced to what the wheel can honour.
enum PencilPreference: String {
    case switchEraser, switchPrevious, openPalette, ignore
    /// A system shortcut or anything newer than this code: the system handles it, the wheel does nothing.
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
    case select(WheelTool)
    case openWheel
    case nothing
}

enum PencilGesture: String {
    case doubleTap = "double_tap"
    case squeeze
}

enum PencilRules {
    /// "Switch to eraser" toggles: the first gesture goes to the eraser, the next returns to the tool before it.
    /// "Switch to previous" swaps the current and the previous tool.
    static func outcome(for preference: PencilPreference, current: WheelTool, previous: WheelTool) -> PencilOutcome {
        switch preference {
        case .switchEraser:
            if current == .eraser { return .select(previous == .eraser ? .pen : previous) }
            return .select(.eraser)
        case .switchPrevious:
            return previous == current ? .nothing : .select(previous)
        case .openPalette:
            return .openWheel
        case .ignore, .system:
            return .nothing
        }
    }
}

/// The arithmetic of the wheel: where the handle sits, where it snaps to, where the ring opens. No UIKit.
enum ToolWheelGeometry {
    static let handleDiameter: CGFloat = 56
    static let edgeMargin: CGFloat = 14
    /// Inner ring: the four tools, undo and redo. Outer ring: four colours and three widths.
    static let innerRadius: CGFloat = 70
    static let outerRadius: CGFloat = 128
    static let innerItemSize: CGFloat = 50
    static let outerItemSize: CGFloat = 44
    /// The soft disc behind the ring; the ring never reaches past it.
    static var discRadius: CGFloat { outerRadius + outerItemSize / 2 + 10 }

    /// The area the handle's centre may be in.
    static func travel(in size: CGSize) -> CGRect {
        let inset = edgeMargin + handleDiameter / 2
        return CGRect(x: inset, y: inset, width: max(0, size.width - 2 * inset), height: max(0, size.height - 2 * inset))
    }

    /// Handle position as a fraction of the travel area: (0,0) top-left, (1,1) bottom-right.
    static func handleCenter(fraction: CGPoint, in size: CGSize) -> CGPoint {
        let area = travel(in: size)
        return CGPoint(x: area.minX + min(max(fraction.x, 0), 1) * area.width,
                       y: area.minY + min(max(fraction.y, 0), 1) * area.height)
    }

    /// Where a dropped handle settles: on the nearest edge of the travel area, at the dropped position along that edge.
    static func snappedFraction(center: CGPoint, in size: CGSize) -> CGPoint {
        let area = travel(in: size)
        let x = fraction(center.x, area.minX, area.width)
        let y = fraction(center.y, area.minY, area.height)
        let toEdges = [x, 1 - x, y, 1 - y]   // left, right, top, bottom, as fractions
        switch toEdges.firstIndex(of: toEdges.min() ?? 0) ?? 0 {
        case 0: return CGPoint(x: 0, y: y)
        case 1: return CGPoint(x: 1, y: y)
        case 2: return CGPoint(x: x, y: 0)
        default: return CGPoint(x: x, y: 1)
        }
    }

    /// Where the middle of the ring sits when the handle opens: the handle's own place, moved inward just far enough that the
    /// whole disc is on the page. A handle on an edge therefore slides in when it opens and slides back when it closes.
    static func openCenter(handleCenter: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: clamp(handleCenter.x, discRadius, size.width - discRadius),
                y: clamp(handleCenter.y, discRadius, size.height - discRadius))
    }

    /// Item centres on a ring, as offsets from the middle, evenly spaced clockwise starting at the top.
    static func ringOffsets(count: Int, radius: CGFloat, startAngle: CGFloat = -.pi / 2) -> [CGPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let angle = startAngle + 2 * .pi * CGFloat(index) / CGFloat(count)
            return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
        }
    }

    /// "right", "bottom_right" (a corner), ... for the log.
    static func edgeLabel(fraction: CGPoint) -> String {
        var parts: [String] = []
        if fraction.y <= 0.001 { parts.append("top") } else if fraction.y >= 0.999 { parts.append("bottom") }
        if fraction.x <= 0.001 { parts.append("left") } else if fraction.x >= 0.999 { parts.append("right") }
        return parts.isEmpty ? "inside" : parts.joined(separator: "_")
    }

    private static func fraction(_ value: CGFloat, _ origin: CGFloat, _ span: CGFloat) -> CGFloat {
        span > 0 ? min(max((value - origin) / span, 0), 1) : 0.5
    }

    /// Like `min(max(v, low), high)` but when the room is smaller than the disc it centres instead of pinning to one side.
    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        high < low ? (low + high) / 2 : min(max(value, low), high)
    }
}

/// The wheel's state, and the one place that sets the canvas's tool. Every choice is logged with labels only.
@MainActor
final class ToolWheelModel: ObservableObject {
    @Published private(set) var style: ToolWheelStyle
    @Published private(set) var isOpen = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Handle position as a fraction of its travel area; kept between launches.
    @Published private(set) var handleFraction: CGPoint

    private weak var canvas: PKCanvasView?
    private var log: (String, [String: Any]) -> Void = { _, _ in }
    private var previousTool: WheelTool = .eraser
    private let defaults: UserDefaults

    private enum Key {
        static let handleX = "toolWheel.handleX"
        static let handleY = "toolWheel.handleY"
        static let ink = "toolWheel.ink"
        static let colour = "toolWheel.colour"
        static let width = "toolWheel.width"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var style = ToolWheelStyle()
        if let raw = defaults.string(forKey: Key.ink), let tool = WheelTool(rawValue: raw), tool.isInk { style.select(tool) }
        if let raw = defaults.string(forKey: Key.colour), let colour = InkColour(rawValue: raw) { style.colour = colour }
        if let raw = defaults.string(forKey: Key.width), let width = InkWidth(rawValue: raw) { style.width = width }
        self.style = style
        if defaults.object(forKey: Key.handleX) != nil, defaults.object(forKey: Key.handleY) != nil {
            handleFraction = CGPoint(x: defaults.double(forKey: Key.handleX), y: defaults.double(forKey: Key.handleY))
        } else {
            handleFraction = CGPoint(x: 1, y: 1)   // bottom-right corner
        }
        previousTool = style.lastInk
    }

    func attach(canvas: PKCanvasView, log: @escaping (String, [String: Any]) -> Void) {
        self.canvas = canvas
        self.log = log
        canvas.tool = style.pkTool()
    }

    /// Replaces the old `tool_picker_items` / `tool_picker_shown` diagnostics: the wheel is up, with this much of it working.
    func reportReady(firstResponder: Bool) {
        refreshUndoState()
        log("wheel_ready", [
            "first_responder": firstResponder, "has_undo_manager": canvas?.undoManager != nil,
            "tools": WheelTool.allCases.map(\.rawValue).joined(separator: ","),
            "tool": style.tool.rawValue, "colour": style.colour.rawValue, "width": style.width.rawValue,
            "handle": ToolWheelGeometry.edgeLabel(fraction: handleFraction),
            "tap_action": PencilPreference(UIPencilInteraction.preferredTapAction).rawValue,
            "squeeze_action": PencilPreference(UIPencilInteraction.preferredSqueezeAction).rawValue
        ])
    }

    // MARK: Open and close

    func toggle() {
        isOpen ? close(reason: "tap_handle") : open(reason: "tap_handle")
    }

    func open(reason: String) {
        guard !isOpen else { return }
        refreshUndoState()
        isOpen = true
        log("wheel_opened", ["reason": reason, "tool": style.tool.rawValue])
    }

    func close(reason: String) {
        guard isOpen else { return }
        isOpen = false
        log("wheel_closed", ["reason": reason, "tool": style.tool.rawValue])
    }

    // MARK: Choices

    /// Tapping a tool selects it and puts the wheel away.
    func select(_ tool: WheelTool, source: String = "wheel") {
        if tool != style.tool { previousTool = style.tool }
        style.select(tool)
        apply(source: source)
        persistStyle()
        close(reason: "tool_chosen")
    }

    /// A colour or width changes the pen and leaves the wheel open, so both can be set in one visit.
    func choose(colour: InkColour) {
        if !style.tool.isInk { previousTool = style.tool }
        style.choose(colour: colour)
        apply(source: "wheel")
        persistStyle()
    }

    func choose(width: InkWidth) {
        if !style.tool.isInk { previousTool = style.tool }
        style.choose(width: width)
        apply(source: "wheel")
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

    func undo() { runUndo(redo: false) }
    func redo() { runUndo(redo: true) }

    private func runUndo(redo: Bool) {
        let name = redo ? "wheel_redo" : "wheel_undo"
        guard let manager = canvas?.undoManager else {
            log("\(name)_unavailable", ["why": "canvas has no undo manager"])
            return
        }
        guard redo ? manager.canRedo : manager.canUndo else {
            log("\(name)_unavailable", ["why": "nothing to \(redo ? "redo" : "undo")"])
            refreshUndoState()
            return
        }
        if redo { manager.redo() } else { manager.undo() }
        refreshUndoState()
        log(name, ["can_undo": canUndo, "can_redo": canRedo])
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
        case .openWheel:
            log(event, ["action": preferred.rawValue, "result": "open_wheel"])
            open(reason: gesture.rawValue)
        case .nothing:
            log(event, ["action": preferred.rawValue, "result": "nothing"])
        }
    }

    // MARK: Handle position

    /// The handle was dropped at `center` inside a container of `size`: snap it to the nearest edge and remember it.
    func dropHandle(at center: CGPoint, in size: CGSize) {
        let fraction = ToolWheelGeometry.snappedFraction(center: center, in: size)
        handleFraction = fraction
        defaults.set(Double(fraction.x), forKey: Key.handleX)
        defaults.set(Double(fraction.y), forKey: Key.handleY)
        log("wheel_handle_moved", ["edge": ToolWheelGeometry.edgeLabel(fraction: fraction),
                                   "fx": (Double(fraction.x) * 100).rounded() / 100, "fy": (Double(fraction.y) * 100).rounded() / 100])
    }
}
