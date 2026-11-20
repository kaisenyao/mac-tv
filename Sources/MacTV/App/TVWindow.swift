import AppKit

/// Mac TV's window. Its full screen is TV mode's alone (see TVMode): an Escape nothing else wanted doesn't take it
/// out of full screen, as AppKit's NSWindow would. Back sends Escape into web pages that move with their own keys
/// (YouTube's TV page); one the page lets through means the page is at its top level, and `unhandledCancel` takes
/// it from there (TVController.pageLetBackThrough). Mac TV's own Esc key never gets here: the key monitor in
/// main.swift takes it first.
final class TVWindow: NSWindow {
    var unhandledCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        unhandledCancel?()
    }
}
