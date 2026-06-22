// swift-tools-version: 5.9
import PackageDescription

// Empacota os fontes SwiftUI de MEngine/ como um executável macOS rodável via `swift run`.
// O Info.plist é embutido no binário (sectcreate) para que o macOS leia
// NSMicrophoneUsageDescription (microfone) e NSAppTransportSecurity (HTTP localhost).
let package = Package(
    name: "MEngineApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MEngineApp",
            path: "MEngine",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker",
                    "/Users/gustavomendesesilva/Documents/m-engine/ui-swift/MEngine/Info.plist",
                ])
            ]
        )
    ]
)
