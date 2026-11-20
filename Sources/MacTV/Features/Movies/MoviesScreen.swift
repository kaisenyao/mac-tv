import AppKit
import SwiftUI

/// The Movies app's screen: Continue Watching, then every movie in the chosen folders as
/// posters, driven by the D-pad like the rest of the TV, and a Settings button at the top for the Folders sheet.
struct MoviesBrowser: Equatable {
    var row = 0
    var column = 0
    /// Focus is on the Settings button, above the top row.
    var settingsFocused = false
    /// The Folders sheet, and its focused row.
    var folderRow: Int?
    /// Adding a network share or a Jellyfin server, over the Folders sheet.
    var shareForm: ShareForm?
    /// Asking Resume or Start Over for this movie; 0 resume, 1 from the beginning.
    var resuming: String?
    var resumeRow = 0
}

/// The TV's Add Network Share and Add Jellyfin Server form, typed with the keyboard or the
/// phone's Type on TV.
struct ShareForm: Equatable {
    var jellyfin = false
    /// 0 address, 1 user name, 2 password, 3 Connect.
    var row = 0
    var address = ""
    var user = ""
    var password = ""
    /// Why the share or server couldn't be added.
    var message: String?
    var connecting = false
}

/// A poster: the movie at this path.
struct MovieItem: Hashable {
    let path: String

    static func movie(_ path: String) -> MovieItem { MovieItem(path: path) }
}

struct MovieRow: Hashable {
    let title: String?
    let items: [MovieItem]
    var progress = false
}

extension MoviesBrowser {
    /// Up from the top row goes to the Settings button, and Down from it comes back. With no movies the button is
    /// all there is, and focus stays on it. `lengths` is how many posters each row has.
    mutating func move(_ direction: RemoteCommand.Direction, lengths: [Int]) {
        guard !lengths.isEmpty else { return }
        row = min(row, lengths.count - 1)
        column = min(column, lengths[row] - 1)
        if settingsFocused {
            if direction == .down { settingsFocused = false }
            return
        }
        switch direction {
        case .left: column = max(0, column - 1)
        case .right: column = min(lengths[row] - 1, column + 1)
        case .up:
            if row == 0 { settingsFocused = true } else { row -= 1; column = min(column, lengths[row] - 1) }
        case .down:
            if row < lengths.count - 1 { row += 1; column = min(column, lengths[row] - 1) }
        }
    }
}

extension TVController {
    static let movieColumns = 7

    var movieRows: [MovieRow] {
        let library = movieLibrary
        var rows: [MovieRow] = []
        let started = library.continueWatching.prefix(Self.movieColumns)
        if !started.isEmpty {
            rows.append(MovieRow(title: "Continue Watching", items: started.map { .movie($0.path) }, progress: true))
        }
        let all = library.movies.map { MovieItem.movie($0.path) }
        for start in stride(from: 0, to: all.count, by: Self.movieColumns) {
            let chunk = Array(all[start..<min(start + Self.movieColumns, all.count)])
            rows.append(MovieRow(title: start == 0 ? "Library" : nil, items: chunk))
        }
        return rows
    }

    /// The focused poster, kept inside the rows as they change; nil when there are no movies.
    var movieFocus: (row: Int, column: Int)? {
        let rows = movieRows
        guard !rows.isEmpty else { return nil }
        let browser = movies ?? MoviesBrowser()
        let row = min(browser.row, rows.count - 1)
        return (row, min(browser.column, rows[row].items.count - 1))
    }

    func openMovies() {
        // 从设置里进来时，哔哩哔哩、网易云、得到、浏览器的页面可能还开着：先收起来，不然片库被它们挡住
        closeBilibili(); leaveNetease(); closeDedao(); closeBrowser()
        movies = MoviesBrowser()
        movieLibrary.refresh()
    }

    func handleMovies(_ command: RemoteCommand) {
        guard var browser = movies else { return }
        if browser.shareForm != nil { handleShareForm(command); return }
        if browser.folderRow != nil { handleFolders(command); return }
        if let path = browser.resuming {
            switch command {
            case .move(.up): browser.resumeRow = 0
            case .move(.down): browser.resumeRow = 1
            case .back: browser.resuming = nil
            case .select, .playPause:
                movies?.resuming = nil
                if let movie = movieLibrary.movie(path) {
                    playMovie(movie, from: browser.resumeRow == 0 ? max(0, (movie.position ?? 0) - 5) : 0)
                }
                return
            default: break
            }
            movies = browser
            return
        }
        let rows = movieRows
        switch command {
        case .back:
            movies = nil
        case .move(let direction):
            browser.move(direction, lengths: rows.map(\.items.count))
            movies = browser
        case .select where browser.settingsFocused || rows.isEmpty:
            openMovieFolders()
        case .select, .playPause:
            guard let focus = movieFocus, !browser.settingsFocused else { return }
            activateMovieItem(rows[focus.row].items[focus.column])
        default: break
        }
    }

    func activateMovieItem(_ item: MovieItem) {
        guard let movie = movieLibrary.movie(item.path) else { return }
        if movie.inProgress {
            movies?.resuming = item.path
            movies?.resumeRow = 0
        } else {
            playMovie(movie, from: 0)
        }
    }

    // MARK: Folders

    /// The Settings button: the Folders sheet, and focus back on the button when it closes.
    func openMovieFolders() {
        movies?.settingsFocused = true
        movies?.folderRow = 0
    }

    /// The Folders sheet's last rows, in order, after the folders and the Jellyfin servers.
    enum FolderAdder: Int, CaseIterable {
        case folder, networkShare, jellyfin
    }

    /// Where an Add row sits on the Folders sheet.
    func folderSheetRow(_ adder: FolderAdder) -> Int {
        movieLibrary.suggestedFolders.count + jellyfin.servers.count + adder.rawValue
    }

    private func handleFolders(_ command: RemoteCommand) {
        guard let row = movies?.folderRow else { return }
        let count = folderSheetRow(.folder) + FolderAdder.allCases.count
        switch command {
        case .back: movies?.folderRow = nil
        case .move(.up): movies?.folderRow = max(0, row - 1)
        case .move(.down): movies?.folderRow = min(count - 1, row + 1)
        case .select: activateFolderRow(row)
        default: break
        }
    }

    func activateFolderRow(_ row: Int) {
        movies?.folderRow = row
        let suggested = movieLibrary.suggestedFolders
        let servers = jellyfin.servers
        let extras = suggested.count + servers.count
        if suggested.indices.contains(row) {
            // An offline share reconnects; anything else switches on or off.
            let shares = networkShares
            if let share = shares.share(for: suggested[row]), shares.status[share.id] != .connected {
                shares.connect(share, addToMovies: false)
            } else {
                movieLibrary.toggle(suggested[row])
            }
        } else if row < extras {
            jellyfin.activate(servers[row - suggested.count])
        } else {
            switch FolderAdder(rawValue: row - extras) {
            case .folder: chooseMovieFolder()
            case .networkShare: movies?.shareForm = ShareForm()
            case .jellyfin: movies?.shareForm = ShareForm(jellyfin: true)
            case nil: break
            }
        }
    }

    // MARK: Network shares

    private func handleShareForm(_ command: RemoteCommand) {
        guard var form = movies?.shareForm else { return }
        // While connecting, only Back does anything: it closes the form and the share keeps trying.
        if form.connecting { if case .back = command { movies?.shareForm = nil }; return }
        form.message = nil
        switch command {
        case .back:
            movies?.shareForm = nil
            return
        case .move(.up): form.row = max(0, form.row - 1)
        case .move(.down): form.row = min(3, form.row + 1)
        case .select:
            if form.row == 3 {
                movies?.shareForm = form
                form.jellyfin ? submitJellyfinForm() : submitShareForm()
                return
            }
            form.row += 1
        case .text(let text):
            let typed = text.replacingOccurrences(of: "\n", with: "")
            switch form.row {
            case 1: form.user += typed
            case 2: form.password += typed
            default: form.row = 0; form.address += typed
            }
            if text.hasSuffix("\n") { movies?.shareForm = form; handleShareForm(.select); return }
        case .deleteBackward:
            switch form.row {
            case 1: if !form.user.isEmpty { form.user.removeLast() }
            case 2: if !form.password.isEmpty { form.password.removeLast() }
            default: if !form.address.isEmpty { form.address.removeLast() }
            }
        default: break
        }
        movies?.shareForm = form
    }

    /// Adds the share and waits for it to connect: closes on success, or shows why it didn't.
    private func submitShareForm() {
        guard var form = movies?.shareForm else { return }
        let shares = networkShares
        guard let share = shares.add(address: form.address, user: form.user, password: form.password) else {
            form.message = form.address.isEmpty ? "Type the shared folder's address first." : "Use an address like nas.local/Movies."
            movies?.shareForm = form
            return
        }
        form.connecting = true
        movies?.shareForm = form
        Task { @MainActor [weak self] in
            // macOS gives up on an unreachable server after about a minute.
            for _ in 0..<150 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.movies?.shareForm?.connecting == true else { return }
                switch shares.status[share.id] {
                case .connected:
                    self.movies?.shareForm = nil
                    return
                case .offline(let reason):
                    self.movies?.shareForm?.connecting = false
                    self.movies?.shareForm?.message = reason
                    return
                default: continue
                }
            }
        }
    }

    /// Signs in to the Jellyfin server: closes on success, or shows why it couldn't.
    private func submitJellyfinForm() {
        guard var form = movies?.shareForm else { return }
        form.connecting = true
        movies?.shareForm = form
        let jellyfin = jellyfin
        Task { @MainActor [weak self] in
            let error = await jellyfin.signIn(address: form.address, user: form.user, password: form.password)
            guard let self, self.movies?.shareForm?.connecting == true else { return }
            if let error {
                self.movies?.shareForm?.connecting = false
                self.movies?.shareForm?.message = error
            } else {
                self.movies?.shareForm = nil
            }
        }
    }

    /// The Mac's own folder picker, for anywhere else.
    private func chooseMovieFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders with movies for Mac TV"
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { panel.urls.forEach(self.movieLibrary.add) }
        }
    }
}

// MARK: Views

private enum PosterLayout {
    static let size = CGSize(width: 200, height: 300)
    static let spacing: CGFloat = 40
    static let left: CGFloat = 140
    static let rowsTop: CGFloat = 450
    static let rowStride: CGFloat = 432
}

struct MoviesScreen: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var library: MovieLibrary
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tv: TVController) {
        _tv = ObservedObject(wrappedValue: tv)
        _library = ObservedObject(wrappedValue: tv.movieLibrary)
    }

    var body: some View {
        let rows = tv.movieRows
        let focus = tv.movieFocus
        let browser = tv.movies ?? MoviesBrowser()
        // With no movies the Settings button is all there is to focus.
        let settingsFocused = browser.settingsFocused || focus == nil
        let movie = focus.flatMap { library.movie(rows[$0.row].items[$0.column].path) }
        let focusRow = focus?.row ?? 0

        ZStack(alignment: .topLeading) {
            MovieBackdrop(image: movie.flatMap { library.posters[$0.path] })
                .id(movie?.path ?? "none")
                .transition(.opacity)

            header(movie: movie)
                .padding(.leading, PosterLayout.left)
                .frame(height: PosterLayout.rowsTop - 40, alignment: .bottomLeading)

            // The time, and Settings for the Folders sheet: Up from the top row reaches it, like Apple TV's top controls.
            HStack(spacing: 16) {
                ClockPill(twentyFour: tv.preferences.twentyFourHourTime)
                MoviesSettingsButton(focused: settingsFocused) {
                    tv.openMovieFolders()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 96)
            .padding(.top, 56)

            VStack(alignment: .leading, spacing: 56) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    // Room for a focused poster to grow without covering its row's name.
                    VStack(alignment: .leading, spacing: 42) {
                        Text(row.title ?? " ")
                            .font(.tv(.body, emphasized: true))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(height: 34)
                        HStack(spacing: PosterLayout.spacing) {
                            ForEach(Array(row.items.enumerated()), id: \.element) { column, item in
                                PosterTile(item: item, progress: row.progress,
                                           focused: !settingsFocused && focus?.row == rowIndex && focus?.column == column,
                                           library: library)
                                    .onTapGesture {
                                        tv.movies?.row = rowIndex
                                        tv.movies?.column = column
                                        tv.movies?.settingsFocused = false
                                        tv.activateMovieItem(item)
                                    }
                            }
                        }
                    }
                    .opacity(rowIndex < focusRow ? 0 : 1)
                }
            }
            .offset(x: PosterLayout.left, y: PosterLayout.rowsTop - CGFloat(focusRow) * PosterLayout.rowStride)

            if let row = browser.folderRow {
                FoldersSheet(tv: tv, focusedRow: row)
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if let form = browser.shareForm {
                ShareFormSheet(tv: tv, form: form)
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if let path = browser.resuming, let resuming = library.movie(path) {
                ResumeSheet(movie: resuming, row: browser.resumeRow) { from in
                    tv.movies?.resuming = nil
                    tv.playMovie(resuming, from: from)
                }
                .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(.white)
        .animation(Motion.navigate, value: focusRow)
        .animation(Motion.focus, value: settingsFocused)
        .animation(Motion.appear, value: movie?.path)
        .animation(Motion.appear, value: browser.folderRow != nil)
        .animation(Motion.appear, value: browser.resuming)
    }

    /// The focused movie, or with none in the library, that there are none and where Mac TV looked.
    @ViewBuilder
    private func header(movie: Movie?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let movie {
                Text(movie.displayTitle)
                    .font(.tv(.title2, emphasized: true))
                    .lineLimit(2)
                    .frame(maxWidth: 1300, alignment: .leading)
                Text(details(of: movie))
                    .font(.tv(.body)).foregroundStyle(.white.opacity(0.7))
            } else if library.movies.isEmpty {
                Text("No movies yet")
                    .font(.tv(.title2, emphasized: true))
                if let line = emptyLine {
                    Text(line)
                        .font(.tv(.body)).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: 1100, alignment: .leading)
                }
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 12)
    }

    private var emptyLine: String? {
        if library.scanning { return "Looking for movies…" }
        let names = ListFormatter.localizedString(byJoining: library.folders.map { FileManager.default.displayName(atPath: $0.path) })
        return names.isEmpty ? nil : "No movies in \(names)."
    }

    private func details(of movie: Movie) -> String {
        var parts: [String] = []
        if let year = movie.year { parts.append(String(year)) }
        if let duration = movie.duration { parts.append(Self.length(duration)) }
        if movie.inProgress, let position = movie.position, let duration = movie.duration {
            parts.append("\(Self.length(duration - position)) left")
        }
        parts.append(movie.server ?? movie.url.pathExtension.uppercased())
        return parts.joined(separator: "  ·  ")
    }

    static func length(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(max(minutes, 1)) min"
    }
}

/// The focused movie's poster, blurred across the screen behind everything, like Apple TV's
/// app pages.
struct MovieBackdrop: View {
    let image: NSImage?
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        ZStack {
            Color(hex: "#0B0C10")
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: canvas.width, height: canvas.height)
                    .blur(radius: 90)
                    .saturation(1.2)
                    .opacity(0.75)
                    .clipped()
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

struct PosterTile: View {
    let item: MovieItem
    let progress: Bool
    let focused: Bool
    @ObservedObject var library: MovieLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        artwork
            .frame(width: PosterLayout.size.width, height: PosterLayout.size.height)
            .clipShape(shape)
            .overlay {
                RadialGradient(colors: [.white.opacity(0.28), .white.opacity(0)], center: UnitPoint(x: 0.5, y: 0.02),
                               startRadius: 0, endRadius: PosterLayout.size.height * 0.8)
                    .blendMode(.plusLighter)
                    .clipShape(shape)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(focused ? 0.55 : 0.12), .white.opacity(focused ? 0.08 : 0.03)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: focused ? 1.5 : 1)
            }
            .overlay(alignment: .bottom) { progressBar }
            .scaleEffect(focused ? (reduceMotion ? 1.05 : 1.12) : 1)
            .offset(y: focused && !reduceMotion ? -8 : 0)
            .shadow(color: .black.opacity(focused ? 0.6 : 0.25), radius: focused ? 28 : 10, y: focused ? 22 : 6)
            .zIndex(focused ? 1 : 0)
            .animation(Motion.focus, value: focused)
    }

    @ViewBuilder private var artwork: some View {
        if let image = library.posters[item.path] {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            // Until the poster arrives: the film icon on graphite.
            ZStack {
                LinearGradient(colors: [Color(hex: "#3A3A3C"), Color(hex: "#1C1C1E")], startPoint: .top, endPoint: .bottom)
                Image(systemName: "film").font(.system(size: 54, weight: .light)).opacity(0.5)
            }
        }
    }

    @ViewBuilder private var progressBar: some View {
        if progress, let movie = library.movie(item.path),
           let position = movie.position, let duration = movie.duration, duration > 0 {
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.3))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: geo.size.width * min(1, position / duration))
                    }
            }
            .frame(height: 6)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .shadow(color: .black.opacity(0.5), radius: 4)
        }
    }
}

/// Which folders Mac TV looks in: switches for the usual places and drives, and the Mac's own
/// picker for anywhere else.
struct FoldersSheet: View {
    @ObservedObject var tv: TVController
    let focusedRow: Int
    @ObservedObject private var library: MovieLibrary
    @ObservedObject private var shares: NetworkShares
    @ObservedObject private var jellyfin: JellyfinServers
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace

    init(tv: TVController, focusedRow: Int) {
        _tv = ObservedObject(wrappedValue: tv)
        self.focusedRow = focusedRow
        _library = ObservedObject(wrappedValue: tv.movieLibrary)
        _shares = ObservedObject(wrappedValue: tv.networkShares)
        _jellyfin = ObservedObject(wrappedValue: tv.jellyfin)
    }

    var body: some View {
        let folders = library.suggestedFolders
        VStack(alignment: .leading, spacing: 10) {
            Text("Folders").font(.tv(.title3, emphasized: true))
                .padding(.bottom, 14)
            ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                if let share = shares.share(for: folder) {
                    let status = shares.status[share.id] ?? .connecting
                    row(index, systemImage: "server.rack", title: share.name) {
                        if status == .connected {
                            SettingSwitch(on: library.isWatched(folder))
                        } else {
                            Text(status.text).font(.tv(.caption1)).opacity(0.6)
                        }
                    }
                } else {
                    row(index, systemImage: folder.path.hasPrefix("/Volumes/") ? "externaldrive.fill" : "folder.fill",
                        title: FileManager.default.displayName(atPath: folder.path)) {
                        SettingSwitch(on: library.isWatched(folder))
                    }
                }
            }
            ForEach(Array(jellyfin.servers.enumerated()), id: \.element.id) { index, server in
                let status = jellyfin.status[server.id] ?? .connecting
                row(folders.count + index, systemImage: "tv.and.mediabox", title: server.name) {
                    if !server.on || status == .connected {
                        SettingSwitch(on: server.on)
                    } else {
                        Text(status.text).font(.tv(.caption1)).opacity(0.6)
                    }
                }
            }
            row(tv.folderSheetRow(.folder), systemImage: "folder.badge.plus", title: "Add Folder…") {
                Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold)).opacity(0.6)
            }
            row(tv.folderSheetRow(.networkShare), systemImage: "plus", title: "Add Network Share…") {
                Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold)).opacity(0.6)
            }
            row(tv.folderSheetRow(.jellyfin), systemImage: "plus", title: "Add Jellyfin Server…") {
                Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold)).opacity(0.6)
            }
        }
        .padding(56)
        .frame(width: 980, alignment: .leading)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .frame(width: canvas.width, height: canvas.height)
        .background(Color.black.opacity(0.35))
        .animation(Motion.focus, value: focusedRow)
    }

    private func row<Trailing: View>(_ index: Int, systemImage: String, title: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        let focused = index == focusedRow
        return HStack(spacing: 18) {
            Image(systemName: systemImage).font(.system(size: 24)).frame(width: 34)
            Text(title).font(.tv(.body)).lineLimit(1)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .foregroundStyle(focused ? .black : .white)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if focused {
                shape.fill(.white).matchedGeometryEffect(id: "focus", in: focusSpace)
            } else {
                shape.fill(.white.opacity(0.08))
            }
        }
        .scaleEffect(focused ? 1.02 : 1)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 8)
        .contentShape(Rectangle())
        .onTapGesture { tv.activateFolderRow(index) }
    }
}

/// Apple TV's choice for a movie you've started: carry on, or from the beginning.
struct ResumeSheet: View {
    let movie: Movie
    let row: Int
    let choose: (Double) -> Void
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let position = movie.position ?? 0
        VStack(spacing: 18) {
            Text(movie.displayTitle).font(.tv(.callout, emphasized: true)).lineLimit(2).multilineTextAlignment(.center)
                .padding(.bottom, 10)
            button("Resume From \(clockText(position))", systemImage: "play.fill", focused: row == 0) {
                choose(max(0, position - 5))
            }
            button("Start From Beginning", systemImage: "arrow.counterclockwise", focused: row == 1) { choose(0) }
        }
        .padding(48)
        .frame(width: 720)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .tvPanel(in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .frame(width: canvas.width, height: canvas.height)
        .background(Color.black.opacity(0.35))
    }

    private func button(_ title: String, systemImage: String, focused: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 26, weight: .semibold))
        .frame(maxWidth: .infinity)
        .frame(height: 70)
        .foregroundStyle(focused ? .black : .white)
        .background(focused ? .white : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .scaleEffect(focused ? 1.03 : 1)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 8)
        .animation(Motion.focus, value: focused)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: Player

/// A movie on the TV: the picture, subtitles, and Apple TV's controls in Liquid Glass: back at
/// the top, skip and play/pause in the middle, and the title, subtitle and audio buttons and the
/// progress bar at the bottom. The remote drives them (left and right skip, select plays or
/// pauses, down opens subtitles and audio) and so does the mouse.
struct MoviePlayerView: View {
    @ObservedObject var player: MoviePlayer

    var body: some View {
        ZStack {
            LayerHost(layer: player.engine.layer).ignoresSafeArea()
                .onTapGesture { player.togglePlayback() }

            TVCanvas {
                ZStack(alignment: .bottom) {
                    if let text = player.subtitleText {
                        Text(text)
                            .font(.tv(.title3))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 3)
                            .shadow(color: .black.opacity(0.6), radius: 10)
                            .padding(.horizontal, 200)
                            .padding(.bottom, player.controlsVisible ? 300 : 80)
                            .animation(Motion.appear, value: player.controlsVisible)
                            .allowsHitTesting(false)
                    }
                    if player.controlsVisible {
                        controls.transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .foregroundStyle(.white)
            }
            .ignoresSafeArea()
        }
        .background(Color.black)
        .onContinuousHover { phase in
            if case .active(let point) = phase { player.pointerMoved(to: point) }
        }
    }

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 240)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).frame(height: 480)
            }
            .allowsHitTesting(false)

            PlayerButton(symbol: "chevron.backward", size: 72, action: { player.onClose?() })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 96)
                .padding(.top, 64)

            GlassGroup(spacing: 0) {
                HStack(spacing: 56) {
                    TransportButton(symbol: "gobackward.10", size: 100, pressed: player.pressed == "back") { player.skip(-10) }
                    TransportButton(symbol: player.playing ? "pause.fill" : "play.fill", size: 136,
                                     pressed: player.pressed == "playpause") { player.togglePlayback() }
                    TransportButton(symbol: "goforward.10", size: 100, pressed: player.pressed == "forward") { player.skip(10) }
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                if let menu = player.menu {
                    menuView(menu).frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(player.movie.displayTitle)
                            .font(.tv(.headline, emphasized: true))
                            .lineLimit(1)
                        if !details.isEmpty {
                            Text(details).font(.tv(.caption2)).opacity(0.7)
                        }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    Spacer(minLength: 0)
                    GlassGroup {
                        HStack(spacing: 18) {
                            if !player.subtitleOptions.isEmpty {
                                PlayerButton(symbol: player.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill",
                                             size: 68, lit: player.menuShowsSubtitles) { player.toggleMenu(subtitles: true) }
                            }
                            if player.audioOptions.count > 1 {
                                PlayerButton(symbol: "speaker.wave.2.bubble", size: 68,
                                             lit: player.menu != nil && !player.menuShowsSubtitles) { player.toggleMenu(subtitles: false) }
                            }
                        }
                    }
                }
                progress
                HStack {
                    Text(clockText(player.time))
                    Spacer()
                    Text("−" + clockText(max(0, player.duration - player.time)))
                }
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .shadow(color: .black.opacity(0.5), radius: 6)
            }
            .padding(.horizontal, 110)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// The year and the language you're hearing.
    private var details: String {
        var parts: [String] = []
        if let year = player.movie.year { parts.append(String(year)) }
        if let audio = player.selectedAudio, player.audioOptions.indices.contains(audio) {
            let option = player.audioOptions[audio]
            if MediaOption.languageCode(option.language) != nil { parts.append(option.title) }
        }
        return parts.joined(separator: "  ·  ")
    }

    /// The progress bar; click anywhere on it to jump there.
    private var progress: some View {
        GeometryReader { geo in
            let fraction = player.duration > 0 ? min(1, player.time / player.duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: 12)
                Capsule().fill(.white).frame(width: max(12, geo.size.width * fraction), height: 12)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in player.seek(toFraction: location.x / max(geo.size.width, 1)) }
        }
        .frame(height: 36)
        .shadow(color: .black.opacity(0.4), radius: 6)
    }

    private func menuView(_ menu: MoviePlayer.Menu) -> some View {
        let columns = player.menuColumns
        let titles = columns.count == 2 ? ["Audio", "Subtitles"] : ["Subtitles"]
        return HStack(alignment: .top, spacing: 40) {
            ForEach(Array(columns.enumerated()), id: \.offset) { column, options in
                VStack(alignment: .leading, spacing: 8) {
                    Text(titles[column]).font(.tv(.caption2, emphasized: true)).textCase(.uppercase).tracking(1).opacity(0.6)
                        .padding(.leading, 16)
                    ForEach(Array(options.enumerated()), id: \.offset) { row, title in
                        let focused = menu.column == column && menu.row == row
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark").opacity(player.selectedRow(in: column) == row ? 1 : 0)
                            Text(title).lineLimit(1)
                        }
                        .font(.system(size: 24, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .frame(minWidth: 300, alignment: .leading)
                        .foregroundStyle(focused ? .black : .white)
                        .background(focused ? .white : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { player.choose(column: column, row: row) }
                    }
                }
            }
        }
        .padding(24)
        .tvGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .animation(Motion.focus, value: menu)
    }

}

/// A small round glass control at the player's edges (back, subtitles, audio). `lit` shows it
/// white while its menu is open.
struct PlayerButton: View {
    let symbol: String
    let size: CGFloat
    var lit = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if lit { Circle().fill(.white) }
                Image(systemName: symbol)
                    .font(.system(size: size * 0.38, weight: .semibold))
            }
            .frame(width: size, height: size)
            .foregroundStyle(lit ? .black : .white)
            .tvGlass(in: Circle())
            .contentShape(Circle())
            .animation(Motion.press, value: lit)
        }
        .buttonStyle(PressStyle(pressed: false))
    }
}

/// The middle controls: skip and play/pause in glass circles. A press, from the remote
/// (`pressed`) or a click, dips the whole circle slightly and it settles back.
struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var pressed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .tvGlass(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(pressed: pressed))
    }
}

/// Settings beside the time: the pill's glass and height, white when focused, and a dip when pressed.
/// It opens the Folders sheet.
private struct MoviesSettingsButton: View {
    let focused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(focused ? .black : .white)
                .frame(width: 50, height: 50)
                .focusPlatter(Capsule(), focused: focused)
                .contentShape(Circle())
                .scaleEffect(focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 14, y: 8)
                .animation(Motion.focus, value: focused)
        }
        .buttonStyle(PressStyle(pressed: false))
        .accessibilityLabel("Settings")
    }
}

/// A press: the control dips a little and settles back, with no bounce.
private struct PressStyle: ButtonStyle {
    let pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(pressed || configuration.isPressed ? 0.94 : 1)
            .animation(Motion.press, value: pressed || configuration.isPressed)
    }
}

/// Shows a Core Animation layer (the video) filling the view.
struct LayerHost: NSViewRepresentable {
    let layer: CALayer

    final class Host: NSView {
        var hosted: CALayer?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor.black
        view.layer?.addSublayer(layer)
        view.hosted = layer
        return view
    }

    func updateNSView(_ nsView: Host, context: Context) {}
}

/// Add Network Share or Add Jellyfin Server on the TV: the address, a user name and password, then
/// Connect or Sign In.
struct ShareFormSheet: View {
    @ObservedObject var tv: TVController
    let form: ShareForm
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(form.jellyfin ? "Add Jellyfin Server" : "Add Network Share").font(.tv(.title3, emphasized: true))
            AdderField(label: form.jellyfin ? "Server" : "Shared folder", text: form.address,
                       placeholder: form.jellyfin ? "e.g. 192.168.1.5:8096" : "e.g. nas.local/Movies", focused: form.row == 0) { set(0) }
            AdderField(label: "User name", text: form.user, placeholder: form.jellyfin ? "Your Jellyfin user" : "Leave empty for guest",
                       focused: form.row == 1) { set(1) }
            AdderField(label: "Password", text: String(repeating: "•", count: form.password.count), placeholder: "Password",
                       focused: form.row == 2) { set(2) }
            ShelfButton(title: buttonTitle, systemImage: form.jellyfin ? "tv.and.mediabox" : "server.rack",
                        focused: form.row == 3, glass: false) {
                set(3)
                tv.handle(.select)
            }
            if let message = form.message {
                Text(message)
                    .font(.tv(.caption2, emphasized: true))
                    .foregroundStyle(Color(hex: "#FF8A80"))
                    .lineLimit(2)
            }
        }
        .padding(56)
        .frame(width: 1000, alignment: .leading)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .background(Color.black.opacity(0.35))
        .animation(Motion.focus, value: form)
    }

    private var buttonTitle: String {
        switch (form.jellyfin, form.connecting) {
        case (true, true): "Signing In…"
        case (true, false): "Sign In"
        case (false, true): "Connecting…"
        case (false, false): "Connect"
        }
    }

    private func set(_ row: Int) {
        guard tv.movies?.shareForm?.connecting == false else { return }
        tv.movies?.shareForm?.row = row
    }
}
