import SwiftUI

/// Export log and Settings (and, on the course picker, the hours left) in the navigation bar. Each screen that wears it presents
/// its own sheets, so the buttons work wherever the student is in the course lists.
private struct AppToolbarModifier: ViewModifier {
    let showsAllowance: Bool
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var account: StudentAccount
    @State private var showSettings = false
    @State private var exportItem: ExportItem?
    @State private var exportMessage: String?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if showsAllowance {
                    ToolbarItem(placement: .topBarLeading) {
                        // One line at its full width: without this the navigation bar squeezes "478 min left" into "4'".
                        AllowanceChip()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        exportLog()
                    } label: {
                        Label("Export log", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("exportLogButton")
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settingsButton")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: env.settings, log: env.log)
                    .environmentObject(account)
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(items: [item.url])
            }
            .alert("Session log", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportMessage ?? "")
            }
    }

    private func exportLog() {
        if let url = env.log.exportURL() {
            env.log.record("log_exported", ["bytes": (try? Data(contentsOf: url).count) ?? -1])
            exportItem = ExportItem(url: url)
        } else {
            env.log.record("error", ["where": "export_log", "detail": "no session files to export"])
            exportMessage = "There is no log to share yet."
        }
    }
}

extension View {
    func appToolbar(showsAllowance: Bool = false) -> some View {
        modifier(AppToolbarModifier(showsAllowance: showsAllowance))
    }
}

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}
