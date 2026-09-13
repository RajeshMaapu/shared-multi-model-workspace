// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Workshop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkshopCore", targets: ["WorkshopCore"]),
        .library(name: "WorkshopStore", targets: ["WorkshopStore"]),
        .library(name: "WorkshopService", targets: ["WorkshopService"]),
        .library(name: "WorkshopIPC", targets: ["WorkshopIPC"]),
        .executable(name: "workshop-daemon", targets: ["workshop-daemon"]),
        .executable(name: "Workshop", targets: ["WorkshopApp"]),
    ],
    targets: [
        .target(name: "WorkshopCore"),
        .target(
            name: "WorkshopStore",
            dependencies: ["WorkshopCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "WorkshopService", dependencies: ["WorkshopCore", "WorkshopStore"]),
        .target(name: "WorkshopIPC", dependencies: ["WorkshopCore"]),
        .executableTarget(
            name: "workshop-daemon",
            dependencies: ["WorkshopCore", "WorkshopStore", "WorkshopService", "WorkshopIPC"]
        ),
        .executableTarget(
            name: "WorkshopApp",
            dependencies: ["WorkshopCore", "WorkshopIPC"]
        ),
        .testTarget(name: "CoreTests", dependencies: ["WorkshopCore"]),
        .testTarget(name: "StoreTests", dependencies: ["WorkshopStore", "WorkshopCore"]),
        .testTarget(name: "ServiceTests", dependencies: ["WorkshopService", "WorkshopStore", "WorkshopCore"]),
        .testTarget(name: "IPCTests", dependencies: ["WorkshopIPC", "WorkshopService", "WorkshopStore", "WorkshopCore"]),
        .testTarget(name: "LiveSmokeTests", dependencies: ["WorkshopCore"]),
    ]
)
