// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TicketParty",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "TicketPartyDataStore",
            targets: ["TicketPartyDataStore"]
        ),
        .library(
            name: "TicketPartyModels",
            targets: ["TicketPartyModels"]
        ),
        .library(
            name: "TicketPartyUI",
            targets: ["TicketPartyUI"]
        ),
        .executable(
            name: "tp",
            targets: ["tp-cli"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "TicketPartyUI",
            dependencies: [
                "TicketPartyDataStore",
                "TicketPartyModels",
            ]
        ),
        .target(
            name: "TicketPartyModels"
        ),
        .target(
            name: "TicketPartyDataStore",
            dependencies: [
                "TicketPartyModels",
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
            ]
        ),
        .executableTarget(
            name: "tp-cli",
            dependencies: ["TicketPartyModels"]
        ),
    ]
)
