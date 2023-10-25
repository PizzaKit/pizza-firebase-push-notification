// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "PizzaFirebasePushNotification",
    platforms: [
        .iOS(.v15),
        .tvOS(.v15), 
        .watchOS(.v6)
    ],
    products: [
        .library(
            name: "PizzaFirebasePushNotification",
            targets: ["PizzaFirebasePushNotification"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/PizzaKit/pizzakit",
            from: "1.0.1"
        ),
        .package(
            url: "https://github.com/firebase/firebase-ios-sdk",
            from: "10.16.0"
        )
    ],
    targets: [
        .target(
            name: "PizzaFirebasePushNotification",
            dependencies: [
                .product(name: "PizzaKit", package: "pizzakit"),
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
