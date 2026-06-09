"""Flutter engine release versions and their metadata.

Each version entry maps a Flutter SDK version string to a struct containing:
- engine_revision: The engine commit hash (used in artifact URLs)

ARTIFACT_CHECKSUMS maps version → artifact_path → sha256.
"""

FLUTTER_VERSIONS = {
    "3.41.2": struct(
        engine_revision = "6c0baaebf70e0148f485f27d5616b3d3382da7bf",
        material_fonts_url = "flutter_infra_release/flutter/fonts/3012db47f3130e62f7cc0beabff968a33cbec8d8/fonts.zip",
    ),
    "3.41.6": struct(
        engine_revision = "425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb",
        material_fonts_url = "flutter_infra_release/flutter/fonts/3012db47f3130e62f7cc0beabff968a33cbec8d8/fonts.zip",
    ),
    "3.41.7": struct(
        engine_revision = "59aa584fdf100e6c78c785d8a5b565d1de4b48ab",
        material_fonts_url = "flutter_infra_release/flutter/fonts/3012db47f3130e62f7cc0beabff968a33cbec8d8/fonts.zip",
    ),
    "3.44.0": struct(
        engine_revision = "4c525dac5ebe5971c5708ef73558ed8edcf4a362",
        material_fonts_url = "flutter_infra_release/flutter/fonts/3012db47f3130e62f7cc0beabff968a33cbec8d8/fonts.zip",
    ),
    "3.44.1": struct(
        engine_revision = "c416acfeb8126e097f758c664aaa3da929e27da0",
        material_fonts_url = "flutter_infra_release/flutter/fonts/3012db47f3130e62f7cc0beabff968a33cbec8d8/fonts.zip",
    ),
}

# Checksums for engine artifacts, keyed by version then artifact path.
# Artifact paths are relative to:
#   https://storage.googleapis.com/flutter_infra_release/flutter/{engine_revision}/
# Artifacts not listed here will be downloaded without verification.
# Run `bazel run //tools/update_flutter_version -- <version>` to populate all checksums.
ARTIFACT_CHECKSUMS = {
    "3.41.2": {
        # Patched Dart SDK for Flutter (debug + product)
        "flutter_patched_sdk.zip": "4e8c8a648a8842769979075e9b1bb211f82acf04b67fb7570729d0f9e0246630",
        "flutter_patched_sdk_product.zip": "c0f081178ccb373ab1e64e50eac8a5361cdf16fb7f8bc5c98668e0c873e870fa",
        # Host Dart SDK (the Flutter-bundled Dart SDK per host platform)
        "dart-sdk-darwin-arm64.zip": "d3640a93b20573bfc3e7ae7802b3500f1f6d007ffeb6cd86d404cfbe48b496ae",
        "dart-sdk-darwin-x64.zip": "e09bb097b324c65fe6ef7ea4a45788da8de547bef3b95fb183c6b08f17d54727",
        "dart-sdk-linux-x64.zip": "ca7adaeb1650dd145b9b746c4a9acbd75bee221473d08a719efb9a5289ab1584",
        "dart-sdk-linux-arm64.zip": "ac24f7b890aa168822014c69b603a7b1f7d9212f6f7544f2e8d7272c36015694",
        "dart-sdk-windows-x64.zip": "7ba424b9e87220a0250277319fb7eadd9bddbf16b7b9d647937d7191934c574a",
        # Host tools (frontend_server, gen_snapshot, icudtl.dat)
        "darwin-arm64/artifacts.zip": "7844f803a6fe74a34daa6cff05eea4c646ff4935eaf20246b8003d84b389a73a",
        "darwin-x64/artifacts.zip": "7d5e9ef678143a70987071f539624d62081b750f7e603eabed2acf4e6033a273",
        "linux-x64/artifacts.zip": "51721ee4c5536d53e5ef1eb7cfbc2345804d4d99a6b293016568b56dcf01467b",
        "linux-arm64/artifacts.zip": "32a68d08fae569cd1f169880fdfa847343d1c03cac678705a9c7dfa13d11f96e",
        "windows-x64/artifacts.zip": "9e6c7586c7c8397c3a78c47fca9b2a34e7ee2ae19535d2221d6ded7f864b5694",
        # Release host tools (macOS only — product-mode gen_snapshot for AOT builds)
        "darwin-arm64-release/artifacts.zip": "3f2c3c0454da1d171e5e4bcb2c4f6d87c5fc1f931b2f7fb47fdca1750bf14434",
        "darwin-x64-release/artifacts.zip": "244a1526ac04d60893e5e2c1436bd270326d3357a22723eecf5ab51ec18b416a",
        # Font-subset tools (const_finder + font-subset binary for icon tree shaking)
        "darwin-arm64/font-subset.zip": "5bc75e65a6393a51953f6e4c41962ef1142fc0f6f6116aebe6faa643c79cc72a",
        "darwin-x64/font-subset.zip": "989a152ec7ed8e1170d5d8fb5a245b50c98a432f1ee8ed0334f77584fd383ba0",
        "linux-x64/font-subset.zip": "fcc2ca60dad491c7c0b41cb2330b8d401cc4fd416ad11d27162446039fceef1e",
        "linux-arm64/font-subset.zip": "662f67acfd82bc657870dc49458a2d2b08200b28d55bf1600c04be18f2db4406",
        "windows-x64/font-subset.zip": "3d04d80b1d3b7545d4a716b1f31dfd07561a014d2d417068580fd708ac78d237",
        # Flutter web SDK
        "flutter-web-sdk.zip": "202458638ffe543e6bfe063b497224e64d18aa7eabc5a3dd78b238abcab92809",
        # Desktop engine runtime libraries (release mode)
        "darwin-x64-release/FlutterMacOS.framework.zip": "d3e7fbfe522cea597abb3110a9ecd1d380bfaa8939c32dc477172f540216feb1",
        "linux-x64-release/linux-x64-flutter-gtk.zip": "7a2e0b8d3bb5f79385ab4eb4ace79b278740a6159ac1acdac7e23217ff679852",
        "windows-x64-release/windows-x64-flutter.zip": "99ced94840ab9887054356a213e275dcf9dd6331edf40bf863463cfc8b6576a0",
        # Desktop engine runtime libraries (debug mode — JIT, needed for -c dbg)
        "darwin-x64/FlutterMacOS.framework.zip": "47d14b07f673ad703b28bc96eb0efb20bbbf7a645e1e0a62e2516ca9545f47f4",
        "linux-x64-debug/linux-x64-flutter-gtk.zip": "0c2f047c09f386043201b175e4ba03f1cbb59b5a731a5f60b44d91ce8d4b5b46",
        "windows-x64-debug/windows-x64-flutter.zip": "d654c8bb32a8e8e59faee2fabe76109b6cb2bd4e7f62c41848ac41fc8fe06491",
        # iOS engine (Flutter.xcframework — release for device, debug for simulator)
        "ios-release/artifacts.zip": "86667d04a9ab172da940debf82c878144e66ffa5fe47a1f854b0267cce47dbee",
        "ios/artifacts.zip": "a0883f9232e203c5dfc6808bcab9abc2a57d98354244e3f6c3b03f715971913a",
        # Material design fonts (MaterialIcons-Regular.otf, Roboto family)
        "material_fonts.zip": "e56fa8e9bb4589fde964be3de451f3e5b251e4a1eafb1dc98d94add034dd5a86",
    },
    "3.41.6": {
        # Patched Dart SDK for Flutter (debug + product)
        "flutter_patched_sdk.zip": "4b0598dc6c6fde1619033995009c302e5e75085742e0f7e0abcf952ec5476ab6",
        "flutter_patched_sdk_product.zip": "9f138444c433d2aabb105566e8e5a997c051e84fb6d312c6d1dbb9263f981db1",
        # Host Dart SDK (the Flutter-bundled Dart SDK per host platform)
        "dart-sdk-darwin-arm64.zip": "53a7f09b9c5ea0776ccfd2aeae21a8cec5e4cf94da95ddb8b8b73dc78e878e4f",
        "dart-sdk-darwin-x64.zip": "d1dcf8ebfe076a75640203842421f0c0654208b35a4e7d722970cd11847a2682",
        "dart-sdk-linux-x64.zip": "73a37976c9398da9de60bab5d8d93740feb1b9a5d9fb669c0a38144fbe118fc9",
        "dart-sdk-linux-arm64.zip": "198d78388c542f48a3c79df5467614dda5fbe6dcf7116523915afd40cc367c9f",
        "dart-sdk-windows-x64.zip": "dfd0d5f4368abb4f2829a54f56a98215a8c4c68e61d0f90cf6f338b107feadfc",
        # Host tools (frontend_server, gen_snapshot, icudtl.dat)
        "darwin-arm64/artifacts.zip": "3159d137c1ef9ac2ea9ec881a4dbdb12f8068388a7a3b496829fbd63f2aaefa3",
        "darwin-x64/artifacts.zip": "3afab5c9a4ef6108f2af5658b5d0bf9e0790bef08e4c102313b215d30602084e",
        "linux-x64/artifacts.zip": "d7903ae988f4214cef9977228d620515a606b9771c269d0bd6baa0ec03e4c223",
        "linux-arm64/artifacts.zip": "2673d2887c7a85808ada4c7fcd0ab1be36c81993f01f9503238759c89e643c85",
        "windows-x64/artifacts.zip": "d86678a1527f5e388d0ecd20a1a9d63db9a1922c0044653e1acae16674ddcddd",
        # Release host tools (macOS only — product-mode gen_snapshot for AOT builds)
        "darwin-arm64-release/artifacts.zip": "6c253ad321795000b85d9bc38baa77f2fd99c71c9767295c39a26aaccdfcde54",
        "darwin-x64-release/artifacts.zip": "27edaf1ff30b27ad64bd59085f1c753469769120cf0bcc4512fa9ea28a71c16e",
        # Font-subset tools (const_finder + font-subset binary for icon tree shaking)
        "darwin-arm64/font-subset.zip": "71aa6e598b1d0056116467921a84692dfc35d7a18c5d36509f5f154d8464eecb",
        "darwin-x64/font-subset.zip": "2072eb3dae1f02a3eb75e1d876c233f770473b4369fb631209b93b0b6b20c309",
        "linux-x64/font-subset.zip": "61c62032dbed2097a4c69001c94905f0e5624317b5f8405cce929eaf5e6679e0",
        "linux-arm64/font-subset.zip": "f537055a9377b2e2129a33608deed64aaca08966eef50e6de9201f86a665174d",
        "windows-x64/font-subset.zip": "b7484044f7850e156a69dd87d5d961be47fa9776b811cb28547a2d6a07948210",
        # Flutter web SDK
        "flutter-web-sdk.zip": "eeb6729c55a51b2d12276c0246522da6fc0404ad9b214aac9be7fdec51798ece",
        # Desktop engine runtime libraries (release mode)
        "darwin-x64-release/FlutterMacOS.framework.zip": "16b3049848433717d3adda2a36b34fe5b9afb8eb709743c167c91145001a34d2",
        "linux-x64-release/linux-x64-flutter-gtk.zip": "20278f9f71b74a7809e4eefc07462f51fd25b29597241462dc44943a6461b732",
        "windows-x64-release/windows-x64-flutter.zip": "a8b1bc20284a7a9fa7c1872881c33924e18fd306707543dd8dfe2683c4cf9955",
        # Desktop engine runtime libraries (debug mode — JIT, needed for -c dbg)
        "darwin-x64/FlutterMacOS.framework.zip": "57b4b7785c3d593ea3b7f0b54887e5b74b424c38fedf5d5d64abe4de797df95b",
        "linux-x64-debug/linux-x64-flutter-gtk.zip": "a20d0900864bfc0ae496fe1ca5e38c86a84dfa7d9571558983a4f41b785bd6c4",
        "windows-x64-debug/windows-x64-flutter.zip": "e1061d2931761a2a735fe292d05904c1057d3011242948d48bb35abf6d5bbf69",
        # iOS engine (Flutter.xcframework — release for device, debug for simulator)
        "ios-release/artifacts.zip": "82746372ff1bcf576eff0f53f1b6416aca54a8891e2b13c1d01a8fb1ba1fab7e",
        "ios/artifacts.zip": "aa3af6c94e17b1b762c89c002babfb6c836200b208385c94996a4a161683a2ed",
        # C++ client wrapper (Windows — flutter/plugin_registry.h)
        "windows-x64/flutter-cpp-client-wrapper.zip": "96ac4ff7108d6bb0a56723486b19d9bff328acf16657c85a0dd7bf4a6d831b84",
        # Material design fonts (MaterialIcons-Regular.otf, Roboto family)
        "material_fonts.zip": "e56fa8e9bb4589fde964be3de451f3e5b251e4a1eafb1dc98d94add034dd5a86",
    },
    "3.41.7": {
        # Patched Dart SDK for Flutter (debug + product)
        "flutter_patched_sdk.zip": "1e85925ed58e03dfae6933fc8b83553edb5715e249cb16cd7a1f13e2143c6e50",
        "flutter_patched_sdk_product.zip": "12aae288cf53f0f4476ae8da7d20e46930dc1aa54c82a7ad33c93815af46588a",
        # Host Dart SDK (the Flutter-bundled Dart SDK per host platform)
        "dart-sdk-darwin-arm64.zip": "d5c01231a770844e540e1c2b40e623d1199be4eb89083c5a16c8a60e43e81427",
        "dart-sdk-darwin-x64.zip": "bff51e4b0510dfa2d9d936aff938907a54ca86f220db8b098dfe4319c9916a67",
        "dart-sdk-linux-x64.zip": "95f656395ee65b1dfefd901bfde47ffba372632c73aedf6d4a5a0745af7ede99",
        "dart-sdk-linux-arm64.zip": "6c7be6855ad072137ef3294a0858d84b6920049f45a6981b17dc557d1dbf3acb",
        "dart-sdk-windows-x64.zip": "21160f2537c41f007d009626a34de9836a24c2b83be15bcc7779d852beb2eab6",
        # Host tools (frontend_server, gen_snapshot, icudtl.dat)
        "darwin-arm64/artifacts.zip": "46bf6636154f51a27199ef9a66887497202d35e1338a40f6ce84df75f3c323c4",
        "darwin-x64/artifacts.zip": "4aa651cbfb893b2c289d1ae1c2da81eb999c153d62ac8e28172d6c0c5dcd6f5e",
        "linux-x64/artifacts.zip": "711e8a1ff2d32ad8e466932a0700bd86010691101845bd6d10abb5d632ca8d69",
        "linux-arm64/artifacts.zip": "959709551f4d8fb969e148d38466f15ecf456aa913e45386692bbe6c6729a6c4",
        "windows-x64/artifacts.zip": "4692472faa181836968eaedf38b761aa726cfc8731805707c45c82072755b9de",
        # Release host tools (macOS only — product-mode gen_snapshot for AOT builds)
        "darwin-arm64-release/artifacts.zip": "8e50c773e7d7cdadb2550596a5a227ea331472ebee0f2f001c28f0933c28d983",
        "darwin-x64-release/artifacts.zip": "3db2446aa4a327ec3e11d92350fe9db1dbadfa857692fdee80ade212655edd4f",
        # Font-subset tools (const_finder + font-subset binary for icon tree shaking)
        "darwin-arm64/font-subset.zip": "e3fbfdfe74a9aab626f3300fddb55685a2283e2fbfe73cd2dea8b327cb0383b6",
        "darwin-x64/font-subset.zip": "4a82a60d3d0e6d4d680d115a6eb162571fb50ea3f4b4c0f15db6f7b17d9fb49e",
        "linux-x64/font-subset.zip": "a530e658c56d3d53d633c5cd49c4889f31858c48987645e39c9c34d03de01c60",
        "linux-arm64/font-subset.zip": "cd54a1d2d94dc6e56c7514c37c46765da07aa04367831db675b178a165130e40",
        "windows-x64/font-subset.zip": "2aeb04aed2c8483513662ed398e072b034662ddb8d313250c35691ed84344e43",
        # Flutter web SDK
        "flutter-web-sdk.zip": "544aac38a8e17fc4f69055f8527fda0d39fa8a1c1a6782947f25011b1869f650",
        # Desktop engine runtime libraries (release mode)
        "darwin-x64-release/FlutterMacOS.framework.zip": "414badb810f2fabf5afd32c3dbd1c08060cf0e272a2a660705ab213b8b9c29a5",
        "linux-x64-release/linux-x64-flutter-gtk.zip": "649fff2f7c97b6255c91e66e23a0e18d6e185c95464e2adbded2ae2e02b74348",
        "windows-x64-release/windows-x64-flutter.zip": "03c60d234ebc1a8d8fd85705f780827c2f4a0a93ecdaa8c1cf1465867afff8ff",
        # Desktop engine runtime libraries (debug mode — JIT, needed for -c dbg)
        "darwin-x64/FlutterMacOS.framework.zip": "dcbf4761724952da409e2f27dba950169de1c0424262bbd049d2400f931d0eea",
        "linux-x64-debug/linux-x64-flutter-gtk.zip": "f24957d2d0ffec95c30cbf4f9d6f9fb5e7e2fb2689bbebba56b6233918dc8264",
        "windows-x64-debug/windows-x64-flutter.zip": "836474f4708f03642b3b3ca16acde792d7c7176ec8739918470ee186bf526683",
        # iOS engine (Flutter.xcframework — release for device, debug for simulator)
        "ios-release/artifacts.zip": "5f8694a3a218aa07129f0acbb2276d7e9d9ff1fc73dd65fcd8b78a9988bf4eb1",
        "ios/artifacts.zip": "911dd68a4297aa074092aea8076b2260364d7de00b9dbb3e3a6250829a073a4d",
        # C++ client wrapper (Windows — flutter/plugin_registry.h)
        "windows-x64/flutter-cpp-client-wrapper.zip": "9538c7dc3ddc20aa224382990680407343d566b1b497f83a2b323b518a522168",
        # Material design fonts (MaterialIcons-Regular.otf, Roboto family)
        "material_fonts.zip": "e56fa8e9bb4589fde964be3de451f3e5b251e4a1eafb1dc98d94add034dd5a86",
    },
    "3.44.0": {
        # Patched Dart SDK for Flutter (debug + product)
        "flutter_patched_sdk.zip": "2f5feba0f5e1eef058ccfb536fe99078956abf0392dbbdc2a3d9b94722f06381",
        "flutter_patched_sdk_product.zip": "9cbb4c1d130945e9f1f87e039fca592cc40eb24ae98f385a15d4666e6d806ac3",
        # Host Dart SDK (the Flutter-bundled Dart SDK per host platform)
        "dart-sdk-darwin-arm64.zip": "fc0fc598cdebb829ed14d35d36afed1c5ec88e814788810187d1c0851cd02d63",
        "dart-sdk-darwin-x64.zip": "f3a96a755be00bb45dc635a39c569c4d176f9d35db6460fe7ecbce861b72d629",
        "dart-sdk-linux-x64.zip": "c48c502bccab437e8ccc5a51cfec96fc39c6ad075567d98a5ae64704735566ec",
        "dart-sdk-linux-arm64.zip": "5dfcca67f48e0b01609df7f1e96c3117b30f2456e92973578fc8e221ccc30212",
        "dart-sdk-windows-x64.zip": "b15a63331aac81050d4db3e082a1d1f3783ef9ffc9b3c2ffa9c9910eeeaf0d11",
        # Host tools (frontend_server, gen_snapshot, icudtl.dat)
        "darwin-arm64/artifacts.zip": "9ef2c6bd56936fee34f53fb82221fad8bddc35863b62eb9803d26b5f41857d2f",
        "darwin-x64/artifacts.zip": "6d4937fb09de3f516e4e295a5b75711b5b81e8a4461af9de08f5346a96d2ef99",
        "linux-x64/artifacts.zip": "62c031502c444acc76ceb7574b540c6aa71f495dee845f2b43f28734f95e3864",
        "linux-arm64/artifacts.zip": "950edb5042a89db31e38526fd14524c838e023c6acf9b6c61c7bdd21e9ea473d",
        "windows-x64/artifacts.zip": "179969742e3fa0619b25ba6c50b937e2acea4d253c7a37a5ac40384ceaecba30",
        # Release host tools (macOS only — product-mode gen_snapshot for AOT builds)
        "darwin-arm64-release/artifacts.zip": "0531388a6a0f36ce4e31a4c6fb0b69b4c7e682b23cb93c895eefbf6696c3acea",
        "darwin-x64-release/artifacts.zip": "bb40150d73bd7fa535718aedcae73b4dc8b26f01f1aaf29106653944cad25533",
        # Font-subset tools (const_finder + font-subset binary for icon tree shaking)
        "darwin-arm64/font-subset.zip": "33809d42b1d7681183f17ed245362aa6859cec58a049bceb921df8fd86a9b8c1",
        "darwin-x64/font-subset.zip": "ffe1b08da9ae55449f3a2a8e63667ea04d521f6fa41b1c49f0dd1ae31f2d8246",
        "linux-x64/font-subset.zip": "0f14c76f551af4db42144397ed826cfe1a76995e04a547d154e340ce1997a00c",
        "linux-arm64/font-subset.zip": "f3b2113431e5cca4f140eac4bc0a433be6b145309786e2d13b55ca7a19d0dfb9",
        "windows-x64/font-subset.zip": "2c1c6d700929ca1ccaff368019bb7a580852657d4002c44d523069f58bf9e667",
        # Flutter web SDK
        "flutter-web-sdk.zip": "b20e5dc2664d54409027d2152b7b06c79ba2178a047910380fff86ba49cdad47",
        # Desktop engine runtime libraries (release mode)
        "darwin-x64-release/FlutterMacOS.framework.zip": "0ac3deba340076c65db5ba548505a149272dd34c5c85c22542821aa8bf53165c",
        "linux-x64-release/linux-x64-flutter-gtk.zip": "00d3565cc1a6b7dfb90f06ac29dff25cd63be54aec36d9f419f28c748a82c016",
        "windows-x64-release/windows-x64-flutter.zip": "acb8d655a08c3e8f686efbcd00d2f27343b6cef11c016d84373ad2ed01b46c98",
        # Desktop engine runtime libraries (debug mode — JIT, needed for -c dbg)
        "darwin-x64/FlutterMacOS.framework.zip": "1cf787ccf4c02929574720e1f80e007e780b55b78578fcf9ae36224ee9bdd7de",
        "linux-x64-debug/linux-x64-flutter-gtk.zip": "1617575ec5b6ec19ac3d63b530ee403e3525a439bddb80b1505f62fce36cb823",
        "windows-x64-debug/windows-x64-flutter.zip": "bb819021bed98065375903cb42677c5c7f02bdc4e4d5c2dbc5cf66e54bd75beb",
        # iOS engine (Flutter.xcframework — release for device, debug for simulator)
        "ios-release/artifacts.zip": "c9c49bf00a4e5695c3c2ee8021f7258d81dabe34836d694be360916d7358066e",
        "ios/artifacts.zip": "e820e25d0c3052201e0e4f7a29b257758029288ae1031b5931344ec4ed3493b7",
        # C++ client wrapper (Windows — flutter/plugin_registry.h)
        "windows-x64/flutter-cpp-client-wrapper.zip": "18dc95fa2945026baaca267b250ac522857834d81a963c75f21d000e161033d8",
        # Material design fonts (MaterialIcons-Regular.otf, Roboto family)
        "material_fonts.zip": "e56fa8e9bb4589fde964be3de451f3e5b251e4a1eafb1dc98d94add034dd5a86",
    },
    "3.44.1": {
        # Patched Dart SDK for Flutter (debug + product)
        "flutter_patched_sdk.zip": "a166e9af74d737f51d18e177f5abcbfdf746100e523db7f38b1c64e6d70fb19b",
        "flutter_patched_sdk_product.zip": "92e702b9ff45202a4d7af6d1e96079a2313697973422b35a7cf631dc36e2b8ca",
        # Host Dart SDK (the Flutter-bundled Dart SDK per host platform)
        "dart-sdk-darwin-arm64.zip": "c327cf7ff1342fb3da98b49c4586262101e743af13406c4540ea79ad136bb8c2",
        "dart-sdk-darwin-x64.zip": "e797a4cb59d515d375f44ff76d0763388c1b55675d564df5436778f7619cfd4c",
        "dart-sdk-linux-x64.zip": "fc2f1d6d211533e608d0893f455f5c0c4bb5eaa518c1a78bc4d817c07c81c95b",
        "dart-sdk-linux-arm64.zip": "20c918258fc88a1322972f96341e21c52bfa03cd6388f955ef3169136860b4cd",
        "dart-sdk-windows-x64.zip": "e843f007e1d5778f9e364fd0638dcb8f81a9a21c442e0a7ba780d11d9a29c254",
        # Host tools (frontend_server, gen_snapshot, icudtl.dat)
        "darwin-arm64/artifacts.zip": "cd5055cba877ec3a04a4cdc266bffabf5f543bc15eb89a1bccc063a57634f313",
        "darwin-x64/artifacts.zip": "6e1e9bbd1ab240ea67d3cd9d899edb64cd0d9fbd648e7929a23e203dc96fc099",
        "linux-x64/artifacts.zip": "c81653e201457115ef963deed7423216ac54edd7d28233022b39f02df77dc4ea",
        "linux-arm64/artifacts.zip": "faad44e758e1c0a0ee98294ed60790f7b54a61a4b3a06d352bae2af622e01ad2",
        "windows-x64/artifacts.zip": "55e1383ceb95df8e6df6a611876717cadf995f138c67b09b497c13d2d5d5f96e",
        # Release host tools (macOS only — product-mode gen_snapshot for AOT builds)
        "darwin-arm64-release/artifacts.zip": "2731c9240245d5f540556580d12d58e7a75dde0694207b0d1fd0e25009dc2e63",
        "darwin-x64-release/artifacts.zip": "68fecec2a09d3442d59eb087dd830f8611583dbbe2440cb9791a7e5feed4050d",
        # Font-subset tools (const_finder + font-subset binary for icon tree shaking)
        "darwin-arm64/font-subset.zip": "910d52efb1f7aff4bf7dcc13ca788bfc29a81b133f8acac69f10ac978632a042",
        "darwin-x64/font-subset.zip": "54247cd60d8e6d79ce6c7fc07b08fe5e8228c539181cbff7aef5128aefab370e",
        "linux-x64/font-subset.zip": "b63f8888c41cf85786d0c3f68eaacf8232be10d9b7200d066b5a81d0289d59cd",
        "linux-arm64/font-subset.zip": "8d221ff730f872db3185e3674a09f0c2075eea8e37125e98ed02d8e10eabdda8",
        "windows-x64/font-subset.zip": "3671d14727688f0191392dfc183bf824014a99ad4bb984324da7340958ba9ca6",
        # Flutter web SDK
        "flutter-web-sdk.zip": "ffe87e38e7ef3759d3c61d8e690e4b7d7c320f2d11197a22a6e3ed34ac6e3d03",
        # Desktop engine runtime libraries (release mode)
        "darwin-x64-release/FlutterMacOS.framework.zip": "967d6f5aab4a3eaebe8c960f38a4d04c92e7290babc20687aaa2e661be7511a8",
        "linux-x64-release/linux-x64-flutter-gtk.zip": "def37ea8d8ae3559b1dceb25707b2ed953277130b99230bb3e36b32a0dbe6bd9",
        "windows-x64-release/windows-x64-flutter.zip": "14f0f21dd952ef36708e5504eb1a4d7a17edc743aeed2f8fdc5dd07b0e41f333",
        # Desktop engine runtime libraries (debug mode — JIT, needed for -c dbg)
        "darwin-x64/FlutterMacOS.framework.zip": "32f1882c5a5e66debf23cb5caa6cb50fae377be4889c8088d2f1ee23b7654121",
        "linux-x64-debug/linux-x64-flutter-gtk.zip": "0e4b1a8c3c453e87666c3a750a2826aff067dd7184628a67e91963de92a43ecb",
        "windows-x64-debug/windows-x64-flutter.zip": "17ecaa158637145884813f4d306cb575360dfbbf656092939fe8a03b1f9d3ed4",
        # iOS engine (Flutter.xcframework — release for device, debug for simulator)
        "ios-release/artifacts.zip": "7f1dcf0011c16c1e82fbbdfcf6eb6ce45bc32269109febdbc811e952afc573e0",
        "ios/artifacts.zip": "436bd866a3e080e3e71d72debb382e3d642a48688d1a4279213a80fa713634bf",
        # C++ client wrapper (Windows — flutter/plugin_registry.h)
        "windows-x64/flutter-cpp-client-wrapper.zip": "ecb61316a0da7c3f8e55bdaadc9c2b07333c72259a3b2de32762c2e123825f0e",
        # Material design fonts (MaterialIcons-Regular.otf, Roboto family)
        "material_fonts.zip": "e56fa8e9bb4589fde964be3de451f3e5b251e4a1eafb1dc98d94add034dd5a86",
    },
}

# Chromium sysroot checksums for hermetic Linux desktop builds.
# These are independent of the Flutter version — they change rarely.
# The SHA-256 doubles as the filename on the GCS bucket.
# Source: Flutter engine's build/linux/sysroot_scripts/sysroots.json
LINUX_SYSROOT_CHECKSUMS = {
    "amd64": "36a164623d03f525e3dfb783a5e9b8a00e98e1ddd2b5cff4e449bd016dd27e50",
    "arm64": "2f915d821eec27515c0c6d21b69898e23762908d8d7ccc1aa2a8f5f25e8b7e18",
}
