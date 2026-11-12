import Foundation
import Combine

/// Timing settings for when the tutor looks at the page.
///
/// Both numbers are STARTING DEFAULTS, not measured values (plan amendment 8). The session log
/// records every look so the first real sessions can show whether they need to change.
final class TutorSettings: ObservableObject {
    /// Seconds the pen must be idle before the tutor looks. Starting default: 2.5.
    static let startingIdleSeconds: Double = 2.5
    /// Seconds the tutor stays quiet after an interruption. Starting default: 45.
    static let startingCooldownSeconds: Double = 45

    private enum Keys {
        static let idle = "settings.idleSeconds"
        static let cooldown = "settings.cooldownSeconds"
    }

    private let defaults: UserDefaults

    @Published var idleSeconds: Double {
        didSet { defaults.set(idleSeconds, forKey: Keys.idle) }
    }

    @Published var cooldownSeconds: Double {
        didSet { defaults.set(cooldownSeconds, forKey: Keys.cooldown) }
    }

    init(defaults: UserDefaults = .standard, useStartingDefaultsOnly: Bool = false) {
        self.defaults = defaults
        if useStartingDefaultsOnly {
            self.idleSeconds = Self.startingIdleSeconds
            self.cooldownSeconds = Self.startingCooldownSeconds
        } else {
            self.idleSeconds = (defaults.object(forKey: Keys.idle) as? Double) ?? Self.startingIdleSeconds
            self.cooldownSeconds = (defaults.object(forKey: Keys.cooldown) as? Double) ?? Self.startingCooldownSeconds
        }
    }

    func resetToStartingDefaults() {
        idleSeconds = Self.startingIdleSeconds
        cooldownSeconds = Self.startingCooldownSeconds
    }

    var policy: LookPolicy {
        LookPolicy(idleSeconds: idleSeconds, cooldownSeconds: cooldownSeconds)
    }
}
