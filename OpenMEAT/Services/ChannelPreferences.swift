import CookCore
import CookSession
import Foundation
import Observation

/// Remembers per-channel role, name and inclusion across cooks (UserDefaults, JSON).
@MainActor @Observable
final class ChannelPreferences {
    private let defaults: UserDefaults
    private static let key = "channelPreferences.v1"
    private(set) var customizations: [ChannelKey: ProbeCustomization]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customizations = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([ChannelKey: ProbeCustomization].self, from: $0) } ?? [:]
    }

    func customization(for key: ChannelKey) -> ProbeCustomization {
        customizations[key] ?? ProbeCustomization()
    }

    func setRole(_ role: ProbeRole, for key: ChannelKey) {
        update(key) { $0.role = role }
    }

    func setLabel(_ label: String, for key: ChannelKey) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        update(key) { $0.label = trimmed.isEmpty ? nil : trimmed }
    }

    func setIncluded(_ included: Bool, for key: ChannelKey) {
        update(key) { $0.isIncluded = included }
    }

    /// `defaultValue` applies when the user hasn't chosen (e.g. offline probes default to off).
    func isIncluded(_ key: ChannelKey, default defaultValue: Bool = true) -> Bool {
        customizations[key]?.isIncluded ?? defaultValue
    }

    func setShowsSensors(_ shows: Bool, for key: ChannelKey) {
        update(key) { $0.showsSensors = shows }
    }

    func reset() {
        customizations = [:]
        defaults.removeObject(forKey: Self.key)
    }

    private func update(_ key: ChannelKey, _ change: (inout ProbeCustomization) -> Void) {
        var value = customization(for: key)
        change(&value)
        customizations[key] = value
        if let data = try? JSONEncoder().encode(customizations) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
