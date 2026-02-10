// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TicketPartyPackage",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "TicketPartyShared",
            targets: ["TicketPartyShared"]
        ),
        .executable(
            name: "tp",
            targets: ["tp"]
        ),
    ],
    targets: [
        .target(
            name: "TicketPartyShared",
            path: "PackageSources/TicketPartyShared"
        ),
        .executableTarget(
            name: "tp",
            dependencies: ["TicketPartyShared"],
            path: "PackageSources/tp"
        ),
    ]
)
