// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WildcatRadioCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WildcatRadioCore", targets: ["WildcatRadioCore"]),
    ],
    targets: [
        .target(name: "WildcatRadioCore"),
        .testTarget(name: "WildcatRadioCoreTests", dependencies: ["WildcatRadioCore"],
                    resources: [.copy("Fixtures/meshtastic-vectors.json"), .copy("Fixtures/rnode-wisblock.json"),
                                .copy("Fixtures/reticulum-packets.json")]),
    ]
)
