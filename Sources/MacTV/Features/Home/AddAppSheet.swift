import SwiftUI

struct AddAppSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace

    var body: some View {
        let a = tv.adder ?? AppAdder()
        VStack(alignment: .leading, spacing: 26) {
            Text("Add App").font(.tv(.title3, emphasized: true))

            HStack(spacing: 6) {
                tab("Website", .website, a)
                tab("Mac App", .macApp, a)
                if tv.adderTabs.contains(.steam) { tab("Steam", .steam, a) }
            }
            .padding(6)
            .background(.white.opacity(a.row == 0 ? 0.22 : 0.08), in: Capsule())
            .scaleEffect(a.row == 0 ? 1.03 : 1)

            if a.tab == .website {
                AdderField(label: "Website", text: binding(\.address), placeholder: "e.g. crunchyroll.com", focused: a.row == 1,
                           submit: submit) { set(row: 1) }
                AdderField(label: "Name", text: binding(\.name), placeholder: "Optional", focused: a.row == 2, submit: submit) { set(row: 2) }
                ShelfButton(title: "Add to Home Screen", systemImage: "plus", focused: a.row == 3, glass: false) {
                    set(row: 3)
                    tv.submitAdder()
                }
            } else if a.tab == .macApp {
                AdderField(label: "Search", text: binding(\.query), placeholder: "App Name", focused: a.row == 1, submit: submit) { set(row: 1) }
                macList(a)
            } else {
                steamList(a)
            }

            if let message = a.message {
                Text(message)
                    .font(.tv(.caption2, emphasized: true))
                    .foregroundStyle(Color(hex: "#FF8A80"))
            }
        }
        .padding(56)
        .frame(width: 1100, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: a)
    }

    private func set(row: Int) {
        tv.adder?.row = row
    }

    /// A field's text, typed into by its text field.
    private func binding(_ field: WritableKeyPath<AppAdder, String>) -> Binding<String> {
        Binding(get: { tv.adder?[keyPath: field] ?? "" }, set: { tv.adder?[keyPath: field] = $0; if field == \.query { tv.adder?.selected = 0 } })
    }

    /// Return in a field: as Select there (the next field, or Add).
    private func submit() { tv.handle(.select) }

    private func tab(_ title: String, _ tab: AppAdder.Tab, _ a: AppAdder) -> some View {
        let on = a.tab == tab
        return Text(title)
            .font(.tv(.caption1, emphasized: true))
            .padding(.horizontal, 30)
            .frame(height: 54)
            .foregroundStyle(on ? .black : .white)
            .background {
                if on { Capsule().fill(.white).matchedGeometryEffect(id: "tab", in: focusSpace) }
            }
            .contentShape(Capsule())
            .onTapGesture {
                tv.adder?.tab = tab
                tv.adder?.row = 1
                tv.adder?.selected = 0
            }
    }

    /// Steam Big Picture and the installed games, eight rows at a time. Games launch through Steam.
    @ViewBuilder private func steamList(_ a: AppAdder) -> some View {
        let games = tv.adderSteamGames
        let window = 8
        let start = min(max(0, a.selected - window / 2), max(0, games.count - window))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(games.enumerated().dropFirst(start).prefix(window)), id: \.element.appID) { index, game in
                let focused = a.row == 1 && a.selected == index
                let added = tv.isOnHomeScreen(game)
                HStack(spacing: 18) {
                    Group {
                        if game == SteamLibrary.bigPicture, let url = SteamLibrary.appURL {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                        } else {
                            Image(systemName: "gamecontroller.fill").font(.system(size: 24)).frame(width: 44, height: 44)
                        }
                    }
                    .frame(width: 44, height: 44)
                    Text(game.name).font(.tv(.body)).lineLimit(1)
                    Spacer()
                    if added { Text("Added").font(.tv(.caption2, emphasized: true)).opacity(0.6) }
                }
                .padding(.horizontal, 18)
                .frame(height: 60)
                .foregroundStyle(focused ? .black : .white)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                    if focused {
                        shape.fill(.white).matchedGeometryEffect(id: "focus", in: focusSpace)
                    } else {
                        shape.fill(.white.opacity(0.06))
                    }
                }
                .opacity(added && !focused ? 0.55 : 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    tv.adder?.row = 1
                    tv.adder?.selected = index
                    tv.addSelectedSteamGame()
                }
            }
            if games.count == 1 {
                Text("No Steam Games")
                    .font(.tv(.caption2)).opacity(0.6).padding(.top, 6)
            }
        }
    }

    /// Eight rows at a time, scrolled to keep the highlighted app in view.
    @ViewBuilder private func macList(_ a: AppAdder) -> some View {
        let matches = tv.adderMatches
        let window = 8
        let start = min(max(0, a.selected - window / 2), max(0, matches.count - window))
        VStack(spacing: 6) {
            if matches.isEmpty {
                Text("No Results").font(.tv(.caption1)).opacity(0.6)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
            ForEach(Array(matches.enumerated().dropFirst(start).prefix(window)), id: \.element.bundleID) { index, app in
                let focused = a.row == 2 && a.selected == index
                let added = tv.isOnHomeScreen(app)
                HStack(spacing: 18) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().frame(width: 44, height: 44)
                    Text(app.name).font(.tv(.body)).lineLimit(1)
                    Spacer()
                    if added {
                        Text("Added").font(.tv(.caption2, emphasized: true)).opacity(0.6)
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 60)
                .foregroundStyle(focused ? .black : .white)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                    if focused {
                        shape.fill(.white).matchedGeometryEffect(id: "focus", in: focusSpace)
                    } else {
                        shape.fill(.white.opacity(0.06))
                    }
                }
                .opacity(added && !focused ? 0.55 : 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    tv.adder?.row = 2
                    tv.adder?.selected = index
                    tv.addSelectedMacApp()
                }
            }
        }
    }
}

/// A labelled text field on a sheet (Add App, Movies' Add Network Share…): a real one (TVTextField) while it has
/// focus, white like a field being typed in.
struct AdderField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let focused: Bool
    var secure = false
    var submit: () -> Void = {}
    let tap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.tv(.caption2, emphasized: true)).tracking(1).textCase(.uppercase).opacity(0.6)
            TVTextField(text: $text, placeholder: placeholder, editing: focused, secure: secure, onSubmit: submit)
                .font(.tv(.body))
                .padding(.horizontal, 24)
                .frame(height: 72)
                .foregroundStyle(focused ? .black : .white)
                .background(focused ? .white : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .environment(\.colorScheme, focused ? .light : .dark)   // a dark caret on the white field
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }
}
