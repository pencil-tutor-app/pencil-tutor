import SwiftUI

/// Shown until the app has a working code. The student types the 8-character code once, or taps "Start free" and the server makes
/// one; either way it is kept in the Keychain. Everything on this screen is plain words: a wrong code never shows a technical message.
struct CodeEntryView: View {
    @EnvironmentObject private var account: StudentAccount
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var normalized: String { StudentCode.normalize(typed) }
    private var canContinue: Bool { normalized.count == StudentCode.length && !account.isChecking }

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Text("Enter your code")
                .font(.system(size: 42, weight: .bold, design: .rounded))
            Text("Type the 8 letters and numbers you were given.")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField("ABCD-EFGH", text: $typed)
                .font(.system(size: 46, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.go)
                .focused($fieldFocused)
                .padding(.vertical, 18)
                .padding(.horizontal, 24)
                .frame(maxWidth: 560)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.95)))
                .onChange(of: typed) { _, new in
                    // Shows XXXX-XXXX as the student types and never lets the field grow past a full code.
                    let shown = StudentCode.display(String(StudentCode.normalize(new).prefix(StudentCode.length)))
                    if shown != new { typed = shown }
                }
                .onSubmit { submit() }
                .accessibilityIdentifier("codeField")

            if let message = account.codeMessage {
                Text(message)
                    .font(.title3)
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .accessibilityIdentifier("codeMessage")
            }

            Button {
                submit()
            } label: {
                Group {
                    if account.isChecking {
                        ProgressView()
                    } else {
                        Text("Continue")
                    }
                }
                .font(.title2.weight(.semibold))
                .frame(minWidth: 220, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinue)
            .accessibilityIdentifier("codeContinueButton")

            // "Start free": the server makes a code and the student is signed in, with nothing to type. Hidden in a build with no server.
            if account.canStartFree {
                Text("or")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await account.startFree() }
                } label: {
                    Text("Start free")
                        .font(.title2.weight(.semibold))
                        .frame(minWidth: 220, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(account.isChecking)
                .accessibilityIdentifier("startFreeButton")
                Text("8 hours of tutoring a month. No sign-up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard canContinue else { return }
        let value = typed
        Task { await account.signIn(typed: value) }
    }
}
