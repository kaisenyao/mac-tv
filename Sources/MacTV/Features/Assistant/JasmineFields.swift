import SwiftUI

/// The text field the Siri button dictates into: the one with focus, being typed in or only highlighted
/// ("with a text entry field highlighted onscreen", Apple's dictation). Secure fields (passwords, API keys) never
/// get dictation: nothing they'd hear may go to a cloud service.
enum DictationField: Equatable {
    case systemSearch, bilibiliSearch, neteaseSearch, neteaseName, browserAddress, moviesSearch
    case settingsName, settingsForm, appAdder, profileName, moviesShareForm
    case secure

    var isSecure: Bool { self == .secure }
}

extension TVController {
    /// The field that has focus now, if any. Only Mac TV's own screens: a web page's fields aren't known here.
    var dictationField: DictationField? {
        if let panel = pages, sheets.top == .settings || sheets.top == .pairing || sheets.top == .setup {
            guard panel.typing else { return nil }
            switch panel.page {
            case .jasmine(.key): return .secure
            case .addNetworkShare, .addJellyfinServer:
                return SourceForm.fields.indices.contains(panel.row) && SourceForm.fields[panel.row] == .formPassword
                    ? .secure : .settingsForm
            default: return .settingsName
            }
        }
        if let adder, sheets.top == .addApp {
            switch adder.tab {
            case .website: return (1...2).contains(adder.row) ? .appAdder : nil
            case .macApp: return adder.row == 1 ? .appAdder : nil
            case .steam: return nil
            }
        }
        if profilePicker?.naming != nil, sheets.top == .profilePicker { return .profileName }
        if let search = systemSearch, sheets.top == .search { return search.row == 0 ? .systemSearch : nil }
        guard sheets.top == nil, mode == .launcher else {
            if browserPageInFront, browserStore.editing { return .browserAddress }
            return nil
        }
        if let movies {
            if let form = movies.shareForm { return form.row == 2 ? .secure : form.row < 2 ? .moviesShareForm : nil }
            return movies.section == .search && (movies.typing || movies.focus == .header) ? .moviesSearch : nil
        }
        if bilibiliOpen, !bilibiliStore.player.showing, bilibiliStore.editing || bilibiliStore.searchFocused { return .bilibiliSearch }
        if neteaseOpen {
            if neteaseStore.naming != nil { return .neteaseName }
            if neteaseStore.editing || neteaseStore.topFocus == .search { return .neteaseSearch }
        }
        if browserOpen, browserStore.editing || browserStore.focus == .field { return .browserAddress }
        return nil
    }

    /// Dictated text into the field with focus: the same as typing it on the phone (`.text`), so every field takes it
    /// its own way. A field only highlighted starts typing first, as Select would.
    func dictate(_ text: String, into field: DictationField) {
        guard !field.isSecure, !text.isEmpty, dictationField == field else { return }
        switch field {
        case .systemSearch:
            return handleSystemSearch(.text(text))
        case .browserAddress where !browserStore.editing:
            browserStore.startEditing()
        case .moviesSearch where movies?.typing == false:
            movies?.typing = true
        case .neteaseSearch where !neteaseStore.editing:
            neteaseStore.focusSearch(typing: true)
        default:
            break
        }
        handle(.text(text))
    }

    /// The Siri button pressed: the search of the app in front, ready for a hold to dictate into it. An app
    /// without a search of its own (and Home) opens the system Search. A video playing full screen keeps playing.
    func openSearchForSiri() {
        guard sheets.top == nil else { return }
        switch mode {
        case .launcher:
            if let movies {
                guard movies.shareForm == nil else { return }
                tapMovieSidebar(.search)
            } else if bilibiliOpen {
                guard !bilibiliStore.player.showing else { return }
                bilibiliStore.focusSearch()
            } else if neteaseOpen {
                neteaseStore.focusSearch(typing: false)
            } else if browserOpen {
                browserStore.startEditing()
            } else {
                openSystemSearch()   // Home, 得到
            }
        case .player:
            if browserPageInFront { browserStore.startEditingInBar() } else { openSystemSearch() }
        case .movie:
            break
        }
    }
}
