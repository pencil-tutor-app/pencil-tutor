import SwiftUI
import UIKit
import XCTest
@testable import PencilTutor

/// Stands in for the canvas: a plain UIView under the overlay, so the test can tell "the touch fell through to the page" (the
/// probe is hit) from "the overlay took it" (anything else).
private final class TouchProbeView: UIView {}

private struct TouchProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchProbeView {
        let view = TouchProbeView()
        view.backgroundColor = .white
        return view
    }
    func updateUIView(_ uiView: TouchProbeView, context: Context) {}
}

/// The marks overlay sits above the canvas. Only the "Not a mistake" button may take a touch; everything else (the circle, the hint
/// words, the callout card, empty page) must fall through to the canvas so ink, scrolling and pinching still work beside it.
/// This hosts the real overlay over a probe view in a window and asks UIKit what it would hit, point by point.
@MainActor
final class MarksOverlayHitTestTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1180, height: 820)

    private func host(_ overlay: some View) async -> (UIHostingController<AnyView>, UIWindow) {
        let controller = UIHostingController(rootView: AnyView(ZStack(alignment: .topLeading) {
            TouchProbe().ignoresSafeArea()
            overlay.ignoresSafeArea()
        }))
        controller.view.backgroundColor = .clear
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: screen)
        window.frame = screen
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = screen
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 400_000_000)
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    /// Every sampled point where the overlay, not the page underneath, answers a touch.
    private func overlayHits(_ controller: UIHostingController<AnyView>, step: CGFloat = 4) -> [CGPoint] {
        var hits: [CGPoint] = []
        for y in stride(from: CGFloat(0), to: screen.height, by: step) {
            for x in stride(from: CGFloat(0), to: screen.width, by: step) {
                let point = CGPoint(x: x, y: y)
                if !(controller.view.hitTest(point, with: nil) is TouchProbeView) { hits.append(point) }
            }
        }
        return hits
    }

    func testOnlyTheNotAMistakeButtonTakesATouch() async throws {
        let viewport = CanvasViewport()
        viewport.update(offset: CGPoint(x: 2900, y: 2900), contentSize: CGSize(width: 6000, height: 6000), zoomScale: 1)
        let box = CGRect(x: 3100, y: 3200, width: 400, height: 40)
        let mark = Mark(lineIndex: 2, box: box, hint: "Check the signs here", inkSignature: "")
        let (controller, window) = await host(MarksOverlay(marks: [mark], viewport: viewport))
        defer { window.isHidden = true }

        // Wait for SwiftUI to lay the callout out instead of trusting a fixed pause: on GitHub's slower macos-26 runner the
        // button had no frame yet after 0.4 s (run 46053313003), while Blacksmith's M4 machine was always ready.
        var hits = overlayHits(controller, step: 8)
        for _ in 0..<40 where hits.isEmpty {
            try? await Task.sleep(nanoseconds: 125_000_000)
            controller.view.layoutIfNeeded()
            hits = overlayHits(controller, step: 8)
        }
        if hits.isEmpty {
            // On GitHub's macos-26 runner UIKit's hitTest never reaches the hosted SwiftUI button, even with a window scene and 5 s of
            // layout (runs 46053313003, 46054436954, 46056036868), while Blacksmith's runner hits it. The behaviour itself is checked
            // with a real tap in OwnProblemUITests.testNotAMistakeButtonDismissesTheCircleAndInkAroundItStillDraws (circle gone, ink
            // beside the button and across the hint still drawn), so a probe that sees nothing is reported as a skip, not a pass.
            throw XCTSkip("UIKit hitTest sees no SwiftUI button in this test host; the real tap is checked by OwnProblemUITests")
        }
        hits = overlayHits(controller)
        let total = Int(screen.width / 4) * Int(screen.height / 4)
        XCTAssertFalse(hits.isEmpty, "the button takes touches")
        XCTAssertLessThan(hits.count, total / 20, "almost every point of the screen falls through to the page (overlay took \(hits.count) of \(total))")
        let minX = hits.map(\.x).min() ?? 0, maxX = hits.map(\.x).max() ?? 0
        let minY = hits.map(\.y).min() ?? 0, maxY = hits.map(\.y).max() ?? 0
        XCTAssertGreaterThanOrEqual(maxY - minY, 40, "the button is about 44 pt tall (sampled every 4 pt): \(minY)...\(maxY)")
        XCTAssertLessThanOrEqual(maxY - minY, 52, "and nothing taller takes touches: \(minY)...\(maxY)")
        XCTAssertLessThanOrEqual(maxX - minX, 250, "and no wider than the callout: \(minX)...\(maxX)")

        // The circle's stroke is not a hit target (the ellipse is about 22 pt wider than the line box on each side).
        let circleLeftEdge = CGPoint(x: box.minX - 22 - 2900, y: box.midY - 2900)
        XCTAssertTrue(controller.view.hitTest(circleLeftEdge, with: nil) is TouchProbeView, "the red circle's stroke lets touches through")
    }

    func testWithNoMarksEverythingFallsThrough() async throws {
        let (controller, window) = await host(MarksOverlay(marks: [], viewport: CanvasViewport()))
        defer { window.isHidden = true }
        XCTAssertTrue(overlayHits(controller, step: 20).isEmpty)
    }
}
