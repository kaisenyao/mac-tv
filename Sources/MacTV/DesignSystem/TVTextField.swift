import SwiftUI

/// The one text field for typing on the TV (Search, Settings' names, forms and keys, "Who's Watching?", Add App).
///
/// While it's `editing` it's a real macOS text field: input methods compose in it (pinyin's marked text and its
/// candidates), ⌘V pastes, Delete deletes, and the caret is the system's thin one, which takes no room and keeps
/// itself in view in a long text. Otherwise it's the same text drawn, the placeholder dimmed. It takes the font and
/// colour around it. What the keys do around it is main.swift's: while it has the keyboard the keys are its own,
/// apart from Up and Down (the TV's navigation, unless an input method is composing) and Esc (Back, unless composing).
/// Return is its own: it ends a composition, or submits.
///
/// The phone's Type on TV and dictation still arrive as `.text` and change the bound text where the field's owner
/// handles them (TextEntry), so the field shows them at once.
struct TVTextField: View {
    @Binding var text: String
    let placeholder: String
    /// Has the keyboard.
    let editing: Bool
    /// A password or an API key: dots, no input method, and never dictated (see DictationField).
    var secure = false
    var limit = Int.max
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool
    @ObservedObject private var focus = TVTextFieldFocus.shared

    var body: some View {
        if editing {
            field
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSubmit)
                .onAppear { focused = true }   // the keyboard as soon as it shows (a change alone can miss it)
                .onChange(of: focus.requests) { _, _ in focused = true }
                .onChange(of: text) { _, typed in
                    if typed.count > limit { text = String(typed.prefix(limit)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text.isEmpty ? placeholder : secure ? String(repeating: "•", count: text.count) : text)
                .opacity(text.isEmpty ? 0.4 : 1)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var field: some View {
        if secure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

/// Asks the field that's editing to take the keyboard again: it didn't get it as it appeared, or something took it.
@MainActor
final class TVTextFieldFocus: ObservableObject {
    static let shared = TVTextFieldFocus()
    @Published private(set) var requests = 0
    func request() { requests += 1 }
}

/// Typed text from the phone (Type on TV) and from dictation, into a field's text: at the end, as the system field's
/// caret is there when it's typed into from outside. Delete takes the last character out. A Return at the end of
/// what's typed isn't typed (the owner may take it as Done).
enum TextEntry {
    /// True when the text changed.
    @discardableResult
    static func apply(_ command: RemoteCommand, to text: inout String, limit: Int = .max) -> Bool {
        switch command {
        case .text(let typed):
            let added = String(typed.filter { $0 != "\n" && $0 != "\r" }.prefix(max(0, limit - text.count)))
            guard !added.isEmpty else { return false }
            text += added
            return true
        case .deleteBackward:
            guard !text.isEmpty else { return false }
            text.removeLast()
            return true
        default:
            return false
        }
    }
}
