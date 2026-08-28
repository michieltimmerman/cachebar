// swift-tools-version: 5.9
// The Swift target builds only the bare executable; packaging/build.sh wraps it
// into CacheBar.app (Info.plist, icon, bundled ai-cache-bar.py, codesign).
import PackageDescription

let package = Package(
    name: "CacheBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CacheBar")
    ]
)
