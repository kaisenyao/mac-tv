import Foundation

/// The phone remote. Any phone browser opens it; "Add to Home Screen" makes it feel like an app.
///
/// Its markup, styles and script live in `Page/` as ordinary web files. They're served as one
/// page, with the stylesheet and script put inline, so the phone loads the remote in one request.
enum RemotePage {
    static let html: String = load()

    /// The page's files were found, so phones get the real remote.
    static var available: Bool { pageFolder != nil }

    private static func load() -> String {
        guard let folder = pageFolder,
              let page = try? String(contentsOf: folder.appendingPathComponent("remote.html"), encoding: .utf8),
              let style = try? String(contentsOf: folder.appendingPathComponent("remote.css"), encoding: .utf8),
              let script = try? String(contentsOf: folder.appendingPathComponent("remote.js"), encoding: .utf8)
        else {
            Log.remote.fault("The phone remote's page is missing from the app")
            return "<!doctype html><meta charset=\"utf-8\"><title>Mac TV Remote</title>"
                + "<p>The remote page is missing. Reinstall Mac TV.</p>"
        }
        return page
            .replacingOccurrences(of: #"<link rel="stylesheet" href="remote.css">"#, with: "<style>\n" + style + "</style>")
            .replacingOccurrences(of: #"<script src="remote.js"></script>"#, with: "<script>\n" + script + "</script>")
    }

    /// 遥控页用到的文件（主屏幕图标；手机不出声，没有声音文件），按名字给；只给这几个，别的名字一律没有
    static func asset(_ name: String) -> (data: Data, type: String)? {
        let types = ["touch-icon.png": "image/png"]
        guard let type = types[name], let folder = pageFolder,
              let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return (data, type)
    }

    /// The package's resource bundle holds `Page/`. It's in the app's Resources folder, or next to
    /// the binary in a Swift build or test run.
    private static var pageFolder: URL? {
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                      Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()]
        for place in places.compactMap({ $0 }) {
            if let bundle = Bundle(url: place.appendingPathComponent("MacTV_MacTV.bundle")),
               let folder = bundle.url(forResource: "Page", withExtension: nil) {
                return folder
            }
        }
        return nil
    }

    private final class BundleMarker {}
}
