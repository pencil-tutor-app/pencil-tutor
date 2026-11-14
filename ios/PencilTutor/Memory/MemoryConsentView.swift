import SwiftUI

/// The consent screen: short, plain, text from the server, a link to the full policy, who is agreeing, and two equal buttons.
/// Nothing here nudges. "Not now" is as easy to reach as "Turn on memory", and leaving the screen any other way is the same as "Not now".
struct MemoryConsentView: View {
    @ObservedObject var memory: MemoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var who: MemoryAttestation?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let notice = memory.status?.notice {
                        Text(notice.title)
                            .font(.largeTitle.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(notice.intro)
                            .font(.title3)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(notice.sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.heading)
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                Text(section.body)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let url = URL(string: notice.policyUrl) {
                            Link(destination: url) {
                                Label("Read the full privacy policy", systemImage: "doc.text")
                                    .frame(minHeight: 44, alignment: .leading)
                            }
                            .accessibilityIdentifier("memoryPolicyLink")
                        }
                        Divider()
                        attestation
                        if let message = memory.message {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("memoryMessage")
                        }
                        buttons
                    } else {
                        Text("The tutor's memory is not available right now.")
                            .font(.title3)
                            .accessibilityIdentifier("memoryUnavailable")
                        Button("Close") { dismiss() }
                            .frame(minHeight: 44)
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("memoryConsentView")
        }
    }

    private var attestation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who is agreeing?")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(MemoryAttestation.allCases) { option in
                Button {
                    who = option
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: who == option ? "largecircle.fill.circle" : "circle")
                            .font(.title3)
                            .foregroundStyle(who == option ? Color.accentColor : Color.secondary)
                        Text(option.label)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(who == option ? .isSelected : [])
                .accessibilityIdentifier(option == .parentGuardian ? "memoryAttestParent" : "memoryAttestAdult")
            }
            Text("No name is asked for or stored. Memory stays off until you choose one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                turnOnButton
                notNowButton
            }
            VStack(spacing: 14) {
                turnOnButton
                notNowButton
            }
        }
    }

    private var turnOnButton: some View {
        Button {
            guard let who else { return }
            Task {
                if await memory.turnOn(as: who) { dismiss() }
            }
        } label: {
            Text("Turn on memory").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(who == nil || memory.busy)
        .accessibilityIdentifier("memoryTurnOn")
    }

    private var notNowButton: some View {
        Button {
            dismiss()
        } label: {
            Text("Not now").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(memory.busy)
        .accessibilityIdentifier("memoryNotNow")
    }
}
