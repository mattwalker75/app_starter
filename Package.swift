// swift-tools-version:5.10
// App Starter — start and stop "application bundles" (your self-hosted apps) in order, with one click.
// `swift build` builds the core and the app; BUILD_APP.sh wraps the app into "App Starter.app".
import PackageDescription

let package = Package(
    name: "AppStarter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppStarterCore", targets: ["AppStarterCore"]),
        .executable(name: "AppStarter", targets: ["AppStarter"]),
    ],
    targets: [
        // Bundles, the commands, health checks and the start/stop engine. No UI — testable on its own.
        .target(name: "AppStarterCore", path: "Sources/AppStarterCore"),
        // The SwiftUI app (the window, the menu bar item, Settings). Thin: it drives the core and shows what it reports.
        .executableTarget(name: "AppStarter", dependencies: ["AppStarterCore"], path: "Sources/AppStarter"),
        .testTarget(name: "AppStarterCoreTests", dependencies: ["AppStarterCore"], path: "Tests/AppStarterCoreTests"),
        // the app's own logic (AppModel: placing apps, steps, login/logout, import) on a scratch APPSTARTER_HOME
        .testTarget(name: "AppStarterTests", dependencies: ["AppStarter", "AppStarterCore"], path: "Tests/AppStarterTests"),
    ],
    swiftLanguageVersions: [.v5]
)
