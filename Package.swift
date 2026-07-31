// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentRemoteDevice",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeviceProtocol", targets: ["DeviceProtocol"]),
        .library(name: "DeviceSecurity", targets: ["DeviceSecurity"]),
        .library(name: "GUIExecutor", targets: ["GUIExecutor"]),
        .library(name: "DeviceAppCore", targets: ["DeviceAppCore"]),
        .library(name: "DeviceIPC", targets: ["DeviceIPC"]),
        .library(name: "DeviceServices", targets: ["DeviceServices"]),
        .executable(name: "agent-remote-device-dev", targets: ["AgentRemoteDeviceApp"]),
        .executable(name: "agent-remote-device-network-broker-xpc", targets: ["NetworkBrokerService"]),
        .executable(name: "agent-remote-device-gui-executor-xpc", targets: ["GUIExecutorService"]),
        .executable(name: "agent-remote-device-system-e2e-peer", targets: ["DeviceSystemE2EPeer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.3.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.15.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"),
    ],
    targets: [
        .target(name: "DeviceProtocol", path: "macos/Shared/DeviceProtocol"),
        .target(name: "DeviceSecurity", dependencies: ["DeviceProtocol"], path: "macos/Shared/DeviceSecurity"),
        .target(name: "GUIExecutor", dependencies: ["DeviceProtocol", "DeviceSecurity"], path: "macos/GUIExecutor"),
        .target(
            name: "DeviceIPC",
            dependencies: ["DeviceProtocol", "DeviceSecurity"],
            path: "macos/Shared/DeviceIPC"
        ),
        .target(
            name: "DeviceServices",
            dependencies: [
                "DeviceIPC",
                "DeviceProtocol",
                "DeviceSecurity",
                "GUIExecutor",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "macos/DeviceServices"
        ),
        .target(
            name: "DeviceAppCore",
            dependencies: ["DeviceIPC", "DeviceProtocol", "DeviceSecurity", "GUIExecutor"],
            path: "macos/AppCore"
        ),
        .executableTarget(
            name: "AgentRemoteDeviceApp",
            dependencies: ["DeviceAppCore", "DeviceIPC", "DeviceSecurity"],
            path: "macos/App",
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "NetworkBrokerService",
            dependencies: ["DeviceIPC", "DeviceServices"],
            path: "macos/NetworkBrokerService"
        ),
        .executableTarget(
            name: "GUIExecutorService",
            dependencies: ["DeviceIPC", "DeviceServices", "GUIExecutor"],
            path: "macos/GUIExecutorService"
        ),
        .executableTarget(
            name: "DeviceSystemE2EPeer",
            dependencies: ["DeviceIPC", "DeviceProtocol", "DeviceServices"],
            path: "macos/SystemE2EPeer"
        ),
        .testTarget(name: "DeviceProtocolTests", dependencies: ["DeviceProtocol"], path: "macos/Tests/DeviceProtocolTests", resources: [.copy("Fixtures")]),
        .testTarget(name: "DeviceSecurityTests", dependencies: ["DeviceSecurity", "DeviceProtocol"], path: "macos/Tests/DeviceSecurityTests"),
        .testTarget(
            name: "GUIExecutorTests",
            dependencies: ["DeviceProtocol", "DeviceSecurity", "GUIExecutor"],
            path: "macos/Tests/GUIExecutorTests"
        ),
        .testTarget(
            name: "DeviceAppCoreTests",
            dependencies: ["DeviceAppCore", "DeviceProtocol", "GUIExecutor"],
            path: "macos/Tests/DeviceAppCoreTests"
        ),
        .testTarget(
            name: "DeviceIPCTests",
            dependencies: ["DeviceIPC", "DeviceProtocol", "DeviceSecurity"],
            path: "macos/Tests/DeviceIPCTests"
        ),
        .testTarget(
            name: "DeviceServicesTests",
            dependencies: [
                "DeviceIPC",
                "DeviceProtocol",
                "DeviceSecurity",
                "DeviceServices",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "macos/Tests/DeviceServicesTests"
        ),
    ]
)
