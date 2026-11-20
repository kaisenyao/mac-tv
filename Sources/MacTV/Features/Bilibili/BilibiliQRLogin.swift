import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI
import WebKit

/// 网页版扫码登录给的一张二维码：码里写的地址（手机 App 扫它）和问状态用的编号
struct BiliQRCode: Equatable, Sendable {
    let url: String
    let key: String
}

/// 问一次"扫了没有"的回答
enum BiliQRPoll: Equatable, Sendable {
    /// 还没扫（86101）
    case waiting
    /// 扫了，等手机上点确认（86090）
    case scanned
    /// 二维码过期了（86038）
    case expired
    /// 手机上确认了：哔哩哔哩发下来的登录信息（只有哔哩哔哩自己的 cookie）
    case signedIn([HTTPCookie])
    /// 没问到（网络、看不懂的回答）：下一次接着问
    case unknown
}

/// 扫码登录要用的两个接口。测试里换成假的，不联网、不登录真的账号
protocol BiliQRService: Sendable {
    func generate() async -> BiliQRCode?
    func poll(_ key: String) async -> BiliQRPoll
}

/// 哔哩哔哩网页版自己的扫码登录（passport.bilibili.com/x/passport-login/web/qrcode/…）。
/// 登录信息（cookie）只从回答里收下来交给 BiliQRLogin，不落进系统的 cookie 仓库，也不打印
struct BiliQRWeb: BiliQRService {
    private static let base = "https://passport.bilibili.com/x/passport-login/web/qrcode/"

    /// 不带、不存任何 cookie 的连接：登录信息由我们自己放进这个人的网页数据（见 BilibiliStore.saveLogin）
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    func generate() async -> BiliQRCode? {
        guard let url = URL(string: Self.base + "generate"), let (json, _) = await Self.get(url) else { return nil }
        return Self.code(from: json)
    }

    func poll(_ key: String) async -> BiliQRPoll {
        var parts = URLComponents(string: Self.base + "poll")
        parts?.queryItems = [URLQueryItem(name: "qrcode_key", value: key)]
        guard let url = parts?.url, let (json, response) = await Self.get(url) else { return .unknown }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { all, field in
            if let name = field.key as? String, let value = field.value as? String { all[name] = value }
        }
        return Self.poll(from: json, cookies: HTTPCookie.cookies(withResponseHeaderFields: headers, for: url))
    }

    private static func get(_ url: URL) async -> ([String: Any], HTTPURLResponse)? {
        var request = URLRequest(url: url)
        request.setValue(UserAgent.safari, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json, http)
    }

    /// generate 的回答：{"code":0,"data":{"url":"https://account.bilibili.com/…","qrcode_key":"…"}}
    static func code(from json: [String: Any]) -> BiliQRCode? {
        guard (json["code"] as? Int) == 0, let data = json["data"] as? [String: Any],
              let url = data["url"] as? String, !url.isEmpty,
              let key = data["qrcode_key"] as? String, !key.isEmpty else { return nil }
        return BiliQRCode(url: url, key: key)
    }

    /// poll 的回答：外面的 code 是接口本身，data.code 才是扫码的状态。
    /// 登录成功时登录信息在回答的 Set-Cookie 里；万一没有，网页版跳转的地址里也带着同样几样
    static func poll(from json: [String: Any], cookies: [HTTPCookie]) -> BiliQRPoll {
        guard (json["code"] as? Int) == 0, let data = json["data"] as? [String: Any], let code = data["code"] as? Int else { return .unknown }
        switch code {
        case 0:
            var found = cookies.filter(\.isBilibili)
            if !found.contains(where: { $0.name == "SESSDATA" }) { found = Self.cookies(fromRedirect: data["url"] as? String) }
            return found.contains { $0.name == "SESSDATA" } ? .signedIn(found) : .unknown
        case 86090: return .scanned
        case 86101: return .waiting
        case 86038: return .expired
        default: return .unknown
        }
    }

    /// 登录成功时 data.url 是网页版接着要去的地址，参数里有 DedeUserID、DedeUserID__ckMd5、SESSDATA、bili_jct 和过期时间。
    /// 照网页版的样子做成 .bilibili.com 的 cookie（值保持原样，和网页版存的一样）
    static func cookies(fromRedirect address: String?) -> [HTTPCookie] {
        guard let address, let items = URLComponents(string: address)?.percentEncodedQueryItems else { return [] }
        let names: Set<String> = ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct", "sid"]
        let expiresValue = items.first { $0.name == "Expires" }?.value.flatMap(Double.init) ?? 0
        let expires = expiresValue > 1_000_000_000 ? Date(timeIntervalSince1970: expiresValue)
            : Date().addingTimeInterval(expiresValue > 0 ? expiresValue : 180 * 24 * 3600)
        return items.compactMap { item in
            guard names.contains(item.name), let value = item.value, !value.isEmpty else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [.domain: ".bilibili.com", .path: "/", .name: item.name, .value: value,
                                                            .expires: expires, .secure: "TRUE"]
            if item.name == "SESSDATA" { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }
}

/// 登录页左边的扫码登录：取一张二维码，开着的时候每两秒问一次扫了没有，过期了停下等人按确认再取。
/// 页面关了（stop）就不再问；整个过程没有一直在动的东西
@MainActor
final class BiliQRLogin: ObservableObject {
    enum State: Equatable {
        /// 正在取二维码
        case loading
        /// 等着扫（二维码的内容）
        case waiting(String)
        /// 扫了，等手机上确认（二维码还画着，盖一层提示）
        case scanned(String)
        /// 过期了：按确认刷新
        case expired
        /// 取不到二维码（网络）：按确认重试
        case failed
        /// 登录成功
        case done
    }

    @Published private(set) var state = State.loading
    /// 二维码的点阵（换了一张才重新算）
    private(set) var matrix: BiliQRMatrix?
    /// 手机上确认了：把登录信息交出去（存进这个人的网页数据，回到列表）
    var signedIn: (([HTTPCookie]) async -> Void)?

    private let service: BiliQRService
    private let interval: Duration
    private let lifetime: Duration
    private var task: Task<Void, Never>?

    /// lifetime：二维码能用多久（哔哩哔哩是 180 秒），到点不再问，当作过期
    init(service: BiliQRService = BiliQRWeb(), interval: Duration = .seconds(2), lifetime: Duration = .seconds(180)) {
        self.service = service
        self.interval = interval
        self.lifetime = lifetime
    }

    /// 正在取二维码或正在问
    var running: Bool { task != nil }

    /// 取一张新的二维码，开始问
    func start() {
        task?.cancel()
        state = .loading
        task = Task { [weak self] in await self?.run() }
    }

    /// 页面关了：不再问
    func stop() {
        task?.cancel()
        task = nil
    }

    /// 过期了、没取到：按确认重新取一张（还在用的那张不换）
    func refresh() {
        guard state == .expired || state == .failed else { return }
        start()
    }

    private func run() async {
        guard let code = await service.generate() else {
            if !Task.isCancelled { finish(.failed) }
            return
        }
        guard !Task.isCancelled else { return }
        matrix = BiliQRMatrix(code.url)
        state = .waiting(code.url)
        let clock = ContinuousClock()
        let deadline = clock.now + lifetime
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return }
            if clock.now >= deadline { finish(.expired); return }
            let answer = await service.poll(code.key)
            guard !Task.isCancelled else { return }
            switch answer {
            case .waiting: state = .waiting(code.url)   // 手机上点了取消：回到等着扫
            case .scanned: state = .scanned(code.url)
            case .expired: finish(.expired); return
            case .signedIn(let cookies):
                finish(.done)
                await signedIn?(cookies)
                return
            case .unknown: continue
            }
        }
    }

    private func finish(_ final: State) {
        state = final
        task = nil
    }

    /// 测试、截图用：当作已经取到了这张二维码，停在这个状态（不联网）。过期等状态沿用刚才那张码
    func pretend(_ state: State) {
        stop()
        switch state {
        case .waiting(let link), .scanned(let link): matrix = BiliQRMatrix(link)
        default: if matrix == nil { matrix = BiliQRMatrix("https://account.bilibili.com/h5/account-h5/auth/scan-web?qrcode_key=0") }
        }
        self.state = state
    }
}

extension BiliQRLogin {
    /// 登录信息放进这个人的网页数据（和网页里登录存的是同一个地方、同样的名字和域名，别处读的就是这里）。
    /// 只放哔哩哔哩自己的
    static func save(_ cookies: [HTTPCookie], in store: WKHTTPCookieStore) async {
        for cookie in cookies where cookie.isBilibili { await store.setCookie(cookie) }
    }
}

/// 二维码的点阵：CoreImage 生成，一格一个点；画的时候按格子画成矢量（多大都清楚）
struct BiliQRMatrix: Equatable {
    /// 一边几格（不含四周的空白）
    let size: Int
    /// 从左上角起一行一行：这一格是不是黑的
    let dark: [Bool]

    init?(_ text: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, width == height else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        CIContext().render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var cells = (0..<(width * height)).map { pixels[$0 * 4] < 128 }
        // 去掉 CoreImage 自己留的空白边（四周的空白由白色底板留）
        let rows = (0..<height).filter { y in (0..<width).contains { cells[y * width + $0] } }
        let columns = (0..<width).filter { x in (0..<height).contains { cells[$0 * width + x] } }
        guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last,
              bottom - top == right - left else { return nil }
        let size = bottom - top + 1
        cells = (top...bottom).flatMap { y in (left...right).map { cells[y * width + $0] } }
        // 三个定位角在左上、右上、左下。读出来的行序万一是从下往上的（右下角是定位角），翻过来
        if Self.finder(in: cells, size: size, x: size - 7, y: size - 7), !Self.finder(in: cells, size: size, x: size - 7, y: 0) {
            cells = (0..<size).reversed().flatMap { y in cells[(y * size)..<(y * size + size)] }
        }
        self.size = size
        dark = cells
    }

    subscript(x: Int, y: Int) -> Bool { dark[y * size + x] }

    /// (x, y) 起的 7×7 是不是一个定位角（外圈黑、里一圈白、中间 3×3 黑）
    static func finder(in cells: [Bool], size: Int, x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x + 7 <= size, y + 7 <= size else { return false }
        for dy in 0..<7 {
            for dx in 0..<7 {
                let ring = max(abs(dx - 3), abs(dy - 3))
                if cells[(y + dy) * size + x + dx] != (ring != 2) { return false }
            }
        }
        return true
    }
}

/// 二维码画成矢量：一行里连着的黑格并成一条，整个是一条路径（相邻的格子之间不会有缝）
struct BiliQRShape: Shape {
    let matrix: BiliQRMatrix

    func path(in rect: CGRect) -> Path {
        let cell = min(rect.width, rect.height) / CGFloat(matrix.size)
        var path = Path()
        for y in 0..<matrix.size {
            var x = 0
            while x < matrix.size {
                guard matrix[x, y] else { x += 1; continue }
                let start = x
                while x < matrix.size, matrix[x, y] { x += 1 }
                path.addRect(CGRect(x: rect.minX + CGFloat(start) * cell, y: rect.minY + CGFloat(y) * cell,
                                    width: CGFloat(x - start) * cell, height: cell))
            }
        }
        return path
    }
}
