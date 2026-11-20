import SwiftUI

/// Connect a Remote: the phone (scan the code), a Siri Remote or a game controller (Bluetooth).
struct PairSheet: View {
    @Environment(\.canvasSize) private var canvas
    @ObservedObject var tv: TVController
    @ObservedObject private var siriRemote = SiriRemoteStatus.shared

    /// System Settings › Bluetooth, where a Siri Remote or game controller is paired.
    static func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        let links = tv.pairingGuest ? tv.remoteGuestLinks : tv.remoteLinks
        HStack(alignment: .center, spacing: 52) {
            // Top-aligned, so the codes stay level when one has an address to type under it.
            HStack(alignment: .top, spacing: 24) {
                if links.isEmpty {
                    RoundedRectangle(cornerRadius: 28).fill(.white.opacity(0.1))
                        .frame(width: 300, height: 300)
                        .overlay(Text("Connect to Wi-Fi\nor Tailscale").multilineTextAlignment(.center)
                            .font(.tv(.caption2)).opacity(0.7))
                }
                ForEach(links) { link in
                    VStack(spacing: 14) {
                        if let qr = link.qr {
                            Image(nsImage: qr).interpolation(.none).resizable()
                                .frame(width: 260, height: 260)
                                .padding(20)
                                .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        }
                        Text(link.label).font(.tv(.caption2)).opacity(0.8)
                        if let fallback = link.fallback {
                            Text("or open \(fallback)").font(.tv(.caption2)).monospacedDigit().opacity(0.5)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect a Remote").font(.tv(.title3, emphasized: true))
                Text("Pairing Code \(tv.pairingGuest ? tv.remoteGuestToken : tv.remoteToken)")
                    .font(.tv(.caption2)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                VStack(alignment: .leading, spacing: 12) {
                    status("iphone", "iPhone", tv.phonePaired ? "Connected" : "Not Connected", on: tv.phonePaired)
                    status("appletvremote.gen4.fill", "Siri Remote", siriRemote.connected ? "Connected" : "Not Connected",
                           on: siriRemote.connected)
                    status("gamecontroller.fill", "Game Controller", tv.controller?.name ?? "Not Connected", on: tv.controller != nil)
                }
                .padding(.top, 6)
                VStack(spacing: 10) {
                    pairRow("Phone Access", value: tv.pairingGuest ? "Guest (24 Hours)" : "Full Access",
                            focused: tv.pairingFocusedRow == .access) { tv.pairingGuest.toggle() }
                    if tv.pairingRows.contains(.display) {
                        let displays = tv.availableTVDisplays
                        pairRow("Display", value: (displays.first(where: \.current) ?? displays.first)?.name,
                                focused: tv.pairingFocusedRow == .display) { tv.stepPairingDisplay() }
                    }
                    pairRow("Bluetooth Settings…", focused: tv.pairingFocusedRow == .bluetooth) { Self.openBluetoothSettings() }
                    pairRow("Show at Launch", value: tv.preferences.showPairingAtLaunch ? "On" : "Off",
                            focused: tv.pairingFocusedRow == .showAtLaunch) {
                        tv.preferences.showPairingAtLaunch.toggle()
                    }
                }
                .padding(.top, 8)
                ShelfButton(title: "Done", focused: tv.pairingFocusedRow == .done, glass: false) { tv.pairing = false }
                    .padding(.top, 10)
                if !siriRemote.connected {
                    Text("To pair a Siri Remote, press and hold Back and Volume Up for 5 seconds, then choose it in Bluetooth Settings.")
                        .font(.tv(.caption2)).foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(56)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
    }

    /// One kind of remote and whether it's connected. Not a control: focus skips it.
    private func status(_ symbol: String, _ title: String, _ detail: String, on: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 24, weight: .medium)).frame(width: 34)
            Text(title)
            Spacer(minLength: 16)
            Text(detail).opacity(on ? 0.9 : 0.5)
            if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
        .font(.tv(.callout))
        .padding(.horizontal, 26)
        .accessibilityElement(children: .combine)
    }

    /// A row on the frosted sheet: a plain fill at rest, the white platter with dark text when focused.
    private func pairRow(_ title: String, value: String? = nil, focused: Bool,
                         action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 16) {
                Text(title).lineLimit(1)
                Spacer(minLength: 16)
                if let value { Text(value).opacity(0.6) }
            }
            .font(.tv(.callout))
            .padding(.horizontal, 26)
            .frame(height: 66)
            .foregroundStyle(focused ? .black : .white)
            .background { if !focused { shape.fill(.white.opacity(0.07)) } }
            .focusPlatter(shape, focused: focused, glass: false)
            .scaleEffect(focused ? 1.03 : 1)
            .animation(Motion.focus, value: focused)
        }
        .buttonStyle(.plain)
    }
}
