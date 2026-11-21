import SwiftUI

/// Arrange Apps shows Home as it is: the dock (Home's top row) in its glass, the rest of the apps below in
/// Home's six columns, Store and Settings among them. Select picks the focused app up and the
/// D-pad moves it, the others making room; Select again puts it down and Back puts it back where it was.
/// Moving an app into a full dock moves the dock's last app to the first place below; moving one out brings
/// the first app below up into the dock. Press and hold Select on an app for Hide (and, for an app someone
/// added, Delete for Everyone); system apps (AppLibrary.systemApps) move but never hide. The pointer drags apps
/// directly.
///
/// App identities, rather than positions, keep the selection on the same app as things move.
struct AppOrganizer: Equatable {
    /// Home's columns: the dock and each row below hold six.
    static let columns = AppLibrary.dockSize

    /// The app picked up, and where it's going in Home's order. `rest` is the order without it, so the apps
    /// it passes go back to their places when it moves on.
    struct Lift: Equatable {
        let id: String
        var rest: [String]
        var index: Int

        init(id: String, in order: [String]) {
            self.id = id
            rest = order.filter { $0 != id }
            index = order.firstIndex(of: id) ?? 0
        }

        /// Home's order with the app where it's going.
        var order: [String] {
            var order = rest
            order.insert(id, at: clamped(index))
            return order
        }

        /// A place it can actually take.
        func clamped(_ index: Int) -> Int { min(max(index, 0), rest.count) }

        /// Where the D-pad takes it, nil at an edge.
        func step(_ direction: RemoteCommand.Direction) -> Int? {
            AppOrganizer.step(from: index, direction, count: rest.count + 1)
        }
    }

    /// What press and hold offers for an app.
    enum Action: Equatable { case quick(QuickAction), editHomeScreen, hide, deleteForEveryone }

    /// Press and hold Select on an app: its menu, then, for Delete for Everyone, the question before the app
    /// goes from everyone's Home. The question starts on Cancel.
    enum Menu: Equatable {
        case actions(row: Int)
        case confirmDelete(row: Int)

        static let cancelRow = 0, deleteRow = 1
    }

    var selectedID: String?
    var lift: Lift?
    var menu: Menu?
    /// Opened by holding Select on a Home Screen app: its menu, with Edit Home Screen first. Back, Hide or Delete
    /// return to Home; Edit Home Screen stays, with the app picked up.
    var fromHome = false

    /// The menu is over Home itself, beside the app held, as on Apple TV: Arrange Apps shows only once Edit Home
    /// Screen is chosen.
    var onHome: Bool { fromHome && menu != nil }

    /// Where the D-pad goes from a place among `count` apps laid out as on Home, six to a row; nil at an edge.
    /// Down to a shorter last row lands on its last app.
    static func step(from index: Int, _ direction: RemoteCommand.Direction, count: Int) -> Int? {
        let row = index / columns, column = index % columns
        switch direction {
        case .left: return column > 0 ? index - 1 : nil
        case .right: return column < columns - 1 && index + 1 < count ? index + 1 : nil
        case .up: return row > 0 ? index - columns : nil
        case .down:
            if index + columns < count { return index + columns }
            return (row + 1) * columns < count ? count - 1 : nil
        }
    }
}

extension TVController {
    func openOrganizer() {
        let focusedID: String?
        if case .app(let index) = focus, services.indices.contains(index) {
            focusedID = services[index].id
        } else {
            focusedID = nil
        }
        let order = appOrder
        organizer = AppOrganizer(selectedID: order.contains(focusedID ?? "") ? focusedID : order.first)
    }

    /// What Arrange Apps shows: Home's order, with an app that's being moved where it's going.
    var organizerOrder: [String] { organizer?.lift?.order ?? appOrder }

    /// What press and hold offers for an app: Hide for every app but a system app (Movies, Web), Delete for Everyone
    /// for an app someone added, and, held on Home, Edit Home Screen first. A system app held on Home offers only
    /// Edit Home Screen; in Arrange Apps it offers nothing, so holding it opens no menu.
    func organizerActions(for id: String) -> [AppOrganizer.Action] {
        let added = library.containsAddedApp(id) && !Catalog.services.contains(where: { $0.id == id })
        let hide: [AppOrganizer.Action] = AppLibrary.isSystemApp(id) ? [] : [.hide]
        // Held on Home: the app's own quick actions first (QuickActions), then Edit Home Screen.
        let home: [AppOrganizer.Action] = organizer?.fromHome == true
            ? quickActions(for: id).map(AppOrganizer.Action.quick) + [.editHomeScreen] : []
        return home + hide + (added ? [.deleteForEveryone] : [])
    }

    /// Focus is on an app on the Home Screen itself (no app open, no sheet): holding Select opens its menu.
    var homeAppFocused: Bool {
        guard mode == .launcher, activeSheet == nil, !bilibiliOpen, !neteaseOpen, !browserOpen, !dedaoOpen, movies == nil,
              case .app(let index) = focus else { return false }
        return services.indices.contains(index) && appOrder.contains(services[index].id)
    }

    /// Press and hold Select on a Home Screen app, as on Apple TV: Edit Home Screen, Hide and, for an app someone
    /// added, Delete for Everyone, in Arrange Apps' menu.
    func openHomeAppMenu() -> Bool {
        guard homeAppFocused, case .app(let index) = focus else { return false }
        organizer = AppOrganizer(selectedID: services[index].id, menu: .actions(row: 0), fromHome: true)
        return true
    }

    /// Call after a library refresh, including edits made by the phone while this sheet is open: an app
    /// being moved keeps its place among the apps as they are now.
    func reconcileOrganizerSelection() {
        guard var panel = organizer else { return }
        let order = appOrder
        if var lift = panel.lift {
            if order.contains(lift.id) {
                lift.rest = order.filter { $0 != lift.id }
                lift.index = lift.clamped(lift.index)
                panel.lift = lift
            } else {
                panel.lift = nil
            }
        }
        if !order.contains(panel.selectedID ?? "") {
            panel.selectedID = order.first
            panel.menu = nil
        }
        if panel != organizer { organizer = panel }
    }

    func handleOrganizer(_ command: RemoteCommand) {
        guard var panel = organizer else { return }
        if let menu = panel.menu {
            handleOrganizerMenu(menu, command)
            return
        }
        switch command {
        case .back:
            if panel.lift != nil {
                panel.lift = nil            // Back puts it back where it was: nothing was saved yet
                organizer = panel
            } else {
                organizer = nil
            }
        case .move(let direction):
            if var lift = panel.lift {
                guard let index = lift.step(direction) else { return }
                lift.index = index
                panel.lift = lift
            } else {
                let order = appOrder
                guard let id = panel.selectedID, let index = order.firstIndex(of: id),
                      let next = AppOrganizer.step(from: index, direction, count: order.count) else { return }
                panel.selectedID = order[next]
            }
            organizer = panel
        case .select:
            if panel.lift != nil {
                dropOrganizerApp()
            } else if let id = panel.selectedID, appOrder.contains(id) {
                panel.lift = AppOrganizer.Lift(id: id, in: appOrder)
                organizer = panel
            }
        default:
            return
        }
    }

    /// Puts the app being moved down where it is, saving Home's order if it changed.
    func dropOrganizerApp() {
        guard var panel = organizer, let lift = panel.lift else { return }
        panel.lift = nil
        panel.selectedID = lift.id
        organizer = panel
        if lift.order != appOrder { moveApp(lift.id, to: lift.index) }
    }

    // MARK: Press and hold

    /// Press and hold Select on an app: its menu. Not while an app is being moved, and not for an app it would
    /// offer nothing for (a system app).
    func openOrganizerMenu() -> Bool {
        guard var panel = organizer, panel.lift == nil, panel.menu == nil,
              let id = panel.selectedID, appOrder.contains(id), !organizerActions(for: id).isEmpty else { return false }
        panel.menu = .actions(row: 0)
        organizer = panel
        return true
    }

    /// The menu or question that press and hold opened is showing: it goes, as with Back (from Home, back to Home).
    func closeOrganizerMenu() -> Bool {
        guard organizer?.menu != nil else { return false }
        if organizer?.fromHome == true { organizer = nil } else { organizer?.menu = nil }
        return true
    }

    private func handleOrganizerMenu(_ menu: AppOrganizer.Menu, _ command: RemoteCommand) {
        guard let id = organizer?.selectedID else { return }
        switch (menu, command) {
        case (_, .back):
            _ = closeOrganizerMenu()
        case (.actions(let row), .move(let direction)) where direction == .up || direction == .down:
            let next = min(max(row + (direction == .down ? 1 : -1), 0), organizerActions(for: id).count - 1)
            if next != row { organizer?.menu = .actions(row: next) }
        case (.actions(let row), .select), (.confirmDelete(let row), .select):
            chooseOrganizerMenuRow(row)
        case (.confirmDelete(let row), .move(let direction)):
            let next = direction == .up || direction == .left ? AppOrganizer.Menu.cancelRow : AppOrganizer.Menu.deleteRow
            if next != row { organizer?.menu = .confirmDelete(row: next) }
        default:
            break
        }
    }

    /// A row of the menu chosen: Hide hides the app here; Delete for Everyone asks first.
    func chooseOrganizerMenuRow(_ row: Int) {
        guard let panel = organizer, let menu = panel.menu, let id = panel.selectedID else { return }
        switch menu {
        case .actions:
            let actions = organizerActions(for: id)
            guard actions.indices.contains(row) else { return }
            switch actions[row] {
            case .quick(let action):
                performQuickAction(action)
            case .editHomeScreen:
                // Arrange Apps, with this app picked up to move; Select puts it down.
                organizer?.menu = nil
                organizer?.fromHome = false
                organizer?.lift = AppOrganizer.Lift(id: id, in: appOrder)
            case .hide:
                guard !AppLibrary.isSystemApp(id) else { return }
                removeOrganizerApp(id) { hideApp($0) }
            case .deleteForEveryone: organizer?.menu = .confirmDelete(row: AppOrganizer.Menu.cancelRow)
            }
        case .confirmDelete:
            if row == AppOrganizer.Menu.deleteRow {
                removeOrganizerApp(id) { deleteAppForEveryone($0) }
            } else {
                _ = closeOrganizerMenu()
            }
        }
    }

    /// Hides or deletes an app; focus goes to the app that takes its place.
    private func removeOrganizerApp(_ id: String, _ remove: (String) -> Void) {
        let order = appOrder
        guard let index = order.firstIndex(of: id) else { return }
        organizer?.menu = nil
        organizer?.selectedID = order.indices.contains(index + 1) ? order[index + 1] : (index > 0 ? order[index - 1] : nil)
        if organizer?.fromHome == true { organizer = nil }   // held on Home: back to Home
        remove(id)
    }

    // MARK: The pointer

    /// A click on an app: it takes focus, and an app being moved goes down where it is.
    func organizerClick(_ id: String) {
        guard organizer != nil else { return }
        if organizer?.menu != nil { organizer?.menu = nil; return }
        if organizer?.lift != nil { dropOrganizerApp(); return }
        if organizer?.selectedID != id, appOrder.contains(id) { organizer?.selectedID = id }
    }

    /// Pressing and holding an app with the pointer: its menu.
    func organizerHold(_ id: String) {
        guard organizer?.lift == nil, appOrder.contains(id) else { return }
        organizer?.selectedID = id
        organizer?.menu = nil
        if openOrganizerMenu() { feedback.play(.select, from: .pointer) }
    }

    /// The pointer starts dragging an app: it's picked up.
    func beginOrganizerDrag(_ id: String) {
        guard var panel = organizer, appOrder.contains(id) else { return }
        if panel.lift?.id == id { return }
        panel.menu = nil
        panel.selectedID = id
        panel.lift = AppOrganizer.Lift(id: id, in: appOrder)
        organizer = panel
        feedback.play(.select, from: .pointer)
    }

    /// The dragged app is over another place: the others make room, with the move sound.
    func dragOrganizerApp(to index: Int) {
        guard var lift = organizer?.lift else { return }
        let target = lift.clamped(index)
        guard target != lift.index else { return }
        lift.index = target
        organizer?.lift = lift
        feedback.play(.step, from: .pointer)
    }

    func endOrganizerDrag() {
        guard organizer?.lift != nil else { return }
        dropOrganizerApp()
        feedback.play(.select, from: .pointer)
    }
}

// MARK: - The sheet

/// Where everything sits, in the sheet's own coordinates: Home's tiles, dock, columns and gaps (HomeGrid), with the
/// rows as Home's grid has them.
struct ArrangeGrid {
    static let space = "arrange-apps"
    static let tile = HomeGrid.tile
    static let spacing = HomeGrid.spacing
    /// The dock's padding around its row, as on Home.
    static let inset = HomeGrid.dockPadding
    static let width = HomeGrid.dockWidth(columns: AppOrganizer.columns)
    static let dockTop: CGFloat = 96
    static let dockHeight = HomeGrid.dockHeight
    /// Room under a row for the focused app's name, as on Home.
    static let rowGap = HomeGrid.rowGap
    /// The second row's top: a row's stride under the dock's row.
    static let belowTop = dockTop + inset + HomeGrid.rowStride

    /// Every tile.
    let count: Int

    var rows: Int { max((count + AppOrganizer.columns - 1) / AppOrganizer.columns, 1) }
    var height: CGFloat { Self.belowTop + CGFloat(max(rows - 1, 1)) * (Self.tile.height + Self.rowGap) }

    /// The tile at a place in Home's order.
    static func frame(of index: Int) -> CGRect {
        let center = center(of: index)
        return CGRect(x: center.x - tile.width / 2, y: center.y - tile.height / 2, width: tile.width, height: tile.height)
    }

    /// The middle of the tile at a place in Home's order.
    static func center(of index: Int) -> CGPoint {
        let row = index / AppOrganizer.columns, column = index % AppOrganizer.columns
        let x = inset + CGFloat(column) * (tile.width + spacing) + tile.width / 2
        if row == 0 { return CGPoint(x: x, y: dockTop + dockHeight / 2) }
        return CGPoint(x: x, y: belowTop + CGFloat(row - 1) * (tile.height + rowGap) + tile.height / 2)
    }

    /// The place under a point, for the pointer: the dock and the gap just below it are the dock's row.
    static func index(at point: CGPoint) -> Int {
        let column = min(max(Int(((point.x - inset + spacing / 2) / (tile.width + spacing)).rounded(.down)), 0),
                         AppOrganizer.columns - 1)
        if point.y < (dockTop + dockHeight + belowTop) / 2 { return column }
        let row = 1 + max(0, Int(((point.y - belowTop + rowGap / 2) / (tile.height + rowGap)).rounded(.down)))
        return row * AppOrganizer.columns + column
    }
}

struct AppOrganizerSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the pointer has hold of the dragged tile, from its middle.
    @State private var grab: CGSize = .zero
    @State private var pointer: CGPoint?

    private static let top: CGFloat = 64

    var body: some View {
        let panel = tv.organizer ?? AppOrganizer()
        let order = tv.organizerOrder
        let apps = Dictionary(tv.arrangedServices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grid = ArrangeGrid(count: order.count)
        let focused = (panel.lift?.id ?? panel.selectedID).flatMap { order.firstIndex(of: $0) }
        let shift = scroll(to: focused)

        ZStack(alignment: .topLeading) {
            Text("Arrange Apps").font(.tv(.title3, emphasized: true))
            GlassDock()
                .frame(width: ArrangeGrid.width, height: ArrangeGrid.dockHeight)
                .offset(y: ArrangeGrid.dockTop)
                .allowsHitTesting(false)
            ForEach(Array(order.enumerated()), id: \.element) { index, id in
                if let service = apps[id] { tile(service, at: index, panel: panel) }
            }
        }
        .frame(width: ArrangeGrid.width, height: grid.height, alignment: .topLeading)
        .coordinateSpace(name: ArrangeGrid.space)
        .offset(x: (canvas.width - ArrangeGrid.width) / 2, y: Self.top - shift)
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .overlay {
            // Press and hold's menu over the whole screen, grown out of the app held (see AppMenuLayer).
            let held = panel.onHome ? nil : panel.selectedID.flatMap { id in order.firstIndex(of: id).map { (id, $0) } }
            let origin = CGPoint(x: (canvas.width - ArrangeGrid.width) / 2, y: Self.top - shift)
            AppMenuLayer(tv: tv, menu: held == nil ? nil : panel.menu, id: held?.0, name: held.flatMap { apps[$0.0]?.name } ?? "",
                         tile: held.map { ArrangeGrid.frame(of: $0.1).offsetBy(dx: origin.x, dy: origin.y) },
                         rightOfTile: (held?.1 ?? 0) % AppOrganizer.columns < AppOrganizer.columns - 2, size: canvas)
        }
        .clipped()
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : Motion.focus, value: order)
        .animation(reduceMotion ? nil : Motion.navigate, value: shift)
        .animation(Motion.focus, value: panel)
    }

    /// How far the sheet scrolls up so the focused row, with its name, stays on screen.
    private func scroll(to index: Int?) -> CGFloat {
        guard let index, index >= AppOrganizer.columns else { return 0 }
        let bottom = ArrangeGrid.center(of: index).y + ArrangeGrid.tile.height / 2
        return max(0, Self.top + bottom + 100 - canvas.height)
    }

    private func tile(_ service: Service, at index: Int, panel: AppOrganizer) -> some View {
        let lifted = panel.lift?.id == service.id
        let focused = lifted || (panel.lift == nil && panel.selectedID == service.id)
        let follows = lifted && pointer != nil
        let center = follows ? CGPoint(x: pointer!.x - grab.width, y: pointer!.y - grab.height) : ArrangeGrid.center(of: index)
        // As on Home, the focused app's name shows under the rows below the dock.
        let named = focused && !follows && index >= AppOrganizer.columns
        return AppTile(service: service, focused: focused, tilt: .zero)
            .scaleEffect(lifted ? 1.06 : 1)
            .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: lifted ? 40 : 0, y: lifted ? 34 : 0)
            .modifier(Wiggle(active: lifted && !reduceMotion))
            .overlay(alignment: .bottom) {
                Text(service.name)
                    .font(.tv(.caption1))
                    .fixedSize()
                    .offset(y: 50)
                    .opacity(named ? 1 : 0)
                    .animation(Motion.focus, value: named)
            }
            .contentShape(Rectangle())
            .onTapGesture { tv.organizerClick(service.id) }
            .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 6) { tv.organizerHold(service.id) }
            .simultaneousGesture(drag(service.id, from: ArrangeGrid.center(of: index)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(service.name)
            .accessibilityAddTraits(focused ? .isSelected : [])
            .position(center)
            // The dragged tile stays under the pointer; the others ease into their new places.
            .transaction { if follows { $0.animation = nil } }
            .zIndex(lifted ? 3 : focused ? 2 : 1)
    }

    private func drag(_ id: String, from center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(ArrangeGrid.space))
            .onChanged { value in
                if pointer == nil || tv.organizer?.lift?.id != id {
                    grab = CGSize(width: value.startLocation.x - center.x, height: value.startLocation.y - center.y)
                    tv.beginOrganizerDrag(id)
                }
                pointer = value.location
                tv.dragOrganizerApp(to: ArrangeGrid.index(at: CGPoint(x: value.location.x - grab.width,
                                                                       y: value.location.y - grab.height)))
            }
            .onEnded { _ in
                pointer = nil
                tv.endOrganizerDrag()
            }
    }

}

/// Press and hold's menu (a Menu in DesignSystem/Layers): beside the app held, right of it or left of it in the last
/// two columns, kept on the screen; the screen behind dims, and the card grows out of the app and shrinks back into it.
/// `menu` nil puts it away. `tile` and `size` are in the space the layer fills (the whole screen).
struct AppMenuLayer: View {
    @ObservedObject var tv: TVController
    let menu: AppOrganizer.Menu?
    let id: String?
    let name: String
    let tile: CGRect?
    let rightOfTile: Bool
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            if menu != nil {
                DimBackdrop { tv.organizer?.menu = nil; if tv.organizer?.fromHome == true { tv.organizer = nil } }
                    .transition(.opacity)
            }
            if let menu, let id, let tile {
                let half = AppMenuCard.height(menu, actions: tv.organizerActions(for: id)) / 2
                let reach = AppMenuCard.reach(from: tile.width)
                AppMenuCard(tv: tv, menu: menu, id: id, name: name)
                    .position(x: rightOfTile ? tile.midX + reach : tile.midX - reach,
                              y: min(max(tile.midY, half + 40), size.height - half - 40))
                    // Positioned, the card fills the layer: the scale's anchor is the app's middle in it.
                    .transition(.growing(from: UnitPoint(x: tile.midX / max(1, size.width), y: tile.midY / max(1, size.height))))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(Motion.slide, value: menu != nil)
    }
}

/// Press and hold Select on an app: its menu (Edit Home Screen on Home, Hide, Delete for Everyone), or the question
/// before Delete for Everyone. The same card on Home and in Arrange Apps.
struct AppMenuCard: View {
    @ObservedObject var tv: TVController
    let menu: AppOrganizer.Menu
    let id: String
    let name: String

    static let width: CGFloat = 470

    private static func isQuick(_ action: AppOrganizer.Action) -> Bool {
        if case .quick = action { return true }
        return false
    }

    /// From the middle of the app to the middle of the card beside it.
    static func reach(from tileWidth: CGFloat) -> CGFloat { tileWidth * 0.57 + 32 + width / 2 }

    /// How tall the card is, to keep it on the screen: its rows, or the question and its two answers.
    static func height(_ menu: AppOrganizer.Menu, actions: [AppOrganizer.Action]) -> CGFloat {
        let count = actions.count
        let line: CGFloat = actions.contains(where: isQuick) && !actions.allSatisfy(isQuick) ? 21 : 0   // under quick actions
        switch menu {
        case .actions: return 44 + CGFloat(count) * 66 + CGFloat(max(0, count - 1)) * 10 + line
        case .confirmDelete: return 316   // the question (about 60), Cancel and Delete (66 each), their gaps and padding
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch menu {
            case .actions(let row):
                let actions = tv.organizerActions(for: id)
                ForEach(Array(actions.enumerated()), id: \.offset) { offset, action in
                    // A line between the app's quick actions and Home's own (as on an iPhone's Haptic Touch menu).
                    if offset > 0, case .quick = actions[offset - 1], !Self.isQuick(action) {
                        Rectangle().fill(.white.opacity(0.18)).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 5)
                    }
                    switch action {
                    case .quick(let quick):
                        menuRow(quick.title, systemImage: quick.symbol, focused: row == offset, destructive: false) {
                            tv.chooseOrganizerMenuRow(offset)
                        }
                    case .editHomeScreen:
                        menuRow("Edit Home Screen", systemImage: "square.grid.3x3", focused: row == offset, destructive: false) {
                            tv.chooseOrganizerMenuRow(offset)
                        }
                    case .hide:
                        menuRow("Hide", systemImage: "eye.slash", focused: row == offset, destructive: false) {
                            tv.chooseOrganizerMenuRow(offset)
                        }
                    case .deleteForEveryone:
                        menuRow("Delete for Everyone", systemImage: "trash", focused: row == offset, destructive: true) {
                            tv.chooseOrganizerMenuRow(offset)
                        }
                    }
                }
            case .confirmDelete(let row):
                Text("Delete “\(name)” for Everyone?")
                    .font(.tv(.callout, emphasized: true))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                menuRow("Cancel", systemImage: nil, focused: row == AppOrganizer.Menu.cancelRow, destructive: false) {
                    tv.chooseOrganizerMenuRow(AppOrganizer.Menu.cancelRow)
                }
                menuRow("Delete for Everyone", systemImage: "trash", focused: row == AppOrganizer.Menu.deleteRow, destructive: true) {
                    tv.chooseOrganizerMenuRow(AppOrganizer.Menu.deleteRow)
                }
            }
        }
        .padding(22)
        .frame(width: Self.width, alignment: .leading)
        .tvPanelSurface(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .tvShadow(.float)
        .foregroundStyle(.white)
    }

    private func menuRow(_ title: String, systemImage: String?, focused: Bool, destructive: Bool,
                         action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            if let systemImage { Image(systemName: systemImage).frame(width: 34) }
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.tv(.body, emphasized: true))
        .foregroundStyle(destructive ? Color.destructive : (focused ? .black : .white))
        .padding(.horizontal, 22)
        .frame(height: 66)
        .focusPlatter(RoundedRectangle(cornerRadius: 18, style: .continuous), focused: focused, glass: false)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// The lifted app's gentle wiggle, as Apple TV's while it moves an app. It runs only while an app is lifted,
/// a few degrees at 30 frames a second on that one tile.
struct Wiggle: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            content.rotationEffect(.degrees(active ? sin(t * 2 * .pi * 2.4) * 1.3 : 0))
        }
    }
}
