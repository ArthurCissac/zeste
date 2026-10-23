// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Zeste",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Zeste",
            path: "Sources/Zeste",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
