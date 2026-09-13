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
        .library(name: "WorkshopDaemonKit", targets: ["WorkshopDaemonKit"]),
        .executable(name: "workshop-daemon", targets: ["workshop-daemon"]),
        .executable(name: "workshop-mcp", targets: ["workshop-mcp"]),
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
        .target(name: "WorkshopMCP", dependencies: ["WorkshopCore", "WorkshopService"]),
        .target(name: "WorkshopAdapters",
                dependencies: ["WorkshopCore", "WorkshopService"]),
        .target(
            name: "WorkshopDaemonKit",
            dependencies: ["WorkshopCore", "WorkshopStore", "WorkshopService",
                           "WorkshopIPC", "WorkshopAdapters"]
        ),
        .executableTarget(
            name: "workshop-daemon",
            dependencies: ["WorkshopDaemonKit"]
        ),
        .executableTarget(
            name: "workshop-mcp",
            dependencies: ["WorkshopCore", "WorkshopIPC", "WorkshopMCP"]
        ),
        .executableTarget(
            name: "WorkshopApp",
            dependencies: ["WorkshopCore", "WorkshopIPC"]
        ),
        .testTarget(name: "CoreTests", dependencies: ["WorkshopCore"]),
        .testTarget(name: "StoreTests", dependencies: ["WorkshopStore", "WorkshopCore"]),
        .testTarget(name: "ServiceTests", dependencies: ["WorkshopService", "WorkshopStore", "WorkshopCore"]),
        .testTarget(name: "IPCTests", dependencies: ["WorkshopIPC", "WorkshopService", "WorkshopStore", "WorkshopCore"]),
        .testTarget(name: "MCPTests", dependencies: ["WorkshopMCP", "WorkshopIPC", "WorkshopService", "WorkshopStore", "WorkshopCore"]),
        .testTarget(name: "AdapterContractTests",
                    dependencies: ["WorkshopAdapters", "WorkshopService", "WorkshopCore"]),
        .testTarget(name: "LiveSmokeTests",
                    dependencies: ["WorkshopDaemonKit", "WorkshopAdapters",
                                   "WorkshopService",
                                   "WorkshopStore", "WorkshopCore"]),
    ]
)
