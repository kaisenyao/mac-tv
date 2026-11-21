import SwiftUI
import WebKit

/// A person who watches on this Mac: their own home screen apps and their own sign-ins.
struct Profile: Codable, Identifiable, Equatable {
    static let mainID = "main"

    let id: String
    var name: String
    var color: String
    /// The WebKit store that keeps this profile's sign-ins. The first profile has none and uses
    /// the default store, so everything signed in before profiles existed stays signed in.
    var store: UUID?

    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    @MainActor
    var websiteDataStore: WKWebsiteDataStore {
        store.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
    }
}

/// Everyone's profiles and who's watching now, kept in ~/Library/Application Support/Mac TV/profiles.json.
@MainActor
final class ProfileStore {
    private struct Saved: Codable {
        var profiles: [Profile]
        var current: String
    }

    static let colors = ["#0A84FF", "#FF9F0A", "#30D158", "#BF5AF2", "#FF375F", "#64D2FF"]

    private var saved: Saved
    private let file: URL
    private let folder: URL

    init(folder: URL = AppFolder.url) {
        self.folder = folder
        file = folder.appendingPathComponent("profiles.json")
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Saved.self, from: data),
           !decoded.profiles.isEmpty {
            saved = decoded
        } else {
            let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
            saved = Saved(profiles: [Profile(id: Profile.mainID, name: first, color: Self.colors[0])], current: Profile.mainID)
        }
    }

    var all: [Profile] { saved.profiles }

    var current: Profile {
        saved.profiles.first { $0.id == saved.current } ?? saved.profiles[0]
    }

    func select(_ id: String) {
        guard saved.profiles.contains(where: { $0.id == id }) else { return }
        saved.current = id
        save()
    }

    /// The colour a new profile gets: the first one nobody has yet.
    var nextColor: String {
        let used = Set(saved.profiles.map(\.color))
        return Self.colors.first { !used.contains($0) } ?? Self.colors[saved.profiles.count % Self.colors.count]
    }

    func add(named name: String) -> Profile {
        let profile = Profile(id: String(UUID().uuidString.prefix(8)).lowercased(), name: name, color: nextColor, store: UUID())
        saved.profiles.append(profile)
        save()
        return profile
    }

    /// Renames a profile; a blank name keeps the old one.
    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = saved.profiles.firstIndex(where: { $0.id == id }) else { return }
        saved.profiles[index].name = String(trimmed.prefix(ProfileName.maxLength))
        save()
    }

    /// Removes a profile, its app list and its sign-ins. The first profile stays.
    func remove(_ id: String) {
        guard id != Profile.mainID, let index = saved.profiles.firstIndex(where: { $0.id == id }) else { return }
        let profile = saved.profiles.remove(at: index)
        if saved.current == id { saved.current = Profile.mainID }
        save()
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("apps-\(id).json"))
        if let store = profile.store {
            // WebKit crashes removing a data store before it has started up in this launch (when no
            // website has been opened yet); asking for the default store starts it.
            _ = WKWebsiteDataStore.default()
            WKWebsiteDataStore.remove(forIdentifier: store) { _ in }
        }
    }

    private func save() {
        Log.app.attempt("Saving profiles") { try JSONEncoder().encode(saved).write(to: file, options: .atomic) }
    }
}

/// The "Who's watching?" screen: pick a profile, add one, or remove one.
struct ProfilePicker: Equatable {
    /// A profile, or the Add tile just after the last one.
    var index = 0
    /// On the Remove button below the focused profile.
    var onRemove = false
    /// Remove asks first: "Remove “Name”?" with Cancel, then Remove Profile. Focus starts on Cancel.
    var confirmingRemove = false
    /// On the question, focus is on Remove Profile rather than Cancel.
    var onConfirm = false
    /// The new profile's name while it's being typed.
    var naming: String?
    /// Dropped down from Home's avatar, as tvOS 26's: the profiles in a grid under the status row, the one watching
    /// ticked, and Add Profile. (At launch, and from Control Center, it's the full "Who's Watching?" screen.)
    /// Adding a profile goes on to the full screen to name it; removing one is in Settings › Profiles and Accounts.
    var dropdown = false

    /// Columns of the dropdown's grid.
    static let dropdownColumns = 2
}

/// Typing a profile's name, on "Who's Watching?" and in Settings: the keyboard, or the phone's Type on TV.
enum ProfileName {
    static let maxLength = 20

    /// Applies one command to the name being typed. True when it finishes the name: Return, or Select.
    static func apply(_ command: RemoteCommand, to name: inout String) -> Bool {
        switch command {
        case .text(let text):
            name = String((name + text.replacingOccurrences(of: "\n", with: "")).prefix(maxLength))
            return text.hasSuffix("\n")
        case .deleteBackward:
            if !name.isEmpty { name.removeLast() }
            return false
        case .select:
            return true
        default:
            return false
        }
    }
}

extension TVController {
    func openProfiles(dropdown: Bool = false) {
        let index = profiles.all.firstIndex { $0.id == profile.id } ?? 0
        profilePicker = ProfilePicker(index: index, dropdown: dropdown)
    }

    /// Someone else starts watching. The order matters: everything the last person had open closes and
    /// saves first (their queue, positions, tabs), then the new person's space becomes current, and only
    /// then does each app read its data again, from the new space.
    func switchProfile(to id: String) {
        profilePicker = nil
        defer { showStartupPairingIfReady() }
        guard id != profile.id else { return }
        leaveProfile()
        profiles.select(id)
        loadCurrentProfile()
        setFocus(.app(0))
    }

    /// Removes a profile and everything it kept: its home screen layout (apps-<id>.json), its sign-ins (its WebKit
    /// store and Keychain items), its defaults suite, its folder (with its picture) and caches, its remembered
    /// YouTube rows and its website player choice. The apps everyone shares, and their icons, stay. When it was the
    /// one watching, the first profile takes over.
    func removeProfile(_ id: String) {
        guard id != Profile.mainID, profiles.all.contains(where: { $0.id == id }) else { return }
        let wasWatching = id == profile.id
        // The first profile takes over: what the removed one was playing stops and saves, as on any switch.
        if wasWatching { leaveProfile() }
        profiles.remove(id)
        if wasWatching { loadCurrentProfile() } else { objectWillChange.send() }
        spaces.remove(id, keychainServices: profileApps.keychainServices)
        YouTubeFeed.forget(profile: id)
        browserPreferences.forget(id)
    }

    /// The person watching is about to change: close what's open and save what they were in the middle of.
    private func leaveProfile() {
        goHome()
        quitBackgroundApps(reason: "a profile switch")   // Home keeps apps in the background; they're the last person's (see AppQuit)
        profileApps.profileWillChange()
    }

    func renameProfile(_ id: String, to name: String) {
        profiles.rename(id, to: name)
        profileEdited()
    }

    /// The store isn't observed, so a changed name is published here.
    private func profileEdited() {
        if profiles.current != profile { profile = profiles.current } else { objectWillChange.send() }
    }

    /// Takes on the store's current profile: their space first, then their apps, and every app that keeps
    /// data per profile reloads it from their space.
    private func loadCurrentProfile() {
        let space = spaces.enter(profiles.current.id)
        profile = profiles.current
        library = AppLibrary(profileID: profile.id, folder: library.storageFolder)
        reloadServices()
        preferences.use(space)
        remoteCoordinator.shortcutsProfileChanged(space)
        movieLibrary.use(space)
        // 哔哩哔哩、网易云、得到、浏览器按这个人的重新来（不留上一个人的登录、设置、观看记录），主屏顶部也是
        profileApps.profileChanged()
        appShelf.reset()
    }

    func handleProfiles(_ command: RemoteCommand) {
        guard var picker = profilePicker else { return }
        let all = profiles.all
        let addIndex = all.count

        if var name = picker.naming {
            if case .back = command {
                picker.naming = nil
                profilePicker = picker
                return
            }
            let done = ProfileName.apply(command, to: &name)
            picker.naming = name
            profilePicker = picker
            if done { createProfile() }
            return
        }

        if picker.dropdown {
            // The grid under the avatar: Left, Right, Up, Down move; up from its top row, or Back, it goes up again
            let columns = ProfilePicker.dropdownColumns, count = addIndex + 1
            switch command {
            case .back:
                profilePicker = nil
                return
            case .move(.left) where picker.index % columns > 0: picker.index -= 1
            case .move(.right) where picker.index % columns < columns - 1 && picker.index + 1 < count: picker.index += 1
            case .move(.down) where picker.index + columns < count: picker.index += columns
            case .move(.down) where picker.index / columns < (count - 1) / columns: picker.index = count - 1
            case .move(.up):
                if picker.index < columns { profilePicker = nil; return }
                picker.index -= columns
            case .select:
                profilePicker = picker
                activateProfile(picker.index)
                return
            default: break
            }
            profilePicker = picker
            return
        }

        if picker.confirmingRemove {
            switch command {
            case .back: picker.confirmingRemove = false   // back on the Remove button
            case .move(.up), .move(.left): picker.onConfirm = false
            case .move(.down), .move(.right): picker.onConfirm = true
            case .select:
                answerProfileRemoval(picker.onConfirm)
                return
            default: break
            }
            profilePicker = picker
            return
        }

        let removable = picker.index < addIndex && all[picker.index].id != Profile.mainID
        switch command {
        case .back:
            // At launch there's nowhere to go back to: stay with whoever was watching last.
            profilePicker = nil
            showStartupPairingIfReady()
            return
        case .move(.left) where !picker.onRemove:
            picker.index = max(0, picker.index - 1)
        case .move(.right) where !picker.onRemove:
            picker.index = min(addIndex, picker.index + 1)
        case .move(.down) where removable:
            picker.onRemove = true
        case .move(.up):
            picker.onRemove = false
        case .select:
            profilePicker = picker
            activateProfile(picker.index, remove: picker.onRemove)
            return
        default:
            break
        }
        profilePicker = picker
    }

    /// Chooses a profile, starts adding one, or asks before removing the focused one.
    func activateProfile(_ index: Int, remove: Bool = false) {
        guard var picker = profilePicker else { return }
        let all = profiles.all
        picker.index = index
        if index >= all.count {
            picker.naming = ""
            picker.onRemove = false
            picker.dropdown = false   // naming is the full screen's
        } else if remove {
            picker.onRemove = true
            picker.confirmingRemove = true
            picker.onConfirm = false
        } else {
            switchProfile(to: all[index].id)
            return
        }
        profilePicker = picker
    }

    /// The answer to "Remove “Name”?": Remove Profile removes it; Cancel goes back to its Remove button.
    func answerProfileRemoval(_ remove: Bool) {
        guard var picker = profilePicker, picker.confirmingRemove else { return }
        let all = profiles.all
        if remove, all.indices.contains(picker.index) {
            removeProfile(all[picker.index].id)
            picker = ProfilePicker(index: max(0, picker.index - 1))
        } else {
            picker.confirmingRemove = false
            picker.onConfirm = false
        }
        profilePicker = picker
    }

    private func createProfile() {
        guard let name = profilePicker?.naming?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        let added = profiles.add(named: name)
        switchProfile(to: added.id)
    }
}

// MARK: Views

/// A profile's round avatar: their photo (Settings › Profiles and Accounts › Choose Photo…), or their initial on
/// their colour.
struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 200
    @ObservedObject private var photos = ProfilePhotos.shared

    var body: some View {
        if let photo = photos.photo(for: profile.id) {
            Image(nsImage: photo).resizable().interpolation(.high).scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: profile.color), Color(hex: profile.color).opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Text(profile.initial).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white))
                .frame(width: size, height: size)
        }
    }
}

struct ProfilesScreen: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let picker = tv.profilePicker ?? ProfilePicker()
        let all = tv.profiles.all
        let removing = picker.confirmingRemove && all.indices.contains(picker.index) ? all[picker.index] : nil
        VStack(spacing: 56) {
            Text(removing.map { "Remove “\($0.name)”?" } ?? (picker.naming == nil ? "Who’s Watching?" : "New Profile"))
                .font(.tv(.title2, emphasized: true))
            if let name = picker.naming {
                naming(name)
            } else if let removing {
                confirmRemoval(removing, onConfirm: picker.onConfirm)
            } else {
                HStack(alignment: .top, spacing: 56) {
                    ForEach(Array(all.enumerated()), id: \.element.id) { index, profile in
                        tile(index: index, focused: picker.index == index && !picker.onRemove) {
                            ProfileAvatar(profile: profile)
                        } label: {
                            Text(profile.name)
                        }
                    }
                    tile(index: all.count, focused: picker.index == all.count) {
                        Circle().fill(.white.opacity(0.1))
                            .overlay(Circle().strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 3, dash: [10, 8])))
                            .overlay(Image(systemName: "plus").font(.system(size: 64, weight: .medium)))
                            .frame(width: 200, height: 200)
                    } label: {
                        Text("Add Profile")
                    }
                }
                removeButton(picker, all: all)
                    .frame(height: 70)
            }
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: picker)
    }

    private func tile<Art: View, Label: View>(index: Int, focused: Bool, @ViewBuilder art: () -> Art,
                                              @ViewBuilder label: () -> Label) -> some View {
        VStack(spacing: 22) {
            art()
                .overlay(Circle().strokeBorder(.white, lineWidth: focused ? 5 : 0).padding(-10))
                .scaleEffect(focused ? 1.1 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 16)
            label()
                .font(.tvCardTitle)
                .opacity(focused ? 1 : 0.6)
        }
        .contentShape(Rectangle())
        .onTapGesture { tv.activateProfile(index) }
    }

    @ViewBuilder
    private func removeButton(_ picker: ProfilePicker, all: [Profile]) -> some View {
        if picker.index < all.count, all[picker.index].id != Profile.mainID {
            pillButton("Remove \(all[picker.index].name)", focused: picker.onRemove) {
                tv.activateProfile(picker.index, remove: true)
            }
        }
    }

    /// The question before a profile goes: its avatar, then Cancel (where focus starts) and Remove Profile, red
    /// when focused.
    private func confirmRemoval(_ profile: Profile, onConfirm: Bool) -> some View {
        VStack(spacing: 40) {
            ProfileAvatar(profile: profile)
            VStack(spacing: 18) {
                pillButton("Cancel", focused: !onConfirm) { tv.answerProfileRemoval(false) }
                pillButton("Remove Profile", focused: onConfirm, destructive: true) { tv.answerProfileRemoval(true) }
            }
        }
    }

    private func pillButton(_ title: String, focused: Bool, destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.tv(.caption2, emphasized: true))
                .padding(.horizontal, 30)
                .frame(height: 58)
                .foregroundStyle(focused && !destructive ? .black : .white)
                .background(Capsule().fill(focused ? (destructive ? Color(hex: "#FF453A") : .white) : .white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .scaleEffect(focused ? 1.06 : 1)
    }

    private func naming(_ name: String) -> some View {
        VStack(spacing: 30) {
            ProfileAvatar(profile: Profile(id: "new", name: name.isEmpty ? "?" : name, color: tv.profiles.nextColor))
            ProfileNameField(name: Binding(get: { tv.profilePicker?.naming ?? "" }, set: { tv.profilePicker?.naming = $0 })) {
                tv.handle(.select)
            }
            ShelfButton(title: "Create Profile", focused: !name.isEmpty, glass: false) { tv.handle(.select) }
        }
    }
}

/// The new profile's name on "Who's Watching?": a real text field (TVTextField) while it's typed.
struct ProfileNameField: View {
    @Binding var name: String
    let onSubmit: () -> Void

    var body: some View {
        TVTextField(text: $name, placeholder: "Name", editing: true, limit: ProfileName.maxLength, onSubmit: onSubmit)
            .multilineTextAlignment(.center)
            .frame(width: 448)
        .font(.tv(.headline, emphasized: true))
        .padding(.horizontal, 36)
        .frame(minWidth: 520, minHeight: 84)
        .tvPanel(in: Capsule())
    }
}

/// The profiles dropped down from Home's avatar, as tvOS 26's: a grid of avatars under the status row, each with its
/// name, the one watching ticked in green, then Add Profile on glass. Focus lifts an avatar and rings it white, as
/// the avatar in the row. Apple TV's sizes at 1920 points wide: avatars 172 across and 31 apart, rows 228 apart, the
/// grid 103 from the right edge and 145 from the top.
struct ProfileDropdown: View {
    @ObservedObject var tv: TVController
    private static let side: CGFloat = 172
    private static let tick: CGFloat = 40

    var body: some View {
        let picker = tv.profilePicker ?? ProfilePicker(dropdown: true)
        let all = tv.profiles.all
        let count = all.count + 1
        let rows = stride(from: 0, to: count, by: ProfilePicker.dropdownColumns).map { Array($0..<min($0 + ProfilePicker.dropdownColumns, count)) }
        VStack(alignment: .trailing, spacing: 18) {
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 31) {
                    ForEach(row, id: \.self) { index in
                        item(index, all: all, focused: picker.index == index)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.trailing, 103)
        .padding(.top, 145)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(Motion.focus, value: picker)
    }

    private func item(_ index: Int, all: [Profile], focused: Bool) -> some View {
        let profile = all.indices.contains(index) ? all[index] : nil
        return VStack(spacing: 10) {
            Group {
                if let profile {
                    ProfileAvatar(profile: profile, size: Self.side)
                } else {
                    Image(systemName: "plus").font(.system(size: 72, weight: .regular))
                        .frame(width: Self.side, height: Self.side)
                        .tvGlass(in: Circle())
                }
            }
            // The focus ring first, then the tick on top of it (on the avatar's edge, never under the ring), both
            // growing with the avatar
            .overlay(Circle().strokeBorder(.white, lineWidth: 3).padding(-5).opacity(focused ? 1 : 0))
            .overlay {
                // As tvOS's: a small green tick whose centre sits on the avatar's edge, up and to the right at 45°
                if profile?.id == tv.profile.id {
                    let edge = Self.side / 2 * 0.7071
                    Image(systemName: "checkmark").font(.system(size: 20, weight: .bold))
                        .frame(width: Self.tick, height: Self.tick)
                        .background(Circle().fill(Color(hex: "#30D158")))
                        .offset(x: edge, y: -edge)
                }
            }
            .scaleEffect(focused ? 1.12 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 14, y: 8)
            Text(profile?.name ?? "Add Profile")
                .font(.tvMenuDetail)
                .lineLimit(1)
                .opacity(focused ? 1 : 0.75)
                // The focused avatar grows by 12 %: its name moves down with it, the same gap below every avatar
                .offset(y: focused ? Self.side * 0.06 : 0)
        }
        .frame(width: Self.side)
        .contentShape(Rectangle())
        .onTapGesture { tv.activateProfile(index) }
    }
}
