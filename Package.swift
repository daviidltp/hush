// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Boveda",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Boveda", targets: ["Boveda"]),
        .executable(name: "HushBridge", targets: ["HushBridge"]),
        .executable(name: "HushMenu", targets: ["HushMenu"]),
    ],
    dependencies: [
        // Copia local de KDBXKit (commit e9b8839) con un parche en las fechas; ver Vendor/KDBXKit/PARCHE-BOVEDA.md.
        .package(path: "Vendor/KDBXKit"),
    ],
    targets: [
        .target(
            name: "BovedaCore",
            dependencies: [.product(name: "KDBXKit", package: "KDBXKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Boveda",
            dependencies: ["BovedaCore", .product(name: "KDBXKit", package: "KDBXKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Puente de mensajería nativa para la extensión del navegador (va dentro de la app como «hush-bridge»).
        .executableTarget(
            name: "HushBridge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Ayudante que pone el icono en la barra de menús (va dentro de la app como Helpers/HushMenu.app).
        .executableTarget(
            name: "HushMenu",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BovedaCoreTests",
            dependencies: ["BovedaCore", .product(name: "KDBXKit", package: "KDBXKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
