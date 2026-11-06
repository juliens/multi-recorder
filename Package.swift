// swift-tools-version: 6.0
import PackageDescription

/// Files of the Steinberg VST3 SDK (MIT) needed to host plug-ins.
/// The SDK is in git submodules under Sources/VST3Host/vst3sdk.
let vst3SDKSources = [
    "pluginterfaces/base/conststringtable.cpp",
    "pluginterfaces/base/coreiids.cpp",
    "pluginterfaces/base/funknown.cpp",
    "pluginterfaces/base/ustring.cpp",
    "base/source/baseiids.cpp",
    "base/source/fbuffer.cpp",
    "base/source/fdebug.cpp",
    "base/source/fobject.cpp",
    "base/source/fstreamer.cpp",
    "base/source/fstring.cpp",
    "base/source/updatehandler.cpp",
    "base/thread/source/fcondition.cpp",
    "base/thread/source/flock.cpp",
    "public.sdk/source/common/commoniids.cpp",
    "public.sdk/source/common/commonstringconvert.cpp",
    "public.sdk/source/common/threadchecker_mac.mm",
    "public.sdk/source/common/memorystream.cpp",
    "public.sdk/source/vst/vstinitiids.cpp",
    "public.sdk/source/vst/hosting/connectionproxy.cpp",
    "public.sdk/source/vst/hosting/eventlist.cpp",
    "public.sdk/source/vst/hosting/hostclasses.cpp",
    "public.sdk/source/vst/hosting/module.cpp",
    "public.sdk/source/vst/hosting/module_mac.mm",
    "public.sdk/source/vst/hosting/parameterchanges.cpp",
    "public.sdk/source/vst/hosting/pluginterfacesupport.cpp",
    "public.sdk/source/vst/hosting/plugprovider.cpp",
    "public.sdk/source/vst/hosting/processdata.cpp",
    "public.sdk/source/vst/utility/stringconvert.cpp",
].map { "vst3sdk/" + $0 }

let package = Package(
    name: "MultiRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "VST3Host",
            // Samples and wrappers of the SDK hold resources that SwiftPM would try to bundle.
            exclude: [
                "vst3sdk/public.sdk/samples",
                "vst3sdk/public.sdk/source/vst/interappaudio",
                "vst3sdk/public.sdk/source/vst/auv3wrapper",
                "vst3sdk/public.sdk/source/vst/auwrapper",
                "vst3sdk/public.sdk/source/vst/aaxwrapper",
            ],
            sources: ["Host"] + vst3SDKSources,
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("vst3sdk"),
                .unsafeFlags(["-fobjc-arc"]),
            ],
            cxxSettings: [
                .headerSearchPath("vst3sdk"),
                .define("RELEASE", to: "1"),
                .unsafeFlags(["-fobjc-arc", "-Wno-deprecated-declarations"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudioKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(name: "RecorderCore", dependencies: ["VST3Host"]),
        .executableTarget(name: "MultiRecorder", dependencies: ["RecorderCore"]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
