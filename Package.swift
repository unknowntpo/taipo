// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Taipo",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "TaipoSettingsApp", targets: ["TaipoSettingsApp"]),
        .library(name: "TaipoCore", targets: ["TaipoCore"]),
        .library(name: "TaipoIME", targets: ["TaipoIME"]),
        .executable(name: "TaipoIMEApp", targets: ["TaipoIMEApp"]),
        .executable(name: "taipo", targets: ["taipo"]),
        .executable(name: "taipo-bench", targets: ["taipo-bench"]),
        .executable(name: "taipo-dev", targets: ["taipo-dev"]),
        .executable(name: "taipo-asr", targets: ["taipo-asr"]),
    ],
    dependencies: [
        // On-device decision model runtime (Spec 004). FoundationModels integration is off by request.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(name: "TaipoCore", resources: [.copy("Resources/zh.tsv"), .copy("Resources/en.tsv")]),
        .executableTarget(name: "taipo", dependencies: ["TaipoCore"]),
        .target(name: "TaipoIME", dependencies: ["TaipoCore"]),
        .target(name: "TaipoDecision", dependencies: [
            "TaipoCore",
            "TaipoIME",
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
        .executableTarget(name: "TaipoSettingsApp", dependencies: ["TaipoCore", "TaipoIME", "TaipoDecision"]),
        .executableTarget(
            name: "TaipoIMEApp",
            dependencies: ["TaipoCore", "TaipoIME", "TaipoDecision", "TaipoVoice"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("InputMethodKit")]
        ),
        .executableTarget(name: "taipo-bench", dependencies: ["TaipoCore", "TaipoIME", "TaipoDecision"]),
        .executableTarget(name: "taipo-dev"),
        .target(name: "TaipoSpeech"),
        // Spec 012: whisper.cpp (MIT) official XCFramework, release b5454; checksum verified against two downloads.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .target(name: "TaipoVoice", dependencies: ["TaipoIME", "whisper"]),
        .executableTarget(name: "taipo-asr", dependencies: ["TaipoSpeech", "TaipoVoice"]),
        .testTarget(name: "TaipoCoreTests", dependencies: ["TaipoCore"], resources: [.copy("Cases")]),
        .testTarget(name: "TaipoIMETests", dependencies: ["TaipoCore", "TaipoIME"], resources: [.copy("Cases")]),
        .testTarget(name: "TaipoSpeechTests", dependencies: ["TaipoSpeech"]),
        .testTarget(name: "TaipoDecisionTests", dependencies: ["TaipoCore", "TaipoIME", "TaipoDecision"]),
    ]
)
