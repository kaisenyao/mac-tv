import SwiftUI
import WebKit

/// 登录页上两块的位置（1920×1080 画布上；窗口不是 16:9 时整体居中）。网页那块要按同一个位置放到窗口上，所以单独算
struct BiliLoginLayout {
    let qr: CGRect
    let form: CGRect
    /// 网页放在右边那块里面，四周让出圆角
    var web: CGRect { form.insetBy(dx: 12, dy: 12) }

    init(canvas: CGSize) {
        let width: CGFloat = 1568, height: CGFloat = 740
        let left = (canvas.width - width) / 2, top = 220 + (canvas.height - 1080) / 2
        qr = CGRect(x: left, y: top, width: 600, height: height)
        form = CGRect(x: left + 640, y: top, width: width - 640, height: height)
    }

    /// 和 TVCanvas 一样的比例：1920×1080 的画布放到窗口上
    static func scale(for window: CGSize) -> CGFloat {
        let width = max(window.width, 1), height = max(window.height, 1)
        return width / height < 16 / 9 ? width / 1920 : height / 1080
    }
}

/// 登录页：原生画的部分在画布上，右边的网页按同样的位置放在窗口上（网页不能跟着画布一起缩放，改用网页自己的缩放）
struct BilibiliLoginScreen: View {
    @ObservedObject var page: BiliLoginPage

    var body: some View {
        GeometryReader { geo in
            let scale = BiliLoginLayout.scale(for: geo.size)
            let rect = BiliLoginLayout(canvas: CGSize(width: geo.size.width / scale, height: geo.size.height / scale)).web
            ZStack(alignment: .topLeading) {
                TVCanvas { BiliLoginCanvas(page: page, qr: page.qr) }
                if let web = page.web {
                    BiliLoginWeb(web: web, zoom: BilibiliLoginPage.zoom * scale)
                        .frame(width: rect.width * scale, height: rect.height * scale)
                        .padding(.leading, rect.minX * scale)
                        .padding(.top, rect.minY * scale)
                        .opacity(page.formReady && !page.formFailed ? 1 : 0)
                        .allowsHitTesting(page.formReady && !page.formFailed)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

/// 右边的网页：缩放跟着窗口走（画布上 1 点 = 网页里 1/zoom 像素）
private struct BiliLoginWeb: NSViewRepresentable {
    let web: WKWebView
    let zoom: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        web.pageZoom = zoom
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if abs(web.pageZoom - zoom) > 0.001 { web.pageZoom = zoom }
    }
}

/// 登录页原生画的部分：背景、字标、左边的二维码、右边那块的底和焦点框
private struct BiliLoginCanvas: View {
    @ObservedObject var page: BiliLoginPage
    @ObservedObject var qr: BiliQRLogin
    @Environment(\.canvasSize) private var canvas
    private let pink = Color(hex: "#FB7299")

    var body: some View {
        let layout = BiliLoginLayout(canvas: canvas)
        ZStack(alignment: .topLeading) {
            backdrop
            logo
                .padding(.leading, layout.qr.minX)
                .padding(.top, 64)
            qrPanel
                .frame(width: layout.qr.width, height: layout.qr.height)
                .offset(x: layout.qr.minX, y: layout.qr.minY)
            formPanel
                .frame(width: layout.form.width, height: layout.form.height)
                .offset(x: layout.form.minX, y: layout.form.minY)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    /// 和列表页一样的深色底，左上角一点粉色的光（不动）
    private var backdrop: some View {
        ZStack {
            Color(hex: "#0B0B10")
            RadialGradient(colors: [pink.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 1300)
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    @ViewBuilder private var logo: some View {
        if let logo = BilibiliScreen.logo {
            Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 64)
        } else {
            Text("bilibili").font(.system(size: 52, weight: .heavy, design: .rounded)).foregroundStyle(pink)
        }
    }

    /// 两块的底：选中的那块加白框（和卡片选中一样）
    private func panel(focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
        return shape.fill(Color(hex: BilibiliLoginPage.background))
            .overlay(shape.strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 5 : 1.5))
            .shadow(color: .black.opacity(focused ? 0.55 : 0.3), radius: focused ? 34 : 20, y: focused ? 20 : 10)
            .animation(Motion.focus, value: focused)
    }

    // MARK: 左边：扫码登录

    private var qrPanel: some View {
        VStack(spacing: 0) {
            Text("扫码登录")
                .font(.tv(.headline, emphasized: true))
                .foregroundStyle(.white)
                .padding(.top, 52)
            qrCard
                .padding(.top, 42)
            Text("使用哔哩哔哩 App 扫码登录")
                .font(.tv(.body))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.top, 40)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background { panel(focused: page.side == .qr) }
        .contentShape(Rectangle())
        .onTapGesture { page.tapQR() }
    }

    /// 白底上的二维码；扫过了、过期了、取不到时把码压淡，上面写现在怎么了
    private var qrCard: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let note = note(for: qr.state)
        return ZStack {
            shape.fill(.white)
            if let matrix = qr.matrix, qr.state != .loading, qr.state != .failed {
                BiliQRShape(matrix: matrix)
                    .fill(.black)
                    .padding(34)
                    .opacity(note == nil ? 1 : 0.1)
            }
            if qr.state == .loading {
                ProgressView().controlSize(.large).colorScheme(.light)
            } else if let note {
                VStack(spacing: 14) {
                    Image(systemName: note.symbol)
                        .font(.system(size: 76, weight: .medium))
                        .foregroundStyle(note.tint)
                    Text(note.title)
                        .font(.tv(.headline, emphasized: true))
                        .foregroundStyle(.black)
                    if let detail = note.detail {
                        Text(detail)
                            .font(.tv(.body))
                            .foregroundStyle(.black.opacity(0.6))
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(width: 420, height: 420)
        .animation(.easeOut(duration: 0.2), value: qr.state)
    }

    private struct Note {
        let symbol: String
        let title: String
        let detail: String?
        let tint: Color
    }

    private func note(for state: BiliQRLogin.State) -> Note? {
        switch state {
        case .loading, .waiting: nil
        case .scanned: Note(symbol: "checkmark.circle.fill", title: "扫码成功", detail: "请在手机上确认", tint: pink)
        case .expired: Note(symbol: "arrow.clockwise.circle.fill", title: "二维码已失效", detail: "按确认刷新", tint: .black.opacity(0.75))
        case .failed: Note(symbol: "wifi.exclamationmark", title: "无法获取二维码", detail: "按确认重试", tint: .black.opacity(0.75))
        case .done: Note(symbol: "checkmark.circle.fill", title: "登录成功", detail: nil, tint: pink)
        }
    }

    // MARK: 右边：哔哩哔哩自己的登录表单（网页盖在这块上面，这里只画底、焦点框，和载入中、载不出来时的样子）

    private var formPanel: some View {
        ZStack {
            if page.formFailed {
                VStack(spacing: 22) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 72))
                    Text("无法载入").font(.tv(.headline, emphasized: true))
                    Text("按确认重试").font(.tv(.body)).opacity(0.7)
                }
                .foregroundStyle(.white)
            } else if !page.formReady {
                ProgressView().controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { panel(focused: page.side == .form) }
    }
}
