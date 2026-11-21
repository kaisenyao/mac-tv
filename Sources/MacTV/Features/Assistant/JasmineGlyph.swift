import SwiftUI

/// 小茗同学 as a symbol, for where she is one button among symbols (Control Center's round button): her ball in
/// outline with the tide filling it under a slow, shallow wave, a little higher on the left (Apple TV draws Siri's own
/// symbol as a ball with a wave across it; hers is her orb's tide, and gentle: a steep one reads as yin and yang).
/// One colour and the weight of the SF Symbols beside it, so it takes the button's colour as they do.
struct JasmineGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height), line = side * 0.1
        let centre = CGPoint(x: rect.midX, y: rect.midY), radius = side / 2 - line / 2
        let ball = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            .strokedPath(StrokeStyle(lineWidth: line))
        // The tide: from the wave, just under the middle, down to the ball's edge
        let level = centre.y + side * 0.02, swell = side * 0.17
        let reach = (radius * radius - (level - centre.y) * (level - centre.y)).squareRoot()
        let angle = asin((level - centre.y) / radius)
        var tide = Path()
        tide.move(to: CGPoint(x: centre.x - reach, y: level))
        tide.addCurve(to: CGPoint(x: centre.x + reach, y: level),
                      control1: CGPoint(x: centre.x - reach / 3, y: level - swell),
                      control2: CGPoint(x: centre.x + reach / 3, y: level + swell))
        tide.addArc(center: centre, radius: radius, startAngle: .radians(angle), endAngle: .radians(.pi - angle), clockwise: false)
        tide.closeSubpath()
        // One outline of the two: laid one over the other they would cancel where they overlap, along the ball's line
        return ball.union(tide)
    }
}
