// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AuralMacApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AuralCore", targets: ["AuralCore"]),
        .executable(name: "aural-prototype", targets: ["AuralPrototype"]),
        .executable(name: "aural-validate", targets: ["AuralValidation"]),
        .executable(name: "aural-test", targets: ["AuralTests"]),
        .executable(name: "aural-e2e", targets: ["AuralEndToEnd"]),
        .executable(name: "aural-ui-prototype", targets: ["AuralUIPrototype"])
    ],
    targets: [
        .target(name: "AuralCore"),
        .executableTarget(
            name: "AuralPrototype",
            dependencies: ["AuralCore"]
        ),
        .executableTarget(
            name: "AuralValidation",
            dependencies: ["AuralCore"]
        ),
        .executableTarget(
            name: "AuralTests",
            dependencies: ["AuralCore"]
        ),
        .executableTarget(
            name: "AuralEndToEnd",
            dependencies: ["AuralCore"]
        ),
        .executableTarget(
            name: "AuralUIPrototype",
            dependencies: ["AuralCore"]
        )
    ]
)
