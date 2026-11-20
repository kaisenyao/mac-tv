import AppKit
import Foundation
import Testing
@testable import MacTV

/// 浏览器的标签栏按很多种顺序乱按一通（遥控器、鼠标、键盘快捷键都有："+"、关、改地址、不改了、返回、换标签、"⋯"菜单、无痕的），
/// 每按一下都检查标签栏的规矩：
/// - 胶囊的宽度和标签的个数对得上（一个是 720，多了跟着变长，最宽撑满）
/// - 两头不切掉东西（浮起来的标签在遮罩里）
/// - 只有焦点所在的那个是白的；只剩一个标签时焦点不留在它上面（关掉一个以后）
/// - 不留下改了一半的地址栏
/// - 只剩一个空白标签页时没有 ×，菜单里也没有 Close Tab
/// 全在开始页上（空白标签页，不联网、不开网页视图）。开着网站的最后一个标签另有一条测试
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BrowserSequenceTests {
    /// 每次都一样的随机数（种子定了，失败的那一串能原样再跑一次）
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    enum Op: CaseIterable {
        case left, right, up, down, select, back, holdSelect, tapBar, tapClose, tapMenu, clickOutside, shortcut, typeLetter
    }

    /// 1920 的画布去掉两边的边距（各 32）、两组按钮（各 116）、和胶囊之间的空（各 16）
    static let track: CGFloat = 1592

    @Test
    func theBarKeepsItsRulesThroughManySequences() throws {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
        // 浏览器把标签页存在 UserDefaults.standard 里（测试里是临时文件夹里的一份，见 TestSandbox.m）：用完原样放回去
        let keys = ["browserTabs", "browserActiveTab", "browserZoom", "browserHistory"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTVTests.sequence.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        let store = tv.browserStore
        store.tv = tv

        var failures = 0
        for seed in 1...160 where failures == 0 {
            var random = Random(state: UInt64(seed))
            // 每一串从一个空白标签页开始（关到只剩一个）
            store.newBlankTab()
            tv.browserOpen = true
            while store.tabs.count > 1, let first = store.tabs.first { store.closeTab(first.id) }
            var log: [String] = []
            for _ in 0..<40 {
                let op = Op.allCases.randomElement(using: &random)!
                let count = store.tabs.count
                let wasInBar = store.barFocus != nil
                let label = apply(op, store: store, tv: tv, random: &random)
                log.append(label)
                if !tv.browserOpen {   // 返回到主屏了：再开浏览器
                    store.newBlankTab()
                    tv.browserOpen = true
                    log.append("reopen")
                }
                let closed = store.tabs.count < count
                let problems = Self.problems(store, closedOne: closed, wasInBar: wasInBar, afterClick: op == .clickOutside)
                if !problems.isEmpty {
                    Issue.record("seed \(seed): \(problems.joined(separator: "; ")) after \(log.joined(separator: " → "))")
                    failures += 1
                    break
                }
            }
        }
    }

    /// 按一下（遥控器、鼠标、快捷键），返回记在日志里的名字
    func apply(_ op: Op, store: BrowserStore, tv: TVController, random: inout Random) -> String {
        // 那几排里的网站、打了字的地址栏按确认会去开网页：这里不开（不联网）
        let onRows: Bool = {
            if let history = store.historyState { if case .row = history.focus, !store.editing { return true } else { return false } }
            if case .item = store.focus, store.barFocus == nil, !store.editing { return true } else { return false }
        }()
        switch op {
        case .left: tv.handle(.move(.left), from: .remote); return "←"
        case .right: tv.handle(.move(.right), from: .remote); return "→"
        case .up: tv.handle(.move(.up), from: .remote); return "↑"
        case .down: tv.handle(.move(.down), from: .remote); return "↓"
        case .select:
            if onRows || (store.editing && !store.query.isEmpty) { return "(skip select)" }
            tv.handle(.select, from: .remote); return "select"
        case .back: tv.handle(.press(.back, .tap), from: .remote); return "back"
        case .holdSelect: _ = store.openMenu(); return "hold select (⋯)"
        case .tapBar:
            guard let item = store.barItems.randomElement(using: &random) else { return "(no bar item)" }
            store.tapBar(item); return "click \(item)"
        case .tapClose:
            guard store.tabsClosable, let tab = store.tabs.randomElement(using: &random) else { return "(no ×)" }
            store.tapBar(.close(tab.id)); return "click × \(store.tabs.firstIndex(of: tab).map(String.init) ?? "closed")"
        case .tapMenu:
            guard store.menu != nil, let item = store.menuRows.flatMap({ $0 }).randomElement(using: &random) else { return "(no menu)" }
            store.tapMenu(item); return "click menu \(item)"
        case .clickOutside: store.endEditingByClick(); return "click outside"
        case .shortcut:
            let shortcut = BrowserStore.Shortcut.allCases.randomElement(using: &random)!
            store.perform(shortcut); return "⌘ \(shortcut.title)"
        case .typeLetter:
            guard store.editing else { return "(not typing)" }
            store.handle(.text("a")); return "type a"
        }
    }

    /// 这一刻标签栏的规矩哪几条不对
    static func problems(_ store: BrowserStore, closedOne: Bool, wasInBar: Bool, afterClick: Bool) -> [String] {
        var problems: [String] = []
        let ids = store.tabs.map(\.id)
        if store.tabs.isEmpty { problems.append("no tabs") }
        // 焦点只在还在、能用的东西上（只有它是白的）
        switch store.barFocus {
        case .tab(let id)?: if !ids.contains(id) { problems.append("focus on a closed tab") }
        case .close(let id)?: if !ids.contains(id) || !store.tabsClosable { problems.append("focus on a × that isn't there") }
        case .back?: if !store.barCanGoBack { problems.append("focus on a hidden Back") }
        case .forward?: if !store.barCanGoForward { problems.append("focus on a hidden Forward") }
        default: break
        }
        if store.menu != nil, store.barFocus != .more { problems.append("menu open without ⋯ focused") }
        // 关掉一个以后只剩一个：焦点不留在标签栏上（那个标签不是白的）
        if closedOne, wasInBar, store.tabs.count == 1, store.barFocus != nil { problems.append("the last tab stayed focused (white) after a close") }
        // 地址栏：不留下改了一半的
        if store.editingInBar {
            if !store.editing { problems.append("editing in the bar without editing") }
            if let current = store.barCurrentID { if store.barFocus != .tab(current) { problems.append("editing but focus isn't on the field") } }
            else { problems.append("editing in the bar without a current tab") }
        }
        if !store.editing, store.replaceQuery { problems.append("stale selected address") }
        if afterClick, store.editing { problems.append("still editing after a click outside the field") }
        // 只剩一个空白标签页：没有 ×，菜单里没有 Close Tab，往左不会走到 ×
        if store.tabs.count == 1, let only = store.tabs.first, only.isBlank {
            if store.tabsClosable { problems.append("the only Start Page tab can be closed") }
            if store.menuRows.contains([.closeTab]) { problems.append("Close Tab in the menu with one Start Page tab") }
            if BrowserStore.barStep(in: store.barItems, from: .tab(only.id), .left, closable: store.tabsClosable) == .close(only.id) {
                problems.append("Left reaches a × on the only Start Page tab")
            }
        }
        // 无痕标签页还在，无痕的那份网站数据就得在
        if store.tabs.contains(where: \.isPrivate), !store.hasPrivateSession { problems.append("private tab without its private session") }
        // 胶囊：一个标签是 720，多了跟着变长（比一个的宽），最宽撑满；两头浮起来的不被切掉
        let current = store.tabs.firstIndex { $0.id == store.barCurrentID }
        let widths = BrowserTopBar.tabWidths(count: store.tabs.count, current: current, editing: store.editing && store.editingInBar,
                                             available: track - BrowserTopBar.inset * 2, gap: BrowserTopBar.tabGap)
        let capsule = BrowserTopBar.capsuleWidth(widths: widths, available: track, gap: BrowserTopBar.tabGap)
        if store.tabs.count == 1, capsule != BrowserTopBar.editWidth { problems.append("one tab but the capsule is \(capsule) wide") }
        if store.tabs.count > 1, !(capsule > BrowserTopBar.editWidth && capsule <= track) { problems.append("\(store.tabs.count) tabs in a \(capsule) capsule") }
        for width in [widths.first, widths.last].compactMap({ $0 }) {
            let overflow = width * (BrowserTopBar.liftScale(width: width) - 1) / 2 + 4   // 放大多出来的一半，加上影子
            if overflow > BrowserTopBar.maskOutset { problems.append("a focused end tab \(width) wide would be clipped") }
        }
        return problems
    }

    /// 胶囊跟着标签的个数：1 → 2 → 1、4 → 1，宽度只跟个数（和正在看的、改地址）有关
    @Test
    func theCapsuleGrowsAndShrinksWithTheTabCount() {
        let available = Self.track - BrowserTopBar.inset * 2
        func capsule(_ count: Int, current: Int? = 0, editing: Bool = false) -> CGFloat {
            BrowserTopBar.capsuleWidth(widths: BrowserTopBar.tabWidths(count: count, current: current, editing: editing, available: available),
                                       available: Self.track)
        }
        #expect(capsule(1) == 720)
        #expect(capsule(1, editing: true) == 720)                 // 一个标签：改地址时胶囊就是地址栏，大小不变
        #expect(capsule(2) == 934)                             // 360 + 560 + 6 + 8
        #expect(capsule(3) == 1300)                            // 360 × 2 + 560 + 12 + 8
        #expect(abs(capsule(4) - Self.track) < 0.5)                         // 四个撑满
        #expect(abs(capsule(12, current: 6) - Self.track) < 0.5)
        let counts = Array(1...12)
        let widths = counts.map { capsule($0) }
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 + 0.5 })   // 只会跟着变长
        #expect(capsule(2) == capsule(2, current: 1))             // 1 → 2 → 1：回到原来的样子
    }
}
