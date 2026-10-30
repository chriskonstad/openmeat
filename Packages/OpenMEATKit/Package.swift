// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenMEATKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ThermoWorksCloud", targets: ["ThermoWorksCloud"]),
        .library(name: "CookCore", targets: ["CookCore"]),
        .library(name: "CookSession", targets: ["CookSession"]),
        .library(name: "ThermoWorksMock", targets: ["ThermoWorksMock"]),
    ],
    targets: [
        // ThermoWorks Cloud (Firebase Auth + Firestore REST) client. Clean-room; see docs/SPEC.md §3.
        .target(name: "ThermoWorksCloud"),
        // Pure domain logic: cooks, samples, estimators, downsampling, persistence, alert planning.
        .target(name: "CookCore"),
        // Live cook orchestration: polling, ingest, estimates, snapshots.
        .target(name: "CookSession", dependencies: ["ThermoWorksCloud", "CookCore"]),
        // Simulator + mock service + HTTP stubs. Used by tests, UI tests and demo mode.
        .target(
            name: "ThermoWorksMock",
            dependencies: ["ThermoWorksCloud", "CookCore"],
            resources: [.copy("Fixtures")]
        ),

        .testTarget(name: "ThermoWorksCloudTests", dependencies: ["ThermoWorksCloud", "ThermoWorksMock"]),
        .testTarget(name: "CookCoreTests", dependencies: ["CookCore"]),
        .testTarget(name: "CookSessionTests", dependencies: ["CookSession", "ThermoWorksMock"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["ThermoWorksCloud", "CookCore", "CookSession", "ThermoWorksMock"]
        ),
    ]
)
