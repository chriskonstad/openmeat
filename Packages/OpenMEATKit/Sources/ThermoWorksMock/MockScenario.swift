import CookCore
import Foundation

/// Named simulator setups. Selected in demo mode / UI tests via `-OM_SCENARIO <rawValue>`.
public enum MockScenario: String, CaseIterable, Sendable {
    /// Like a real RFX setup: a gateway with a wired ambient sensor plus two wireless meat probes
    /// (brisket with a stall, ribs with a low battery). Default for demo mode.
    case gatewayAmbient
    /// One RFX probe in a ~12 h brisket with a pronounced stall at ~150–160 °F, 250 °F pit.
    case brisketStall
    /// One RFX probe in a fast hot chicken cook (~1 h), 375 °F.
    case chickenFast
    /// Two RFX probes (two steaks) reverse-searing at 225 °F with lid openings.
    case twoProbesSteak
    /// Like brisketStall but the probe stops reporting after 2 h.
    case probeDisconnects
    /// A probe without an ambient channel (forces the linear estimator).
    case noAmbient

    public var simulator: CookSimulator {
        let f = { (fahrenheit: Double) in Temperature(fahrenheit: fahrenheit).celsius }
        switch self {
        case .gatewayAmbient:
            // Mirrors a real RFX setup: the gateway's wired Pro-Series port used as the pit sensor, and
            // RFX MEAT probes reporting a computed core (channel 0 = coldest sensor) plus four sensors.
            let pit = CookSimulator.AmbientProfile.ramp(start: f(70), celsius: f(250), rampSeconds: 1800)
            func rfxMeat(start: Double, k: Double, stall: CookSimulator.Stall? = nil) -> [CookSimulator.Channel] {
                // Sensor 4 sits deepest and heats slowest, like the capture from a real probe.
                [.init(number: "0", role: .internal, isComputedCore: true)]
                    + [1.6, 1.35, 1.15, 1.0].enumerated().map { index, factor in
                        .init(number: "\(index + 1)", role: .sensor, startCelsius: f(start) + Double(3 - index) * 0.6,
                              k: k * factor, stall: stall)
                    }
            }
            return CookSimulator(probes: [
                .init(serial: "RFX-GATEWAY", label: "RFX GATEWAY", ambient: pit,
                      channels: [.init(number: "1", role: .ambient)],
                      isGateway: true, battery: 64, batteryDrainPerHour: 2),
                .init(serial: "RFX-BRISKET", label: "Brisket", ambient: pit,
                      channels: rfxMeat(start: 38, k: 0.00009, stall: .init(bandCelsius: f(150)...f(165), factor: 0.1)),
                      battery: 92, batteryDrainPerHour: 1.5),
                .init(serial: "RFX-RIBS", label: "Ribs", ambient: pit,
                      channels: rfxMeat(start: 40, k: 0.00012),
                      battery: 14, batteryDrainPerHour: 1.5),
            ])
        case .brisketStall:
            return CookSimulator(probes: [
                .init(serial: "RFX-BRISKET", label: "Brisket",
                      ambient: .ramp(start: f(70), celsius: f(250), rampSeconds: 1800),
                      channels: [
                        .init(number: "1", role: .internal, label: "Tip", startCelsius: f(38), k: 0.00009,
                              stall: .init(bandCelsius: f(150)...f(165), factor: 0.1)),
                        .init(number: "2", role: .ambient, label: "Ambient"),
                      ]),
            ])
        case .chickenFast:
            return CookSimulator(probes: [
                .init(serial: "RFX-CHICKEN", label: "Chicken",
                      ambient: .steady(celsius: f(375)),
                      channels: [
                        .init(number: "1", role: .internal, label: "Tip", startCelsius: f(40), k: 0.00011),
                        .init(number: "2", role: .ambient, label: "Ambient"),
                      ]),
            ])
        case .twoProbesSteak:
            return CookSimulator(probes: [
                .init(serial: "RFX-RIBEYE", label: "Ribeye",
                      ambient: .lidOpenings(celsius: f(225), interval: 1200, dipCelsius: 25),
                      channels: [
                        .init(number: "1", role: .internal, label: "Tip", startCelsius: f(40), k: 0.00022),
                        .init(number: "2", role: .ambient, label: "Ambient"),
                      ]),
                .init(serial: "RFX-STRIP", label: "Strip",
                      ambient: .lidOpenings(celsius: f(225), interval: 1200, dipCelsius: 25),
                      channels: [
                        .init(number: "1", role: .internal, label: "Tip", startCelsius: f(42), k: 0.00026),
                        .init(number: "2", role: .ambient, label: "Ambient"),
                      ]),
            ])
        case .probeDisconnects:
            var sim = MockScenario.brisketStall.simulator
            for i in sim.probes[0].channels.indices { sim.probes[0].channels[i].dropsOutAfter = 2 * 3600 }
            return sim
        case .noAmbient:
            return CookSimulator(probes: [
                .init(serial: "RFX-ROAST", label: "Roast",
                      ambient: .steady(celsius: f(300)),
                      channels: [.init(number: "1", role: .internal, label: "Tip", startCelsius: f(40), k: 0.00012)]),
            ])
        }
    }
}
