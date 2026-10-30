import Foundation
import ThermoWorksMock

/// Debug/test switches passed as launch arguments, e.g.
/// `-OM_MOCK 1 -OM_SCENARIO brisketStall -OM_TIME_SCALE 600 -OM_POLL 0.5 -OM_RESET 1`.
struct LaunchConfiguration: Equatable {
    /// Use the simulator instead of ThermoWorks Cloud and skip sign-in.
    var useMock = false
    var scenario: MockScenario = .gatewayAmbient
    /// Simulated seconds per real second.
    var timeScale: Double = 1
    /// Real seconds between polls (overrides settings).
    var pollInterval: Double?
    /// Wipe stored cooks, settings and credentials on launch (UI tests).
    var reset = false
    /// Disable animations (UI tests).
    var disableAnimations = false
    /// In mock mode, start a cook with every discovered probe right away.
    var autoStart = false

    init() {}

    init(arguments: [String]) {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let arg = arguments[index]
            if arg.hasPrefix("-OM_") {
                let next = arguments.index(after: index)
                if next < arguments.endIndex, !arguments[next].hasPrefix("-OM_") {
                    values[String(arg.dropFirst())] = arguments[next]
                    index = next
                } else {
                    values[String(arg.dropFirst())] = "1"
                }
            }
            index = arguments.index(after: index)
        }
        useMock = values["OM_MOCK"].map(Self.bool) ?? false
        scenario = values["OM_SCENARIO"].flatMap(MockScenario.init(rawValue:)) ?? .gatewayAmbient
        timeScale = values["OM_TIME_SCALE"].flatMap(Double.init).map { max($0, 1) } ?? 1
        pollInterval = values["OM_POLL"].flatMap(Double.init).map { max($0, 0.1) }
        reset = values["OM_RESET"].map(Self.bool) ?? false
        disableAnimations = values["OM_NO_ANIMATIONS"].map(Self.bool) ?? false
        autoStart = values["OM_AUTOSTART"].map(Self.bool) ?? false
    }

    static let current = LaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)

    private static func bool(_ s: String) -> Bool { ["1", "true", "yes", "YES"].contains(s) }
}
