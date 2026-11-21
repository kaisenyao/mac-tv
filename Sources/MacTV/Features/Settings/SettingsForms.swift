import SwiftUI

/// Add Network Share… or Sign In to Jellyfin… in Settings › Apps › Movies: the server, a user name and a password,
/// added to the same stores as the Movies app's own form. The password goes only where that form sends it: the
/// share's Keychain item, or the Jellyfin server.
struct SourceForm: Equatable, CustomDebugStringConvertible {
    /// The text fields, top to bottom; Connect or Sign In follows them.
    static let fields: [SettingsPanel.Row] = [.formAddress, .formUser, .formPassword]

    var address = ""
    var user = ""
    var password = ""
    /// Why the share or server couldn't be added.
    var message: String?
    var connecting = false

    subscript(field: SettingsPanel.Row) -> String {
        get {
            switch field {
            case .formUser: user
            case .formPassword: password
            default: address
            }
        }
        set {
            switch field {
            case .formUser: user = newValue
            case .formPassword: password = newValue
            default: address = newValue
            }
        }
    }

    /// Wherever the form is described (the sheets compared for the navigation sounds, say), never the password.
    var debugDescription: String {
        "SourceForm(address: \(address.debugDescription), user: \(user.debugDescription), password: \(password.count) characters, "
            + "message: \(message ?? "none"), connecting: \(connecting))"
    }
}

extension TVController {
    /// A form's rows: each field with its label and what's typed, then Connect or Sign In.
    func formContent(_ row: SettingsPanel.Row, panel: SettingsPanel, focused: Bool) -> SettingsRowContent {
        let jellyfin = panel.page == .addJellyfinServer, form = panel.form
        let editing = focused && !form.connecting
        /// The field's own text field: typing goes into the form, Return goes on (as Select).
        func field(_ text: String, _ placeholder: String, secure: Bool = false) -> SettingsRowContent.Field {
            let index = SourceForm.fields.firstIndex(of: row) ?? 0
            return .init(text: text, placeholder: placeholder, editing: editing, secure: secure,
                         set: { [weak self] in self?.pages?.form[row] = $0 },
                         submit: { [weak self] in self?.pressFormRow(index) })
        }
        switch row {
        case .formAddress:
            return SettingsRowContent(title: "Server", field: field(form.address, "Required"))
        case .formUser:
            return SettingsRowContent(title: "User Name", field: field(form.user, jellyfin ? "Required" : "Optional"))
        case .formPassword:
            return SettingsRowContent(title: "Password", field: field(form.password, "Optional", secure: true))
        default:
            let title = switch (jellyfin, form.connecting) {
            case (true, true): "Signing In…"
            case (true, false): "Sign In"
            case (false, true): "Connecting…"
            case (false, false): "Connect"
            }
            return SettingsRowContent(title: title)
        }
    }

    /// Presses on a form: Up and Down move between the fields and the button (the keyboard types into the field with
    /// focus itself, a TVTextField; the phone's Type on TV comes here), and Select goes on to the next field (from the password, or on the button, it adds the source). Back closes the
    /// form; while it's connecting that's the only press that does anything, and the share keeps trying.
    func typeInForm(_ command: RemoteCommand, _ panel: SettingsPanel) {
        var panel = panel
        let fields = SourceForm.fields
        if case .back = command {
            closeSettingsPage(&panel)
            pages = panel
            return
        }
        guard !panel.form.connecting else { return }
        panel.form.message = nil
        switch command {
        case .move(let direction) where direction == .up || direction == .down:
            let next = min(max(panel.row + (direction == .up ? -1 : 1), 0), fields.count)
            if next != panel.row { panel.row = next }
        case .move:
            break   // Left and Right are the text field's own
        case .deleteBackward, .text:
            if panel.row < fields.count {
                var text = panel.form[fields[panel.row]]
                if TextEntry.apply(command, to: &text) { panel.form[fields[panel.row]] = text }
            }
            if case .text(let typed) = command, typed.hasSuffix("\n") {
                pages = panel
                pressFormRow(panel.row)
                return
            }
        case .select:
            panel.presses += 1
            pages = panel
            pressFormRow(panel.row)
            return
        default:
            break
        }
        pages = panel
    }

    /// A click on a field: focus goes to it.
    func focusFormField(_ row: SettingsPanel.Row) {
        guard let panel = pages, !panel.form.connecting, let index = SourceForm.fields.firstIndex(of: row) else { return }
        pages?.row = index
    }

    /// Select on a field goes on to the next one; on the password, or on Connect or Sign In, it adds the source.
    func pressFormRow(_ index: Int) {
        guard var panel = pages, !panel.form.connecting else { return }
        let fields = SourceForm.fields
        if index < fields.count - 1 {
            panel.row = index + 1
            pages = panel
            return
        }
        panel.row = fields.count   // focus waits on Connect or Sign In
        pages = panel
        submitSourceForm()
    }

    /// Adds the share and waits for it to connect, or signs in to the Jellyfin server: back on Movies, on the new
    /// source, once it's there, or the reason it isn't under the form.
    private func submitSourceForm() {
        guard let panel = settings else { return }
        let form = panel.form
        switch panel.page {
        case .addNetworkShare:
            guard let share = networkShares.add(address: form.address, user: form.user, password: form.password) else {
                settings?.form.message = form.address.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Type the shared folder's address first." : "Use an address like nas.local/Movies."
                return
            }
            settings?.form.connecting = true
            let shares = networkShares
            Task { @MainActor [weak self] in
                // macOS gives up on an unreachable server after about a minute.
                for _ in 0..<150 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, self.settings?.page == .addNetworkShare, self.settings?.form.connecting == true else { return }
                    switch shares.status[share.id] {
                    case .connected:
                        self.finishSourceForm(on: .networkShare(share.id))
                        return
                    case .offline(let reason):
                        self.settings?.form.connecting = false
                        self.settings?.form.message = reason
                        return
                    default:
                        continue
                    }
                }
            }
        case .addJellyfinServer:
            settings?.form.connecting = true
            let jellyfin = jellyfin
            Task { @MainActor [weak self] in
                let error = await jellyfin.signIn(address: form.address, user: form.user, password: form.password)
                guard let self, self.settings?.page == .addJellyfinServer, self.settings?.form.connecting == true else { return }
                if let error {
                    self.settings?.form.connecting = false
                    self.settings?.form.message = error
                } else {
                    self.finishSourceForm(on: jellyfin.servers.last.map { .jellyfinServer($0.id) })
                }
            }
        default:
            return
        }
    }

    /// The source is in Movies: the form closes, with focus on the new share or server.
    private func finishSourceForm(on row: SettingsPanel.Row?) {
        guard var panel = settings else { return }
        closeSettingsPage(&panel)
        if let row, let index = settingsRows(panel).firstIndex(of: row) { panel.row = index }
        settings = panel
    }
}
