import PencilKit
import SwiftUI

/// The PencilKit page. Pencil-only in normal use; `--any-input` (UI tests) lets a finger draw.
/// Marks from the tutor are NOT drawn here: they live on a separate overlay above this view.
struct InkCanvas: UIViewRepresentable {
    let session: TutorSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = LaunchOptions.anyInput ? .anyInput : .pencilOnly
        canvas.overrideUserInterfaceStyle = .light
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.isScrollEnabled = false
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.accessibilityIdentifier = "drawingCanvas"
        canvas.delegate = context.coordinator

        if !LaunchOptions.anyInput {
            // The system tool picker (pen, eraser, undo). Skipped in UI tests, where it only gets in the way.
            let picker = PKToolPicker()
            picker.addObserver(canvas)
            context.coordinator.toolPicker = picker
            DispatchQueue.main.async {
                picker.setVisible(true, forFirstResponder: canvas)
                canvas.becomeFirstResponder()
            }
        }

        session.attach(canvas: canvas)
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

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
