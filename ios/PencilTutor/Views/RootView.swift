import SwiftUI

/// The code screen until the app has a working code, then the problem list.
struct RootView: View {
    @EnvironmentObject private var account: StudentAccount

    var body: some View {
        switch account.phase {
        case .needsCode:
            CodeEntryView()
        case .ready:
            ProblemListView()
        }
    }
}

/// "N min left" (or "Hours used up"), coloured by how much of the month remains. Hidden until the first number arrives.
struct AllowanceChip: View {
    @EnvironmentObject private var account: StudentAccount

    var body: some View {
        if let allowance = account.allowance {
            Text(allowance.chipText)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(color(for: allowance.state).opacity(0.18)))
                .foregroundStyle(color(for: allowance.state))
                .accessibilityIdentifier("allowanceChip")
        }
    }

    private func color(for state: AllowanceState) -> Color {
        switch state {
        case .ok: return .green
        case .low: return .orange
        case .usedUp: return .gray
        }
    }
}

/// A calm line that says why the tutor has gone quiet. Drawing keeps working.
struct BlockedBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 19, weight: .medium))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 1.0, green: 0.95, blue: 0.85))
            .foregroundStyle(Color(white: 0.2))
            .accessibilityIdentifier("blockedBanner")
    }
}
