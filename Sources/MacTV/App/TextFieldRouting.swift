import AppKit
import Carbon.HIToolbox
import SwiftUI

extension TVController {
    /// A TVTextField has the keyboard: the system Search's field, a Settings field (a name, a form, an API key),
    /// "Who's Watching?"'s new name, an Add App field, or a field of Movies' Add Network Share…. While it does, the
    /// keyboard's keys are the field's own (main.swift), so input methods can compose in it.
    var tvTextFieldEditing: Bool {
        switch sheets.top {
        case .search: return systemSearch?.row == 0 && systemSearch?.typing == true
        case .settings, .pairing, .setup: return pages?.typing == true && pages?.form.connecting != true
        case .profilePicker: return profilePicker?.naming != nil
        case .addApp:
            guard let adder else { return false }
            switch adder.tab {
            case .website: return (1...2).contains(adder.row)
            case .macApp: return adder.row == 1
            case .steam: return false
            }
        case nil:
            guard mode == .launcher, let form = movies?.shareForm else { return false }
            return form.row < 3 && !form.connecting
        default: return false
        }
    }
}

/// Which keys a TVTextField keeps while it has the keyboard (main.swift's keyDown monitor asks). Everything a text
/// field does is its own: letters, Space, Return, Delete and ⌥⌫, Left and Right, ⌥ and ⌘ with the arrows, and the
/// Edit menu's ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z and ⇧⌘Z (Mac TV's main menu sends those to the field). Only Up and Down, with no
/// modifier and no input method composing, are the TV's: to the next field, to the results.
enum TextFieldKeys {
    static func belongToField(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool) -> Bool {
        let upOrDown = keyCode == 125 || keyCode == 126
        return !(upOrDown && modifiers.isEmpty && !composing)
    }

    /// The field's row has focus but the field hasn't the keyboard (a click took it): Up, Down and Return still move
    /// on, as from the field; any other key gives the field the keyboard back.
    static func navigateWithoutKeyboard(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.isEmpty && [125, 126, 36, 76].contains(keyCode)
    }
}

/// Whether a click ends the typing in a text field: only one outside the field being typed in.
enum TextEditingClicks {
    static func endsTyping(typing: Bool, insideEditor: Bool) -> Bool { typing && !insideEditor }
}

extension TVController {
    /// Some screen's text field is being typed in (its own state; the keyboard may or may not be in it yet).
    var typingInAField: Bool {
        tvTextFieldEditing || (bilibiliOpen && bilibiliStore.editing) || neteaseStore.typing || browserStore.editing
            || movies?.typing == true
    }

    /// Typing ends (a click outside the field): each screen goes back to its non-typing focus on that field, and the
    /// keyboard leaves it. Settings', "Who's Watching?"'s and Add App's fields keep focus on their row, so the click's
    /// own target (another row, another field) decides where it goes next; the field just lets the keyboard go.
    func endTextEditing() {
        if browserStore.editing { browserStore.endEditingByClick() }
        if bilibiliStore.editing { bilibiliStore.stopEditing() }
        if neteaseStore.typing { neteaseStore.stopEditing() }
        if movies?.typing == true { withAnimation(Motion.focus) { movies?.typing = false } }
        if systemSearch?.typing == true { systemSearch?.typing = false }
        window?.makeFirstResponder(nil)
    }
}

/// The keyboard's Siri button: F5 (the 🎤 key on a Mac keyboard, with fn or as a standard function key), alone. main.swift
/// asks this first in both its keyDown and keyUp monitors, before the window check and before any text field gets
/// the key, so the Siri button works over a web page, a video and a field being typed in alike. (`modifiers` without
/// fn: AppKit marks every function key with it.)
enum SiriKey {
    static func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == UInt16(kVK_F5) && modifiers.subtracting([.function, .numericPad, .capsLock, .help]).isEmpty
    }
}
