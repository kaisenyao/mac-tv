// Measures a picture: Apple's screenshots from the guide (scripts/tvos-guide.py) and Mac TV's own renders, to compare
// sizes and positions. Build it once, then run it:
//
//   swiftc -O scripts/px.swift -o /tmp/px
//   /tmp/px size  picture.png                          width and height
//   /tmp/px crop  picture.png out.png x y w h [scale] [grid]   a part of it, enlarged (pixels kept sharp), with a
//                                                      line every `grid` source pixels (every fifth one stronger)
//   /tmp/px erow  picture.png y x0 x1 threshold        where brightness jumps along a row: an edge's x
//   /tmp/px ecol  picture.png x y0 y1 threshold        the same down a column: an edge's y
//   /tmp/px bbox  picture.png x y w h threshold        the box around everything brighter than the threshold (text, a glyph)
//   /tmp/px row | col | rgb                            the brightness along a row or a column, a pixel's colour
//
// A guide screenshot is about 1144 px wide with a pixel or two of border, the screen in it about 1142: multiply by
// 1.681 for points on Mac TV's 1920-wide canvas. Mac TV's renders are 3840 wide: divide by 2.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func load(_ path: String) -> (CGImage, [UInt8], Int, Int) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("cannot load \(path)") }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (img, buf, w, h)
}
func save(_ img: CGImage, _ path: String) {
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
}
let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: px cmd image ..."); exit(1) }
let cmd = a[1]
let (img, buf, w, h) = load(a[2])
func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(buf[i]), Int(buf[i+1]), Int(buf[i+2])) }
func lum(_ x: Int, _ y: Int) -> Int { let (r, g, b) = px(x, y); return (r * 299 + g * 587 + b * 114) / 1000 }
switch cmd {
case "size": print(w, h)
case "crop": // px crop in out x y w h scale [grid]
    let x = Int(a[4])!, y = Int(a[5])!, cw = Int(a[6])!, ch = Int(a[7])!, s = a.count > 8 ? Int(a[8])! : 3
    let grid = a.count > 9 ? Int(a[9])! : 0
    let sub = img.cropping(to: CGRect(x: x, y: y, width: cw, height: ch))!
    let ctx = CGContext(data: nil, width: cw * s, height: ch * s, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(sub, in: CGRect(x: 0, y: 0, width: cw * s, height: ch * s))
    if grid > 0 { // grid lines every `grid` source px, labelled by brightness alternation
        ctx.setLineWidth(1)
        var gx = (x / grid + 1) * grid
        while gx < x + cw { ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 1, alpha: gx % (grid * 5) == 0 ? 0.9 : 0.35)); let p = CGFloat((gx - x) * s); ctx.move(to: CGPoint(x: p, y: 0)); ctx.addLine(to: CGPoint(x: p, y: CGFloat(ch * s))); ctx.strokePath(); gx += grid }
        var gy = (y / grid + 1) * grid
        while gy < y + ch { ctx.setStrokeColor(CGColor(red: 0, green: 1, blue: 1, alpha: gy % (grid * 5) == 0 ? 0.9 : 0.35)); let p = CGFloat(ch * s) - CGFloat((gy - y) * s); ctx.move(to: CGPoint(x: 0, y: p)); ctx.addLine(to: CGPoint(x: CGFloat(cw * s), y: p)); ctx.strokePath(); gy += grid }
    }
    save(ctx.makeImage()!, a[3])
case "row": // px row in y x0 x1 -> luminance list
    let y = Int(a[3])!, x0 = Int(a[4])!, x1 = Int(a[5])!
    print((x0...x1).map { String(lum($0, y)) }.joined(separator: " "))
case "col":
    let x = Int(a[3])!, y0 = Int(a[4])!, y1 = Int(a[5])!
    print((y0...y1).map { String(lum(x, $0)) }.joined(separator: " "))
case "rgb": // px rgb in x y
    print(px(Int(a[3])!, Int(a[4])!))
case "erow": // edges along a row: px erow in y x0 x1 thresh
    let y = Int(a[3])!, x0 = Int(a[4])!, x1 = Int(a[5])!, t = Int(a[6])!
    var out: [String] = []
    for x in (x0 + 1)...x1 { let d = lum(x, y) - lum(x - 1, y); if abs(d) >= t { out.append("\(x):\(d > 0 ? "+" : "")\(d)") } }
    print(out.joined(separator: " "))
case "ecol":
    let x = Int(a[3])!, y0 = Int(a[4])!, y1 = Int(a[5])!, t = Int(a[6])!
    var out: [String] = []
    for y in (y0 + 1)...y1 { let d = lum(x, y) - lum(x, y - 1); if abs(d) >= t { out.append("\(y):\(d > 0 ? "+" : "")\(d)") } }
    print(out.joined(separator: " "))
case "bbox": // bounding box of pixels brighter than thresh inside rect: px bbox in x y w h thresh
    let x0 = Int(a[3])!, y0 = Int(a[4])!, cw = Int(a[5])!, ch = Int(a[6])!, t = Int(a[7])!
    var minx = Int.max, maxx = -1, miny = Int.max, maxy = -1
    for y in y0..<(y0 + ch) { for x in x0..<(x0 + cw) where lum(x, y) >= t { minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y) } }
    print("x \(minx)...\(maxx) (w \(maxx - minx + 1))  y \(miny)...\(maxy) (h \(maxy - miny + 1))")
default: print("unknown")
}
