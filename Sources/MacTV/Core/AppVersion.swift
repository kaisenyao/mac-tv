import Foundation

/// 这个 Mac TV 的版本号（Info.plist 里的 CFBundleShortVersionString）
enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
