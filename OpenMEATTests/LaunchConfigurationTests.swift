import Testing
@testable import OpenMEAT

@Suite("Launch configuration")
struct LaunchConfigurationTests {
    @Test func defaults() {
        let config = LaunchConfiguration(arguments: ["OpenMEAT"])
        #expect(config == LaunchConfiguration())
        #expect(!config.useMock)
        #expect(config.timeScale == 1)
    }

    @Test func parsesMockArguments() {
        let config = LaunchConfiguration(arguments: [
            "OpenMEAT", "-OM_MOCK", "1", "-OM_SCENARIO", "chickenFast", "-OM_TIME_SCALE", "600",
            "-OM_POLL", "0.5", "-OM_RESET", "-OM_NO_ANIMATIONS", "true", "-OM_AUTOSTART",
        ])
        #expect(config.useMock)
        #expect(config.scenario == .chickenFast)
        #expect(config.timeScale == 600)
        #expect(config.pollInterval == 0.5)
        #expect(config.reset) // flag without value
        #expect(config.disableAnimations)
        #expect(config.autoStart)
    }

    @Test func rejectsBadValues() {
        let config = LaunchConfiguration(arguments: ["-OM_SCENARIO", "nope", "-OM_TIME_SCALE", "0", "-OM_POLL", "x"])
        #expect(config.scenario == .brisketStall)
        #expect(config.timeScale == 1)
        #expect(config.pollInterval == nil)
    }
}
