// swift-tools-version: 6.2
import PackageDescription

// The seam between the free app and the Pro layer. It is its own package, not a
// target of the root one, so the private CortlandPro package can import it
// without SwiftPM seeing a dependency cycle back into Cortland.
//
// Nothing in here is Pro code — it is the vocabulary both sides speak: the
// feature protocols, the registry that holds their (optional) implementations,
// the theme/format values the app hands down, and the session parsers the free
// teaser and the Pro panel both read.
let package = Package(
    name: "CortlandProInterface",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CortlandProInterface", targets: ["CortlandProInterface"]),
    ],
    targets: [
        .target(
            name: "CortlandProInterface",
            path: "Sources/CortlandProInterface",
            swiftSettings: [
                // Matches the app target: overwhelmingly AppKit main-thread
                // code, with the parse/cache types marked nonisolated.
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
