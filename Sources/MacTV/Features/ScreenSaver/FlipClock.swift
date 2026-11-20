import CoreText
import SwiftUI

/// 屏保"翻页时钟"（Fliqlo 那样）：黑底上两块深灰的翻页牌，左边小时、右边分钟；数字一变，那块牌的上半片翻下来。
/// 照投影仪上那个启动器的翻页时钟（cleanyourtv 的 FlipClockView）做的：牌的大小和间距、颜色、圆角、
/// 中缝，字是 Helvetica 粗体压窄到 0.77 再描一圈边（翻页钟那种又高又窄又粗的数字）。
/// 12 / 24 小时制跟设置 › General › 24-Hour Time 走（屏保页选了翻页时钟时也有这一行，是同一个设置）（默认是这台 Mac 的设置）；12 小时制时小时那块牌上写 AM（左上角）/ PM（左下角），和 Fliqlo 一样。
/// 只在分钟变的那一下动半秒，平时一帧都不画
struct FlipClock: View {
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        GeometryReader { geo in
            TimelineView(.everyMinute) { context in
                FlipClockFace(date: context.date, twentyFour: preferences.twentyFourHourTime, size: geo.size)
            }
        }
        .background(Color.black)
        // 先拼成一张画再淡入淡出：不然数字的填色和描边各淡各的，叠着的那一圈边会先显出来
        .compositingGroup()
    }
}

/// One moment of the clock at a size (the screensaver, and the Settings card's thumbnail through FlipClock).
struct FlipClockFace: View {
    let date: Date
    let twentyFour: Bool
    let size: CGSize

    static let digitColor = Color(white: 0xAA / 255)

    var body: some View {
        let parts = FlipClockTime(date, twentyFour: twentyFour)
        // 量自真翻页钟的比例：一块牌是宽的 0.4525，两块之间隔一块牌的 0.084
        let side = min(size.height * 0.80, size.width * 0.4525)
        HStack(spacing: side * 0.084) {
            FlipPlate(text: parts.hour, side: side)
                // 和 Fliqlo 一样：AM 在小时那块牌的左上角，PM 在左下角，离边一样远
                .overlay(alignment: parts.meridiemAtTop ? .topLeading : .bottomLeading) {
                    if let meridiem = parts.meridiem {
                        Text(meridiem)
                            .font(.custom(FlipNumerals.fontName, size: side * 0.08))
                            .foregroundStyle(Self.digitColor)
                            .padding(.leading, side * 0.065)
                            .padding(parts.meridiemAtTop ? .top : .bottom, side * 0.1)
                    }
                }
            FlipPlate(text: parts.minute, side: side)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// 现在几点几分，按翻页钟上写的样子：24 小时制小时补零（"09"），12 小时制不补（"9"）带 AM / PM；分钟总是两位
struct FlipClockTime: Equatable {
    let hour: String
    let minute: String
    let meridiem: String?

    init(hour: String, minute: String, meridiem: String?) {
        self.hour = hour
        self.minute = minute
        self.meridiem = meridiem
    }

    init(_ date: Date, twentyFour: Bool = FlipClockTime.systemTwentyFour, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        if twentyFour {
            self.hour = String(format: "%02d", hour)
            meridiem = nil
        } else {
            self.hour = String(hour % 12 == 0 ? 12 : hour % 12)
            meridiem = hour < 12 ? "AM" : "PM"
        }
        minute = String(format: "%02d", parts.minute ?? 0)
    }

    /// AM / PM 写在哪：AM 左上角，PM 左下角（Fliqlo 的位置）
    var meridiemAtTop: Bool { meridiem == "AM" }

    /// 这台 Mac 现在用不用 24 小时制（系统设置 › 通用 › 日期与时间）
    static var systemTwentyFour: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "H"
        return !format.contains("a")
    }
}

/// 一块翻页牌。数字变的时候：旧数字的上半片绕中缝往前翻下去，翻到一半换成新数字的下半片落下来盖住旧的下半片
private struct FlipPlate: View {
    let text: String
    let side: CGFloat
    /// 翻过几次了（只会往上加）；动画就是把它从上一次的数平滑地推到这一次
    @State private var flips: Double = 0
    @State private var before = ""

    var body: some View {
        FlipFrame(now: text, before: before, side: side, target: flips, phase: flips)
            .onChange(of: text) { old, _ in
                before = old
                withAnimation(.linear(duration: 0.52)) { flips += 1 }
            }
    }
}

private struct FlipFrame: View, Animatable {
    let now: String
    let before: String
    let side: CGFloat
    let target: Double
    var phase: Double

    nonisolated var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    /// 0 刚开始翻，1 停稳
    private var progress: Double { min(max(1 - (target - phase), 0), 1) }

    var body: some View {
        let t = progress
        let half = side / 2
        VStack(spacing: 0) {
            ZStack {
                PlateHalf(text: now, side: side, upper: true)
                if t < 0.5 {
                    // 旧数字的上半片翻下去：先慢后快
                    let fold = Self.easeIn(t * 2)
                    PlateHalf(text: before, side: side, upper: true, shade: fold)
                        .rotation3DEffect(.degrees(-90 * fold), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.35)
                }
            }
            .frame(height: half)
            .zIndex(t < 0.5 ? 1 : 0)
            ZStack {
                PlateHalf(text: t < 1 ? before : now, side: side, upper: false)
                if t >= 0.5, t < 1 {
                    // 新数字的下半片落下来：先快后慢
                    let land = Self.easeOut((t - 0.5) * 2)
                    PlateHalf(text: now, side: side, upper: false, shade: 1 - land)
                        .rotation3DEffect(.degrees(90 * (1 - land)), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.35)
                }
            }
            .frame(height: half)
            .zIndex(t >= 0.5 ? 1 : 0)
        }
        .frame(width: side, height: side)
        .overlay {
            // 中缝
            Rectangle().fill(.black).frame(height: max(3, side * 0.011))
        }
    }

    private static func easeIn(_ x: Double) -> Double { x * x }
    private static func easeOut(_ x: Double) -> Double { 1 - (1 - x) * (1 - x) }
}

/// 牌的上半片或下半片（整块牌画好，只露一半）；shade 是翻起来背着光暗下去多少（0 不暗，1 最暗）
private struct PlateHalf: View {
    let text: String
    let side: CGFloat
    let upper: Bool
    var shade: Double = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.085, style: .circular).fill(Color(white: 0x0E / 255))
            // 数字和外面那圈描边合成一个形状，只填一次：淡入淡出时不会再先亮出字里面那一圈（填色和描边叠着的地方）
            FlipNumerals.solid(text, side: side).fill(FlipClockFace.digitColor)
            if shade > 0 { Color.black.opacity(shade * 0.6) }
        }
        .compositingGroup()   // 翻页时这半片自己暗下去，也是整片一起，不透出描边
        .frame(width: side, height: side)
        .frame(width: side, height: side / 2, alignment: upper ? .top : .bottom)
        .clipped()
    }
}

/// 翻页牌上的数字：Helvetica 粗体（系统自带），压窄到 0.77，字距稍放开一点（描边会吃掉两个数字之间的缝），
/// 水平居中，数字的高度正好以中缝为中心
enum FlipNumerals {
    static let fontName = "Helvetica-Bold"

    /// 数字加一圈描边（比粗体再粗一点、宽一点，像翻页钟的数字；描太粗会把 0、6、9 的洞糊上），
    /// 合成一个形状。一分钟才变一次，翻页那半秒每帧都要画，所以按"字 + 大小"记住，最多记十几个
    @MainActor private static var solids: [String: Path] = [:]

    @MainActor static func solid(_ text: String, side: CGFloat) -> Path {
        let key = "\(text)|\(side)"
        if let cached = solids[key] { return cached }
        let digits = path(text, side: side).cgPath
        let rim = digits.copy(strokingWithWidth: side * 0.028, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        let shape = Path(digits.union(rim))
        if solids.count > 16 { solids.removeAll() }
        solids[key] = shape
        return shape
    }

    static func path(_ text: String, side: CGFloat) -> Path {
        let font = CTFontCreateWithName(fontName as CFString, side, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): side * 0.015,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let glyphs = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, at) in zip(ids, positions) {
                guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                glyphs.addPath(outline, transform: CGAffineTransform(translationX: at.x, y: at.y))
            }
        }
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        // 用"0"量数字的上下沿，所有数字都按它居中（不然 1 和 7 会一个个上下跳）
        let zero = digitBounds(font)
        let scale: CGFloat = 0.77
        // 字形是 y 朝上的；翻过来、压窄、挪到牌的正中
        var transform = CGAffineTransform(translationX: side / 2, y: side / 2)
            .scaledBy(x: scale, y: -1)
            .translatedBy(x: -width / 2, y: -zero.midY)
        return Path(glyphs.copy(using: &transform) ?? glyphs)
    }

    private static func digitBounds(_ font: CTFont) -> CGRect {
        var glyph: CGGlyph = 0
        var zero: UniChar = 0x30
        CTFontGetGlyphsForCharacters(font, &zero, &glyph, 1)
        return CTFontCreatePathForGlyph(font, glyph, nil)?.boundingBoxOfPath ?? CGRect(x: 0, y: 0, width: 0, height: CTFontGetCapHeight(font))
    }
}
