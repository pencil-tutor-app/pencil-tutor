import SwiftUI

/// The problem screen: the page fills the whole screen, edge to edge, and everything else floats over it on see-through
/// material (2026-11-14): the Back button and the problem as a small card top-left (the card folds to a one-line pill), the
/// actions as one slim pill top-right, and the tool rail docked on the left edge under the Back button. There is no navigation
/// bar. Nothing floating is large or opaque, so it never hides ink for long: the card folds away, the caption goes when the
/// student writes, and the rail is a 48 pt strip that stays put (it never opens, closes or moves, so a tool or colour change is
/// one tap).
///
/// Overflow rules for the floating chrome (Apple HIG: hit targets at least 44 x 44 pt with room around them; Vercel Web Interface
/// Guidelines: match visual and hit targets, minimum 44 on touch, no layout shift, loading buttons keep their label, icons have
/// labels, gestures have tap alternatives): every label is one line (`lineLimit(1)` + `fixedSize`), never truncated and never
/// wider than its capsule. When the row runs out of width it tries, in order, a shorter label, the pill under the card, and
/// icon-only buttons (their words stay as the accessibility label). A label's width is held at its longest wording so a tap that
/// swaps "Tap to ask" for "Listening..." moves nothing, and the busy spinner replaces the Check icon instead of adding width.
struct ProblemScreen: View {
    @StateObject private var session: TutorSession
    @StateObject private var rail = ToolRailModel()
    @EnvironmentObject private var account: StudentAccount
    @Environment(\.dismiss) private var dismiss
    /// Shown small at the top of the problem card ("BC Math 5"). Nil shows no heading.
    private let courseTitle: String?

    init(problem: Problem, env: AppEnvironment, courseTitle: String? = nil) {
        self.courseTitle = courseTitle
        _session = StateObject(wrappedValue: TutorSession(problem: problem, env: env))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The page and the tutor's marks cover the whole screen, under the status bar and the home indicator too.
            // Both ignore the safe area, so their frames are identical and a mark stays on its line.
            InkCanvas(session: session, rail: rail)
                .ignoresSafeArea()
            MarksOverlay(marks: session.marks, viewport: session.viewport)
                .ignoresSafeArea()
            chrome
            // The rail keeps to the safe area and sits right under the Back button, left of the problem card.
            ToolRailView(model: rail)
                .padding(.leading, ChromeMetrics.edge)
                .padding(.top, ChromeMetrics.railTop)
                .padding(.bottom, ChromeMetrics.edge)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            // Widest first: full labels in one row, short labels in one row, then the pill under the card (full, short, icons).
            ViewThatFits(in: .horizontal) {
                singleRow(.full)
                singleRow(.short)
                twoRows(.full)
                twoRows(.short)
                twoRows(.icons)
            }
            // The rail owns the strip under the Back button; anything lower in this column keeps clear of it.
            if LaunchOptions.showTestStatus {
                Text(session.testStatus)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.leading, ChromeMetrics.railGutter)
                    .accessibilityIdentifier("testStatus")
            }
            if let block = account.block {
                BlockedBanner(message: block.message)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.leading, ChromeMetrics.railGutter)
            }
            if let message = session.statusMessage {
                HStack {
                    Spacer(minLength: 0)
                    caption(message)
                }
            }
        }
        .padding(.horizontal, ChromeMetrics.edge)
        .padding(.top, ChromeMetrics.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.2), value: session.statusMessage)
    }

    private func singleRow(_ density: PillDensity) -> some View {
        HStack(alignment: .top, spacing: 10) {
            backButton
            problemCard
            Spacer(minLength: 8)
            actionPill(density)
        }
    }

    private func twoRows(_ density: PillDensity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                backButton
                problemCard
                Spacer(minLength: 0)
            }
            actionPill(density).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func caption(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 15))
            .fixedSize(horizontal: false, vertical: true)   // wraps to its words, never cut off
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 340, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
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
                .frame(width: ChromeMetrics.hit, height: ChromeMetrics.hit)
                .background(.thinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to problems")
        .accessibilityIdentifier("backButton")
    }

    private var problemCard: some View {
        ProblemCardView(problem: session.problem, heading: courseTitle) { collapsed in
            session.noteCanvas("problem_card_toggled", ["collapsed": collapsed])
        }
        // How far down the card reaches, so the page starts below it and a mark is never left under it.
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: CardBottomKey.self, value: geometry.frame(in: .global).maxY)
            }
        }
        .onPreferenceChange(CardBottomKey.self) { bottom in
            session.cardMeasured(bottomInWindow: bottom)
        }
    }

    /// Check my work, the tutor's voice, Clear marks, Erase page and the hours left: one slim pill, as tall as the Back button.
    private func actionPill(_ density: PillDensity) -> some View {
        HStack(spacing: 6) {
            Button {
                session.checkMyWork()
            } label: {
                PillLabel(full: "Check my work", short: "Check", symbol: "checkmark.circle", fill: Color.accentColor,
                          busy: session.isBusy)
            }
            .buttonStyle(.plain)
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
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: ChromeMetrics.hit)
        .fixedSize()
        .background(.thinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .environment(\.pillDensity, density)
    }

    /// Icon-only to save width; the words are the accessibility label (and what VoiceOver and the UI tests see). The hit target
    /// is the full 44 x 44 pt; the grey disc inside is smaller so the pill stays calm.
    private func iconButton(_ label: String, symbol: String, id: String, role: ButtonRole? = nil, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            PillIconLabel(symbol: symbol, tint: role == .destructive ? .red : .primary)
        }
        .buttonStyle(.plain)
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
                PillLabel(full: micOn ? "Mic on" : "Muted", short: micOn ? "Mic on" : "Muted", widestFull: "Mic on",
                          symbol: micOn ? "mic.fill" : "mic.slash.fill", fill: micOn ? .green : .gray)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("micToggleButton")
        case .connecting:
            PillLabel(full: "Connecting voice...", short: "Connecting...", symbol: "waveform",
                      fill: Color.gray.opacity(0.25), foreground: .primary)
                .accessibilityIdentifier("voiceConnecting")
        case .idleClosed:
            Button {
                session.micTapped()
            } label: {
                PillLabel(full: "Tap to talk", short: "Talk", symbol: "mic.fill", fill: Color.blue.opacity(0.14), foreground: .blue)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("micReopenButton")
        case .fallback:
            // Only reachable when live voice is in the plan and then dropped.
            tapToAsk
            Button {
                session.micTapped()
            } label: {
                PillLabel(full: "Reconnect voice", short: "Reconnect", symbol: "arrow.clockwise",
                          fill: Color.gray.opacity(0.18), foreground: .primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reconnectVoiceButton")
        case .notStarted:
            tapToAsk
        }
    }

    /// Tap once to start talking, tap again to send. Stops by itself after 30 seconds. Idle is a soft blue tint (the Check
    /// button is the one solid colour); listening is solid red so it cannot be missed.
    private var tapToAsk: some View {
        let listening = session.isRecording
        let off = account.isBlocked
        return Button {
            session.tapToTalkTapped()
        } label: {
            // While listening the words are "Tap to send" (the red capsule and waveform say it is listening; VoiceOver hears
            // "Listening... tap to send"). Both wordings are about as wide, so the pill does not jump when it starts listening.
            PillLabel(full: listening ? "Tap to send" : "Tap to ask", short: listening ? "Send" : "Ask",
                      widestFull: "Tap to send", widestShort: "Send",
                      spoken: listening ? "Listening... tap to send" : "Tap to ask",
                      symbol: listening ? "waveform" : "mic.fill",
                      fill: off ? Color.gray : (listening ? Color.red : Color.blue.opacity(0.14)),
                      foreground: (off || listening) ? .white : .blue)
        }
        .buttonStyle(.plain)
        .disabled(off)
        .accessibilityIdentifier("tapToTalkButton")
    }
}

/// The bottom edge of the problem card (or its folded pill) in window coordinates.
private struct CardBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Sizes shared by the floating chrome

enum ChromeMetrics {
    /// Apple HIG: a tappable control is at least 44 x 44 pt.
    static let hit: CGFloat = 44
    static let edge: CGFloat = 12
    static let top: CGFloat = 6
    static let gap: CGFloat = 8
    /// The rail starts right under the Back button.
    static var railTop: CGFloat { top + hit + gap }
    /// The rail's width plus its margin and a gap: what the rows lower in the chrome column leave free on the left.
    static var railGutter: CGFloat { ToolRailMetrics.width + gap }
}

// MARK: - Action pill labels

/// How much of its words an action-pill button shows: all of them, a shorter wording, or only the icon.
enum PillDensity {
    case full, short, icons
}

private struct PillDensityKey: EnvironmentKey {
    static let defaultValue = PillDensity.full
}

extension EnvironmentValues {
    var pillDensity: PillDensity {
        get { self[PillDensityKey.self] }
        set { self[PillDensityKey.self] = newValue }
    }
}

/// One capsule in the action pill: icon, then one line of words. The 44 pt tall hit area is wider than the capsule you see.
/// The words are always one line and never truncated; the width is held at the longest wording the button can show (`widest...`)
/// so changing the words does not move its neighbours.
private struct PillLabel: View {
    let full: String
    let short: String
    var widestFull: String?
    var widestShort: String?
    /// What VoiceOver says; the visible words when empty.
    var spoken: String?
    let symbol: String
    let fill: Color
    var foreground: Color = .white
    /// A busy button swaps its icon for a spinner and keeps its words, so nothing around it moves.
    var busy = false

    @Environment(\.pillDensity) private var density
    @Environment(\.isEnabled) private var isEnabled

    init(full: String, short: String, widestFull: String? = nil, widestShort: String? = nil, spoken: String? = nil,
         symbol: String, fill: Color,
         foreground: Color = .white, busy: Bool = false) {
        self.full = full
        self.short = short
        self.widestFull = widestFull
        self.widestShort = widestShort
        self.spoken = spoken
        self.symbol = symbol
        self.fill = fill
        self.foreground = foreground
        self.busy = busy
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if busy {
                    ProgressView().controlSize(.small).tint(foreground)
                } else {
                    Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(width: 20, height: 20)
            if density != .icons {
                ZStack {
                    Text(density == .full ? (widestFull ?? full) : (widestShort ?? short)).hidden()
                    Text(density == .full ? full : short)
                }
            }
        }
        .font(.body.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, density == .icons ? 12 : 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(fill))
        .foregroundStyle(foreground)
        .opacity(isEnabled ? 1 : 0.4)
        .frame(minHeight: ChromeMetrics.hit)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? full)
    }
}

/// A round grey icon button (Clear marks, Erase page) inside a 44 x 44 pt hit area.
private struct PillIconLabel: View {
    let symbol: String
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.primary.opacity(0.08)))
            .opacity(isEnabled ? 1 : 0.35)
            .frame(width: ChromeMetrics.hit, height: ChromeMetrics.hit)
            .contentShape(Rectangle())
    }
}

// MARK: - The tool rail (drawn here; the state and logic are `ToolRailModel` in InkCanvas.swift)

enum ToolRailMetrics {
    /// Each control has a 44 x 44 pt hit target; the capsule adds 2 pt on each side.
    static let hit: CGFloat = 44
    static let width: CGFloat = 48
    /// The chosen item's highlight, inside its hit target.
    static let highlight: CGFloat = 40
    static let swatch: CGFloat = 28
}

/// A slim floating capsule docked top-left under the Back button, always on screen. Top to bottom: the four tools, the four
/// colours, the three widths, undo and redo, each group split by a hairline. A tap changes the pen and nothing else moves: the
/// rail never opens, closes or hides. The chosen tool, colour and width have a filled highlight with a ring (not a bigger
/// glyph, so nothing shifts). While the highlighter is on, the swatches show its colours (black shows yellow).
/// If a window is too short for all thirteen controls the rail scrolls rather than clip. This view only draws; every choice
/// goes through the model, which sets the canvas's tool and logs it.
struct ToolRailView: View {
    @ObservedObject var model: ToolRailModel

    var body: some View {
        ViewThatFits(in: .vertical) {
            rail
            ScrollView(.vertical, showsIndicators: false) { rail }
                .frame(width: ToolRailMetrics.width)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drawing tools")
        .accessibilityIdentifier("toolRail")
    }

    private var rail: some View {
        let style = model.style
        return VStack(spacing: 0) {
            ForEach(RailTool.allCases, id: \.self) { tool in
                railButton(id: "toolRail_\(tool.rawValue)", label: tool.label, selected: style.tool == tool) {
                    Image(systemName: tool.symbol).font(.system(size: 22, weight: .medium))
                } action: { model.select(tool) }
            }
            divider
            ForEach(InkColour.allCases, id: \.self) { colour in
                railButton(id: "toolRail_colour_\(colour.rawValue)", label: "\(colour.label) ink",
                           selected: style.colour == colour && style.tool.isInk) {
                    Circle()
                        .fill(Color(uiColor: style.swatchColour(colour)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                        .frame(width: ToolRailMetrics.swatch, height: ToolRailMetrics.swatch)
                } action: { model.choose(colour: colour) }
            }
            divider
            ForEach(Array(InkWidth.allCases.enumerated()), id: \.element) { index, width in
                railButton(id: "toolRail_width_\(width.rawValue)", label: "\(width.label) line",
                           selected: style.width == width && style.tool.isInk) {
                    Capsule().fill(Color.primary)
                        .frame(width: 24, height: [3, 6, 10][index])
                } action: { model.choose(width: width) }
            }
            divider
            railButton(id: "toolRail_undo", label: "Undo", selected: false, disabled: !model.canUndo) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 20, weight: .medium))
            } action: { model.undo() }
            railButton(id: "toolRail_redo", label: "Redo", selected: false, disabled: !model.canRedo) {
                Image(systemName: "arrow.uturn.forward").font(.system(size: 20, weight: .medium))
            } action: { model.redo() }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, (ToolRailMetrics.width - ToolRailMetrics.hit) / 2)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private var divider: some View {
        Capsule()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 24, height: 1)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }

    private func railButton<Icon: View>(id: String, label: String, selected: Bool, disabled: Bool = false,
                                        @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon()
                .foregroundStyle(Color.primary)
                .frame(width: ToolRailMetrics.highlight, height: ToolRailMetrics.highlight)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                .frame(width: ToolRailMetrics.hit, height: ToolRailMetrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
