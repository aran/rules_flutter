// swift-tools-version: 5.9

// The Swift packages this workspace declares with rules_swift_package_manager
// (MODULE.bazel): those its Apple plugins depend on, as
// `bazel run @deps//swift:packages` prints them, which the app's own Swift
// code (native_firebase/) uses too. Pinned in Package.resolved by
// `bazel run @swift_package//:update`.
import PackageDescription

let package = Package(
    name: "rules_flutter_ios_example",
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "13.1.1"),
    ]
)
