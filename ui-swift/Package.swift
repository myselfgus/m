// swift-tools-version: 5.9
import PackageDescription

// Empacota os fontes SwiftUI de MEngine/ como um executável macOS rodável via `swift run`.
// O Info.plist é embutido no binário (sectcreate) para que o macOS leia
// NSMicrophoneUsageDescription (microfone) e NSAppTransportSecurity (HTTP localhost).
let package = Package(
    name: "MEngineApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        // MarkdownUI: GFM rich rendering (headings, lists, tables, fenced code).
        // SwiftStreamingMarkdown (a 1ª opção) é iOS-only e usa iosMath/UIKit — não
        // compila no executável macOS. MarkdownUI suporta macOS 12+ e iOS 15+.
        // LaTeX NÃO é coberto (precisa de lib separada — pendente).
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1")
    ],
    targets: [
        .executableTarget(
            name: "MEngineApp",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
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
