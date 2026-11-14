import SwiftUI

/// The problem screen: the page fills the whole screen, edge to edge, and everything else floats over it on see-through
/// material (2026-11-14): the problem as a small card top-left that folds to a one-line pill, the actions as one slim pill
/// top-right, the tool wheel's handle in a bottom corner. There is no navigation bar; the Back button is part of the floating
/// chrome. Nothing floating is large or opaque, so it never hides ink for long: the card folds away, the wheel closes when the
/// student writes, the caption goes when they write.
struct ProblemScreen: View {
    @StateObject private var session: TutorSession
    @StateObject private var wheel = ToolWheelModel()
    @EnvironmentObject private var account: StudentAccount
    @Environment(\.dismiss) private var dismiss

    init(problem: Problem, env: AppEnvironment) {
        _session = StateObject(wrappedValue: TutorSession(problem: problem, env: env))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The page and the tutor's marks cover the whole screen, under the status bar and the home indicator too.
            // Both ignore the safe area, so their frames are identical and a mark stays on its line.
            InkCanvas(session: session, wheel: wheel)
                .ignoresSafeArea()
            MarksOverlay(marks: session.marks, viewport: session.viewport)
                .ignoresSafeArea()
            chrome
            // The wheel keeps to the safe area, so its handle never sits under the home indicator.
            ToolWheelView(model: wheel)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear { session.begin() }
        .onDisappear { session.stop() }
    }

    // MARK: - Floating chrome

    /// Top of the screen: back and problem on the left, actions on the right. The caption (a quiet backup for the voice) sits
    /// under that row on the right, so it never covers the action pill; it goes away on tap or when the student writes.
    private var chrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    backButton
                    problemCard
                    Spacer(minLength: 8)
                    actionPill
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        backButton
                        problemCard
                        Spacer(minLength: 0)
                    }
                    actionPill.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if LaunchOptions.showTestStatus {
                Text(session.testStatus)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityIdentifier("testStatus")
            }
            if let block = account.block {
                BlockedBanner(message: block.message)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let message = session.statusMessage {
                HStack {
                    Spacer(minLength: 0)
                    caption(message)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.2), value: session.statusMessage)
    }

    private func caption(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 15))
            .lineLimit(4)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 340, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.primary)
            .transition(.opacity)
            .onTapGesture { session.dismissStatus() }
            .accessibilityIdentifier("statusBanner")
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to problems")
        .accessibilityIdentifier("backButton")
    }

    private var problemCard: some View {
        ProblemCardView(problem: session.problem) { collapsed in
            session.noteCanvas("problem_card_toggled", ["collapsed": collapsed])
        }
    }

    /// Check my work, the tutor's voice, Clear marks, Erase page, the hours left and the busy spinner: one slim pill.
    private var actionPill: some View {
        HStack(spacing: 8) {
            Button {
                session.checkMyWork()
            } label: {
                Label("Check my work", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isBusy || account.isBlocked)
            .accessibilityIdentifier("checkMyWorkButton")

            voiceControl

            iconButton("Clear marks", symbol: "xmark.circle", id: "clearMarksButton", disabled: session.marks.isEmpty) {
                session.clearMarks()
            }
            iconButton("Erase page", symbol: "trash", id: "erasePageButton", role: .destructive) {
                session.erasePage()
            }

            AllowanceChip()
            if session.isBusy {
                ProgressView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    /// Icon-only to save width; the words are the accessibility label (and what VoiceOver and the UI tests see).
    private func iconButton(_ label: String, symbol: String, id: String, role: ButtonRole? = nil, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: - Voice

    /// The tutor's voice control. The base plan is tap to ask: tap once to talk, tap again to send. Live voice (only when the
    /// student's plan includes it) has a mute toggle instead. Nothing here once the hours are used up or the code is off.
    @ViewBuilder
    private var voiceControl: some View {
        if account.isBlocked {
            tapToAsk
        } else {
            voiceControlForPlan
        }
    }

    @ViewBuilder
    private var voiceControlForPlan: some View {
        switch session.voice {
        case .live(let micOn):
            Button {
                session.micTapped()
            } label: {
                Label(micOn ? "Mic on" : "Muted", systemImage: micOn ? "mic.fill" : "mic.slash.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(micOn ? Color.green : Color.gray))
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("micToggleButton")
        case .connecting:
            Label("Connecting voice...", systemImage: "waveform")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.gray.opacity(0.25)))
                .accessibilityIdentifier("voiceConnecting")
        case .idleClosed:
            Button {
                session.micTapped()
            } label: {
                Label("Tap to talk", systemImage: "mic.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.blue))
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("micReopenButton")
        case .fallback:
            // Only reachable when live voice is in the plan and then dropped.
            tapToAsk
            Button {
                session.micTapped()
            } label: {
                Label("Reconnect voice", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("reconnectVoiceButton")
        case .notStarted:
            tapToAsk
        }
    }

    /// Tap once to start talking, tap again to send. Stops by itself after 30 seconds.
    private var tapToAsk: some View {
        let listening = session.isRecording
        let off = account.isBlocked
        return Button {
            session.tapToTalkTapped()
        } label: {
            Label(listening ? "Listening... tap to send" : "Tap to ask", systemImage: listening ? "waveform" : "mic.fill")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(off ? Color.gray : (listening ? Color.red : Color.blue)))
                .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
        .disabled(off)
        .accessibilityIdentifier("tapToTalkButton")
    }
}

// MARK: - The tool wheel (drawn here; the state and logic are `ToolWheelModel` in InkCanvas.swift)

/// A small round handle floating over the page. Tap it and a ring opens around it: the tools and undo/redo on an inner ring,
/// the colours and widths on an outer one. A tool tap selects and closes; a colour or width tap keeps it open for the next
/// choice; writing, scrolling or tapping the handle closes it. Drag the handle and it snaps to the nearest edge.
/// This view only draws; every choice goes through the model, which sets the canvas's tool and logs it.
struct ToolWheelView: View {
    @ObservedObject var model: ToolWheelModel
    /// Where the finger has dragged the handle's centre to, while it is being dragged.
    @State private var dragCenter: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let resting = ToolWheelGeometry.handleCenter(fraction: model.handleFraction, in: size)
            let hub = model.isOpen ? ToolWheelGeometry.openCenter(handleCenter: resting, in: size) : (dragCenter ?? resting)
            ZStack {
                if model.isOpen {
                    ring(around: hub)
                }
                handle
                    .position(hub)
                    .gesture(dragGesture(in: size))
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "toolWheelArea")
            .animation(.spring(duration: 0.3), value: model.isOpen)
        }
    }

    // MARK: Handle

    private var handle: some View {
        let style = model.style
        return ZStack {
            Circle().fill(.regularMaterial)
            Circle().strokeBorder(style.tool.isInk ? Color(uiColor: style.colour.highlighterColor) : Color.gray.opacity(0.5),
                                  lineWidth: 3)
            Image(systemName: model.isOpen ? "xmark" : style.tool.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(style.tool.isInk ? Color(uiColor: style.colour.uiColor) : Color.primary)
        }
        .frame(width: ToolWheelGeometry.handleDiameter, height: ToolWheelGeometry.handleDiameter)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .contentShape(Circle())
        .onTapGesture { model.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tool wheel, \(style.summary)")
        .accessibilityValue(model.isOpen ? "open" : "closed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.toggle() }
        .accessibilityIdentifier("toolWheelHandle")
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("toolWheelArea"))
            .onChanged { value in
                guard !model.isOpen else { return }
                let area = ToolWheelGeometry.travel(in: size)
                dragCenter = CGPoint(x: min(max(value.location.x, area.minX), area.maxX),
                                     y: min(max(value.location.y, area.minY), area.maxY))
            }
            .onEnded { value in
                guard !model.isOpen else { return }
                let area = ToolWheelGeometry.travel(in: size)
                let dropped = CGPoint(x: min(max(value.location.x, area.minX), area.maxX),
                                      y: min(max(value.location.y, area.minY), area.maxY))
                model.dropHandle(at: dropped, in: size)
                withAnimation(.spring(duration: 0.25)) { dragCenter = nil }
            }
    }

    // MARK: Ring

    private func ring(around hub: CGPoint) -> some View {
        let tools = WheelTool.allCases
        let innerCount = tools.count + 2
        let inner = ToolWheelGeometry.ringOffsets(count: innerCount, radius: ToolWheelGeometry.innerRadius)
        let outerCount = InkColour.allCases.count + InkWidth.allCases.count
        let outer = ToolWheelGeometry.ringOffsets(count: outerCount, radius: ToolWheelGeometry.outerRadius)
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(Color.gray.opacity(0.25), lineWidth: 1))
                .frame(width: ToolWheelGeometry.discRadius * 2, height: ToolWheelGeometry.discRadius * 2)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                .position(hub)

            ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                item(at: hub, offset: inner[index]) {
                    wheelButton(id: "toolWheel_\(tool.rawValue)", label: tool.label, size: ToolWheelGeometry.innerItemSize,
                                selected: model.style.tool == tool, disabled: false) {
                        Image(systemName: tool.symbol).font(.system(size: 20, weight: .medium))
                    } action: { model.select(tool) }
                }
            }
            item(at: hub, offset: inner[tools.count]) {
                wheelButton(id: "toolWheel_undo", label: "Undo", size: ToolWheelGeometry.innerItemSize,
                            selected: false, disabled: !model.canUndo) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 18, weight: .medium))
                } action: { model.undo() }
            }
            item(at: hub, offset: inner[tools.count + 1]) {
                wheelButton(id: "toolWheel_redo", label: "Redo", size: ToolWheelGeometry.innerItemSize,
                            selected: false, disabled: !model.canRedo) {
                    Image(systemName: "arrow.uturn.forward").font(.system(size: 18, weight: .medium))
                } action: { model.redo() }
            }

            ForEach(Array(InkColour.allCases.enumerated()), id: \.element) { index, colour in
                item(at: hub, offset: outer[index]) {
                    wheelButton(id: "toolWheel_colour_\(colour.rawValue)", label: "\(colour.label) ink",
                                size: ToolWheelGeometry.outerItemSize,
                                selected: model.style.colour == colour && model.style.tool.isInk, disabled: false) {
                        Circle().fill(Color(uiColor: model.style.tool == .marker ? colour.highlighterColor : colour.uiColor))
                            .frame(width: 24, height: 24)
                    } action: { model.choose(colour: colour) }
                }
            }
            ForEach(Array(InkWidth.allCases.enumerated()), id: \.element) { index, width in
                item(at: hub, offset: outer[InkColour.allCases.count + index]) {
                    wheelButton(id: "toolWheel_width_\(width.rawValue)", label: "\(width.label) line",
                                size: ToolWheelGeometry.outerItemSize,
                                selected: model.style.width == width && model.style.tool.isInk, disabled: false) {
                        Capsule().fill(Color.primary)
                            .frame(width: 22, height: [3, 6, 10][InkWidth.allCases.firstIndex(of: width) ?? 1])
                    } action: { model.choose(width: width) }
                }
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private func item<Content: View>(at hub: CGPoint, offset: CGPoint, @ViewBuilder content: () -> Content) -> some View {
        content().position(x: hub.x + offset.x, y: hub.y + offset.y)
    }

    private func wheelButton<Icon: View>(id: String, label: String, size: CGFloat, selected: Bool, disabled: Bool,
                                         @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon()
                .frame(width: size, height: size)
                .background(Circle().fill(selected ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.7)))
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: selected ? 2.5 : 1))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
