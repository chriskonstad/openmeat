# OpenMEAT

An open-source iOS app for **cooking** with ThermoWorks RFX probes: fast target setup,
real-time multi-probe graphs (including ambient), estimated time to target, notes, cook history,
Live Activities, and "almost done" alerts. Uses your ThermoWorks Cloud account. Probe setup and
configuration stay in the official ThermoWorks app.

> Unofficial — not affiliated with or endorsed by ThermoWorks.

See **[docs/SPEC.md](docs/SPEC.md)** for the product and technical spec.

## Getting started

Requirements: Xcode 26+, iOS 18+ deployment target, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make generate          # project.yml → OpenMEAT.xcodeproj
open OpenMEAT.xcodeproj
```

- **OpenMEAT** scheme: the real app (sign in with ThermoWorks, or tap *Try demo mode*).
- **OpenMEAT Demo** scheme: launches straight into a running simulated cook at 60× speed (brisket with a stall, 203°F target).

To run on a device, set your team in Signing & Capabilities (don't commit it).

## Layout

| Path | What |
| --- | --- |
| `Packages/OpenMEATKit` | All non-UI code, testable on macOS: `ThermoWorksCloud` (API client), `CookCore` (domain, estimator, persistence), `CookSession` (live polling engine), `ThermoWorksMock` (simulator, mock service, HTTP stubs + fixtures) |
| `OpenMEAT/` | SwiftUI app: auth, live cook, interactive chart, notes, history, settings, notifications, Live Activity controller |
| `OpenMEATWidgets/` | Live Activity / Dynamic Island UI |
| `Shared/` | Code compiled into several targets (activity attributes, accessibility IDs) |
| `OpenMEATTests/`, `OpenMEATUITests/` | App unit tests (Swift Testing) and UI tests (XCUITest, demo mode) |

## Tests

```bash
make test-package      # package unit + hermetic integration tests (macOS, seconds)
make test-app          # app unit + UI tests on the simulator
make test              # everything
make test-live         # optional read-only smoke test against the real cloud
                       #   THERMOWORKS_EMAIL=… THERMOWORKS_PASSWORD=… make test-live
```

Override the simulator with `make test-app SIM="iPhone 17" OS=26.4`.

Demo/test launch arguments: `-OM_MOCK 1 -OM_SCENARIO brisketStall|chickenFast|twoProbesSteak|probeDisconnects|noAmbient -OM_TIME_SCALE 600 -OM_POLL 0.5 -OM_RESET 1 -OM_AUTOSTART 1`.
