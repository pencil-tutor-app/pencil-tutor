import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: TutorSettings
    let log: SessionLog
    @EnvironmentObject private var account: StudentAccount
    @EnvironmentObject private var memory: MemoryStore
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingCodeChange = false
    @State private var showMemoryConsent = false
    @State private var showMemoryRecord = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Your code", value: account.maskedCode ?? "None")
                        .accessibilityIdentifier("settingsCode")
                    LabeledContent("Time left this month", value: account.allowance?.chipText ?? "Checking...")
                        .accessibilityIdentifier("settingsMinutesLeft")
                    Button("Use a different code") { confirmingCodeChange = true }
                        .accessibilityIdentifier("useDifferentCodeButton")
                } header: {
                    Text("Your tutoring time")
                } footer: {
                    Text("Your hours start fresh on the 1st of every month.")
                }
                if memory.isAvailable {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tutor memory").font(.headline)
                            Text(memory.statusLine)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settingsMemoryStatus")
                        }
                        .padding(.vertical, 2)
                        if memory.isOn || memory.hasRecord {
                            Button { showMemoryRecord = true } label: {
                                Text("What the tutor remembers").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .accessibilityIdentifier("settingsMemoryRecordButton")
                        }
                        if !memory.isOn && memory.canTurnOn {
                            Button { showMemoryConsent = true } label: {
                                Text("Turn on memory").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .accessibilityIdentifier("settingsMemoryTurnOnButton")
                        }
                    } header: {
                        Text("Memory")
                    } footer: {
                        Text("Optional. A parent or guardian decides, or an adult student for themselves. The tutor works the same without it.")
                    }
                }
                Section {
                    SettingsStepper(
                        title: "Pen idle before the tutor looks",
                        value: $settings.idleSeconds,
                        range: 1...10, step: 0.5
                    )
                    SettingsStepper(
                        title: "Quiet time after an interruption",
                        value: $settings.cooldownSeconds,
                        range: 10...180, step: 5
                    )
                } header: {
                    Text("When the tutor looks")
                } footer: {
                    Text("These are starting defaults (\(TutorSettings.startingIdleSeconds, specifier: "%.1f") s and \(Int(TutorSettings.startingCooldownSeconds)) s), not measured values. The session log records every look so they can be tuned from real use.")
                }
                Section {
                    Button("Back to starting defaults") {
                        settings.resetToStartingDefaults()
                        log.record("settings_reset", [:])
                    }
                }
            }
            .navigationTitle("Settings")
            .task { await memory.refresh(reason: "settings") }
            .sheet(isPresented: $showMemoryConsent) { MemoryConsentView(memory: memory) }
            .sheet(isPresented: $showMemoryRecord) { MemoryRecordView(memory: memory, problems: env.problems) }
            .confirmationDialog("Use a different code?", isPresented: $confirmingCodeChange, titleVisibility: .visible) {
                Button("Use a different code", role: .destructive) {
                    account.signOut(reason: "settings_use_different_code")
                    dismiss()
                }
                Button("Keep this code", role: .cancel) {}
            } message: {
                Text("You will need to type a code again to talk to the tutor.")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        log.record("settings_saved", [
                            "idle_seconds": settings.idleSeconds,
                            "cooldown_seconds": settings.cooldownSeconds
                        ])
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SettingsStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value, specifier: "%.1f") s").foregroundStyle(.secondary)
            }
        }
    }
}
