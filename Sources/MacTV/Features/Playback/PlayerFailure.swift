import AppKit
import SwiftUI
import WebKit

struct PlayerFailure: Equatable {
    let message: String
    var selected = 0
}

extension TVController {
    func recordPlayerFailure(_ web: WKWebView, error: Error? = nil) {
        guard web === webView, case .player = mode else { return }
        if let error, (error as NSError).code == NSURLErrorCancelled { return }
        if let error { Log.playback.failure("Streaming page didn't load", error) }
        else { Log.playback.error("Streaming page stopped responding") }
        playerFailure = PlayerFailure(message: error == nil
            ? "The streaming page stopped responding."
            : "The streaming page couldn’t load. Check the connection, then try again.")
    }
    func handlePlayerFailure(_ command: RemoteCommand) {
        guard var panel = playerFailure else { return }
        switch command {
        case .move(.left), .move(.up): panel.selected = max(0, panel.selected - 1)
        case .move(.right), .move(.down): panel.selected = min(2, panel.selected + 1)
        case .select: performPlayerRecovery(panel.selected); return
        case .back: goHome(); return
        default: return
        }
        playerFailure = panel
    }
    func performPlayerRecovery(_ action: Int) {
        switch action {
        case 0:
            playerFailure = nil
            webView?.reload()
        case 1:
            guard case .player(let service) = mode else { return }
            let url: URL?
            if let current = webView?.url, ["http", "https"].contains(current.scheme ?? "") { url = current }
            else if case .web(let original) = service.kind { url = original }
            else { url = nil }
            guard let url, let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
                showToast("Safari Isn’t Available"); return
            }
            if SystemGuard.allows("open Safari") {
                NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
            }
            goHome()
        default: goHome()
        }
    }
}

struct PlaybackFailureView: View {
    @ObservedObject var tv: TVController
    var body: some View {
        VStack(spacing: 28) {
            Text("Can’t Play").font(.tv(.title3, emphasized: true))
            Text(tv.playerFailure?.message ?? "").font(.tv(.body)).multilineTextAlignment(.center)
            HStack(spacing: 24) {
                ForEach(Array(["Try Again", "Open in Safari", "Home"].enumerated()), id: \.offset) { index, label in
                    Button(label) { tv.performPlayerRecovery(index) }
                        .buttonStyle(.plain).font(.tvMenuItem).padding(24)
                        .foregroundStyle(tv.playerFailure?.selected == index ? .black : .white)
                        .background(tv.playerFailure?.selected == index ? .white : .white.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(60).frame(width: 1280).tvGlass(in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SheetBackdrop())
    }
}
