// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NudgeAlarm",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "NudgeAlarm",
            targets: ["NudgeAlarm"])
    ],
    targets: [
        .target(
            name: "NudgeAlarm",
            path: ".",
            exclude: ["Info.plist"],
            sources: [
                "NudgeAlarmApp.swift",
                "Models",
                "Services",
                "Views"
            ]
        )
    ]
)
