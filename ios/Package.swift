// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "IntakeKit",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "IntakeKit", targets: ["IntakeKit"])],
  dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0")],
  targets: [
    .target(name: "IntakeKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
    .testTarget(
      name: "IntakeKitTests", dependencies: ["IntakeKit"], resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v5]
)
