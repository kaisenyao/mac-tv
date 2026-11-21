import SwiftUI

/// Mac TV's own Search, over Home (and over apps without a search of their own): what's on this Mac only, the apps,
/// Settings' rows and the Movies library, listed as you type. Control Center's Search opens it with the field
/// highlighted (so does a press of the Siri button while Jasmine is off); the Siri button then dictates into it.
/// Online content isn't searched here: 哔哩哔哩 and 网易云 have their own search.
struct SystemSearch: Equatable {
    var query = ""
    /// The keyboard (or the phone's Type on TV) types into the field.
    var typing = false
    /// 0 is the field; results follow from 1.
    var row = 0
    var presses = 0
}

/// One thing Search found.
enum SystemSearchResult: Hashable {
    case app(String)
    case setting(SettingsPanel.Row)
    case movie(String)
    case show(String)
}

extension TVController {
    func openSystemSearch() {
        sheets.search = SystemSearch()
    }

    var systemSearch: SystemSearch? {
        get { sheets.search }
        set { sheets.search = newValue }
    }

    /// A click on Search's field: typing in it at once, as on any Mac (no Select first).
    func typeInSystemSearch() {
        guard systemSearch != nil else { return }
        systemSearch?.row = 0
        systemSearch?.typing = true
    }

    /// What the query finds, apps first, then Settings, then Movies; a few of each.
    func systemSearchResults(_ query: String) -> [(group: String, results: [SystemSearchResult])] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let matches = { (text: String) in text.localizedStandardContains(query) }
        let apps = services.filter { $0.kind != .addApp && matches($0.name) }.prefix(6).map { SystemSearchResult.app($0.id) }
        let settings = SettingsPanel.Section.allCases.flatMap { section in
            section.rows.map { (section, $0) }
        }.filter { section, row in
            matches(settingsContent(row, panel: SettingsPanel(section: section, open: true), focused: false).title)
        }.map(\.1).reduce(into: [SettingsPanel.Row]()) { if !$0.contains($1) { $0.append($1) } }   // a row in two sections once
            .prefix(6).map { SystemSearchResult.setting($0) }
        let shows = movieLibrary.shows.filter { matches($0.title) }.prefix(6).map { SystemSearchResult.show($0.id) }
        let films = movieLibrary.films.filter { matches($0.title) }.prefix(6).map { SystemSearchResult.movie($0.path) }
        return [("APPS", Array(apps)), ("SETTINGS", Array(settings)), ("MOVIES", Array(shows + films).prefix(8).map { $0 })]
            .filter { !$0.results.isEmpty }
    }

    func systemSearchList(_ query: String) -> [SystemSearchResult] { systemSearchResults(query).flatMap(\.results) }

    func systemSearchContent(_ result: SystemSearchResult) -> SettingsRowContent {
        switch result {
        case .app(let id):
            return SettingsRowContent(title: services.first { $0.id == id }?.name ?? id, value: "App", accessory: .chevron,
                                      symbol: "app.fill")
        case .setting(let row):
            let section = SettingsPanel.Section.allCases.first { $0.rows.contains(row) } ?? .general
            let title = settingsContent(row, panel: SettingsPanel(section: section, open: true), focused: false).title
            return SettingsRowContent(title: title, value: section.title, accessory: .chevron, symbol: "gearshape.fill")
        case .movie(let path):
            return SettingsRowContent(title: movieLibrary.movie(path)?.title ?? "", value: "Movie", accessory: .chevron,
                                      symbol: "film.fill")
        case .show(let id):
            return SettingsRowContent(title: movieLibrary.show(id)?.title ?? "", value: "TV Show", accessory: .chevron,
                                      symbol: "tv.fill")
        }
    }

    /// Presses on Search. On the field: Select starts typing; letters, Delete and Left / Right edit; Down goes to
    /// the results. On a result: Select opens it. Back stops typing, then closes Search.
    func handleSystemSearch(_ command: RemoteCommand) {
        guard var search = systemSearch else { return }
        let results = systemSearchList(search.query)
        switch command {
        case .back:
            if search.typing { search.typing = false } else { return closeSystemSearch() }
        case .text, .deleteBackward:
            // The phone's Type on TV and dictation (the keyboard types into the field itself)
            search.row = 0
            search.typing = true
            TextEntry.apply(command, to: &search.query, limit: Self.searchLimit)
            if case .text(let text) = command, text.hasSuffix("\n") { search.typing = false }
        case .move(.left), .move(.right):
            break   // the field's own caret
        case .move(.down):
            if search.row < results.count { search.row += 1; search.typing = false }
        case .move(.up):
            if search.row > 0 { search.row -= 1 }
        case .select:
            search.presses += 1
            if search.row == 0 {
                search.typing = true
            } else if results.indices.contains(search.row - 1) {
                systemSearch = search
                return openSearchResult(results[search.row - 1])
            }
        default:
            break
        }
        search.row = min(search.row, results.count)
        systemSearch = search
    }

    static let searchLimit = 120

    func closeSystemSearch() {
        withAnimation(Motion.appear) { sheets.search = nil }
    }

    func openSearchResult(_ result: SystemSearchResult) {
        sheets.search = nil
        switch result {
        case .app(let id): if let service = services.first(where: { $0.id == id }) { open(service) }
        case .setting(let row): openSettings(to: row)
        case .movie(let path):
            openMovies()
            openMoviePage(.movie(path))
        case .show(let id):
            openMovies()
            openMoviePage(.show(id))
        }
    }
}

/// Search's sheet: the field at the top, the results under it in groups.
struct SystemSearchSheet: View {
    @ObservedObject var tv: TVController
    @Namespace private var focusSpace

    var body: some View {
        let search = tv.systemSearch ?? SystemSearch()
        let groups = tv.systemSearchResults(search.query)
        VStack(spacing: 40) {
            // Typing: white with dark text and a caret, as every field on the TV (Add App's, 哔哩哔哩's search), so it
            // can't be missed; on the field but not typing: its white outline. A click on it types at once.
            let typing = search.row == 0 && search.typing
            TVTextField(text: Binding(get: { tv.systemSearch?.query ?? "" }, set: { tv.systemSearch?.query = $0 }),
                        placeholder: "Search", editing: typing,
                        limit: TVController.searchLimit) { tv.systemSearch?.typing = false }
                .font(.tv(.headline, emphasized: true))
                .foregroundStyle(typing ? .black : .white)
                .padding(.trailing, 50)
                .padding(.horizontal, 40)
                .frame(width: 900, height: 84, alignment: .leading)
                .background(typing ? .white : .white.opacity(search.row == 0 ? 0.14 : 0.07), in: Capsule())
                .overlay(PillOutline().strokeBorder(.white.opacity(typing ? 0 : search.row == 0 ? 0.85 : 0.12),
                                                    lineWidth: search.row == 0 ? 3 : 1))
                .overlay(alignment: .trailing) {
                    Image(systemName: "magnifyingglass").font(.tv(.headline)).opacity(0.5).padding(.trailing, 34)
                }
                .environment(\.colorScheme, typing ? .light : .dark)   // a dark caret on the white field
                .contentShape(Capsule())
                .onTapGesture { tv.typeInSystemSearch() }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    let start = groups[..<index].reduce(0) { $0 + $1.results.count }
                    Text(group.group).font(.tv(.caption2, emphasized: true)).tracking(1.6).opacity(0.5)
                        .padding(.top, index == 0 ? 0 : 18).padding(.leading, 24)
                    ForEach(Array(group.results.enumerated()), id: \.element) { offset, result in
                        let focused = search.row == start + offset + 1
                        SettingsRow(content: tv.systemSearchContent(result), focused: focused, presses: focused ? search.presses : 0,
                                    focusSpace: focusSpace) {
                            tv.openSearchResult(result)
                        }
                        .equatable()
                    }
                }
            }
            .frame(width: SettingsMetrics.listWidth)
            Spacer(minLength: 0)
        }
        .padding(.top, 120)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.focus, value: search)
    }
}
