import SwiftUI

struct ProblemListView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showSettings = false
    @State private var exportItem: ExportItem?
    @State private var exportMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let notice = env.notice {
                    Text(notice)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("problemListNotice")
                }
                ForEach(env.problems) { problem in
                    NavigationLink(value: problem) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(problem.promptPlain)
                                .font(.system(size: 22, design: .serif))
                            Text(problem.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .accessibilityIdentifier("problem-\(problem.id)")
                }
            }
            .navigationTitle("Pick a problem")
            .navigationDestination(for: Problem.self) { problem in
                ProblemScreen(problem: problem, env: env)
            }
            .toolbar {
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

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}
