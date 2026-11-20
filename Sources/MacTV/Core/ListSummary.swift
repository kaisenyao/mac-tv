/// 设置里"选了哪些"那一行右边的字，所有应用一个写法（照苹果中文界面）：
/// 一项写名字；两项"甲、乙"；三项以上"甲等 5 项"（汉字和数字之间空一格，汉字之间不空）；一项都没有写 `none`
enum ListSummary {
    nonisolated static func chinese(_ items: [String], none: String) -> String {
        switch items.count {
        case 0: none
        case 1: items[0]
        case 2: items.joined(separator: "、")
        default: "\(items[0])等 \(items.count) 项"
        }
    }
}
