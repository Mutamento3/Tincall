// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LAME",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "LAME", type: .dynamic, targets: ["LAME"])],
    targets: [
        .target(name: "LAME", path: "Sources", publicHeadersPath: "include",
            cSettings: [.define("HAVE_CONFIG_H")])
    ]
)
