import SwiftUI

/// "What the tutor remembers": the state of memory, the practice rows that are stored, and the way to turn it off or erase it.
/// Edward's notes are only counted here; the policy and the consent text say they are released on request.
struct MemoryRecordView: View {
    @ObservedObject var memory: MemoryStore
    let problems: [Problem]
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingTurnOff = false
    @State private var confirmingErase = false
    @State private var showConsent = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(memory.statusLine)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("memoryStatusLine")
                    if let line = memory.agreementLine {
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("memoryAgreementLine")
                    }
                } header: {
                    Text("Memory")
                }

                Section {
                    let notes = memory.status?.record?.notes ?? 0
                    Text(notes == 0 ? "Edward has written no notes." : "Edward has written \(notes) \(notes == 1 ? "note" : "notes") about how you work best. They are not shown here. Ask Edward for a copy.")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("memoryNotesLine")
                    let recent = memory.status?.record?.recent ?? []
                    if recent.isEmpty {
                        Text("No practice has been recorded.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("memoryNoPractice")
                    } else {
                        ForEach(recent) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(problemText(row.problemId))
                                    .font(.system(size: 20, design: .serif))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(detail(row))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("memoryRecent-\(row.problemId)")
                        }
                    }
                } header: {
                    Text("What is stored")
                } footer: {
                    Text("Only counts, dates and line numbers are stored. No name, no picture of your page, no recording, and none of the words you write or say. \"Stepped in\" counts what the tutor's server decided, which can differ a little from what appeared on your page.")
                }

                Section {
                    if memory.isOn {
                        Button { confirmingTurnOff = true } label: {
                            Text("Turn off memory").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("memoryTurnOff")
                    } else if memory.canTurnOn {
                        Button { showConsent = true } label: {
                            Text("Turn on memory").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("memoryTurnOnFromRecord")
                    }
                    Button(role: .destructive) { confirmingErase = true } label: {
                        Text("Erase what the tutor remembers").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .disabled(!hasAnythingStored)
                    .accessibilityIdentifier("memoryErase")
                    if let message = memory.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("memoryMessage")
                    }
                } footer: {
                    Text("You can change your mind at any time. The tutor works the same without memory.")
                }

                Section {
                    if let urlText = memory.status?.notice?.policyUrl, let url = URL(string: urlText) {
                        Link(destination: url) {
                            Label("Read the full privacy policy", systemImage: "doc.text")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("memoryPolicyLink")
                    }
                    Text("To get a copy of everything stored, including Edward's notes, ask Edward.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("What the tutor remembers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // The 44 pt is on the label, inside the button, so the tappable area (and the frame VoiceOver and UI tests read) is 44 pt tall.
                    Button { dismiss() } label: {
                        Text("Done").frame(minWidth: 44, minHeight: 44)
                    }
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("memoryRecordDone")
                }
            }
            .confirmationDialog("Turn off memory?", isPresented: $confirmingTurnOff, titleVisibility: .visible) {
                Button("Turn off and erase everything", role: .destructive) { Task { await memory.turnOff(erase: true) } }
                Button("Turn off, keep what is stored") { Task { await memory.turnOff(erase: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The tutor stops remembering right away and works the same as before. What is already stored stays unless you erase it.")
            }
            .confirmationDialog("Erase what the tutor remembers?", isPresented: $confirmingErase, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { Task { await memory.erase() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the practice record and Edward's notes about you. It cannot be undone.")
            }
            .sheet(isPresented: $showConsent) {
                MemoryConsentView(memory: memory)
            }
            .task { await memory.refresh(reason: "record_screen") }
        }
    }

    private var hasAnythingStored: Bool {
        (memory.status?.record?.notes ?? 0) > 0 || !(memory.status?.record?.recent.isEmpty ?? true)
    }

    private func problemText(_ id: String) -> String {
        problems.first(where: { $0.id == id })?.promptPlain ?? id
    }

    private func detail(_ row: MemoryRecentAttempt) -> String {
        var parts = ["The tutor looked \(row.looks) \(row.looks == 1 ? "time" : "times")"]
        if row.interrupts > 0 { parts.append("stepped in \(row.interrupts) \(row.interrupts == 1 ? "time" : "times")") }
        if row.asks > 0 { parts.append("you asked \(row.asks) \(row.asks == 1 ? "question" : "questions")") }
        return parts.joined(separator: ", ") + ". " + MemoryStore.dayText(row.lastAt)
    }
}
