// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nerve",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "Nerve", targets: ["Nerve"]),
        .library(name: "NerveDynamic", type: .dynamic, targets: ["Nerve"]),
    ],
    targets: [
        .target(
            name: "NerveObjC",
            path: "Sources/NerveObjC",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "Nerve",
            dependencies: ["NerveObjC"],
            path: "Sources/Nerve"
        ),
        .testTarget(
            name: "NerveTests",
            dependencies: ["Nerve", "NerveObjC"],
            path: "Tests/NerveTests"
        ),
    ]
)
