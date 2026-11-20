import SwiftUI

/// Connect a Remote, shown at launch while there's no remote at all and from Control Center: Settings › Remotes
/// and Devices on a sheet of its own (the same pages, drawn by `SettingsPages`). The phone's code is on the
/// iPhone page. Back on the first page closes it.
struct PairSheet: View {
    @ObservedObject var tv: TVController

    /// System Settings › Bluetooth, where a Siri Remote or game controller is paired.
    static func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { SystemGuard.open(url) }
    }

    var body: some View {
        SettingsPages(tv: tv, panel: tv.connectRemote)
            .onAppear { tv.remoteCoordinator.refreshRemoteStatus() }
    }
}

extension TVController {
    /// Presses on Connect a Remote go through Settings' pages, which act on the sheet on top.
    func handlePairing(_ command: RemoteCommand) { handleSettings(command) }
}

/// The top of the iPhone page: the code to scan with the phone's camera, where it opens, and the pairing code
/// to type. Phone Access below switches them to a guest's.
struct PhonePairingCodes: View {
    @ObservedObject var tv: TVController

    var body: some View {
        let links = tv.pairingGuest ? tv.remoteGuestLinks : tv.remoteLinks
        HStack(alignment: .top, spacing: 36) {
            if links.isEmpty {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.08))
                    .frame(width: 240, height: 240)
                    .overlay(Text("Connect to Wi-Fi\nor Tailscale").multilineTextAlignment(.center).font(.tv(.caption2)).opacity(0.6))
            }
            ForEach(links) { link in
                VStack(alignment: .leading, spacing: 6) {
                    if let qr = link.qr {
                        Image(nsImage: qr).interpolation(.none).resizable()
                            .frame(width: 208, height: 208)
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .padding(.bottom, 10)
                    }
                    Text(link.label).font(.tv(.caption1, emphasized: true))
                    // The address to type: the Mac's IP when the code uses its name.
                    Text(link.fallback ?? link.address.replacingOccurrences(of: "http://", with: ""))
                        .font(.tv(.caption2)).monospacedDigit().opacity(0.55)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Pairing Code").font(.tv(.caption1)).opacity(0.55)
                Text(tv.pairingGuest ? tv.remoteGuestToken : tv.remoteToken)
                    .font(.system(size: 52, weight: .semibold)).monospacedDigit().tracking(4)
                    .contentTransition(.numericText())
            }
            .padding(.top, 4)
        }
        .padding(.leading, 6)
        .animation(Motion.focus, value: tv.pairingGuest)
    }
}
