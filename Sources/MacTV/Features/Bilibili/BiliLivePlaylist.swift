@preconcurrency import AVFoundation
import Foundation

/// 直播的一份播放列表（HLS 的 media playlist）：读进来、把地址改成绝对的、和上一份接起来、再写出去。
///
/// 为什么要自己经手：哔哩哔哩的直播列表一段只有 1 秒、一份只列 6～7 段（大约 7 秒），CDN 的边缘节点有时候
/// 答一份存了 2～3 秒的旧列表（回复头 age: 2、3，序号没往前走）。系统播放器按规矩只在离最新一段 3 段的地方放，
/// 旧列表一来手里就没得放了，于是隔几秒卡一下。所以列表由我们来取（不让 CDN 用存着的、旧的就再取一次），
/// 并且把刚滑出去的段多留一会儿（CDN 上那些段还能下好几分钟），播放器就能稳稳地落后几秒放，网一抖也有余量
struct BiliLivePlaylist: Equatable {
    /// 交出去的列表最多留多少秒。实测（2026-11，room 22747736，d1--ov-gotcha207 这几台）：
    /// 段滑出列表后 280 秒内都还能下（300 秒时 404），留 30 秒有好几倍的余量
    static let keep = 30.0

    struct Segment: Equatable {
        let sequence: Int
        /// 这一段前面的标签（哔哩哔哩自己的 EXT-BILI-AUX、EXTINF……），原样带着；EXTINF 总在最后
        let tags: [String]
        let duration: Double
        /// 段的地址（绝对的 https，播放器直接去 CDN 取）
        let uri: String
        /// 这一段用的初始化段（EXT-X-MAP 那一行，地址已经改成绝对的）
        let map: String?
        /// 这一段的不连续序号（EXT-X-DISCONTINUITY 一次加一）
        let discontinuity: Int
    }

    /// 整份的标签（版本、每段最长几秒这些）。序号、开始位置、MAP、ENDLIST 由写出去时自己写
    var header: [String]
    var segments: [Segment]
    /// 列表最后有 EXT-X-ENDLIST：直播结束了
    var ended: Bool

    var lastSequence: Int { segments.last?.sequence ?? -1 }
    var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    private static let headerTags = ["#EXT-X-VERSION", "#EXT-X-TARGETDURATION", "#EXT-X-PLAYLIST-TYPE", "#EXT-X-INDEPENDENT-SEGMENTS"]

    /// 读一份 media playlist；base 是它自己的地址（相对的段地址按它补全）。不是 m3u8、或者其实是总表时是 nil
    static func parse(_ text: String, base: URL) -> BiliLivePlaylist? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U", !lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else { return nil }
        var playlist = BiliLivePlaylist(header: [], segments: [], ended: false)
        var sequence = 0, discontinuity = 0, duration = 0.0
        var map: String?
        var pending: [String] = []
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                discontinuity = Int(line.dropFirst("#EXT-X-DISCONTINUITY-SEQUENCE:".count)) ?? 0
            } else if line == "#EXT-X-DISCONTINUITY" {
                if !playlist.segments.isEmpty { discontinuity += 1 }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                map = rewritingURI(in: line, base: base)
            } else if line == "#EXT-X-ENDLIST" {
                playlist.ended = true
            } else if line.hasPrefix("#EXT-X-START:") {
                continue   // 从哪开始放由播放器的 configuredTimeOffsetFromLive 定
            } else if headerTags.contains(where: { line.hasPrefix($0) }) {
                playlist.header.append(line)
            } else if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    duration = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," }) ?? 0
                }
                pending.append(line)
            } else if let uri = absolute(line, base: base) {
                playlist.segments.append(Segment(sequence: sequence + playlist.segments.count, tags: pending, duration: duration,
                                                 uri: uri, map: map, discontinuity: discontinuity))
                pending = []
                duration = 0
            }
        }
        return playlist
    }

    /// 取到的这一份是不是旧的：CDN 说它已经存了一秒以上（age），或者它的最后一段比交出去的上一份还早
    static func isStale(_ fresh: BiliLivePlaylist, age: Int, comparedTo previous: BiliLivePlaylist?) -> Bool {
        age > 1 || fresh.lastSequence < (previous?.lastSequence ?? -1)
    }

    /// 接在交出去的上一份后面：上一份里比这一份更早的段留着，最多留到 keep 秒（这一份里的段一个不少）。
    /// 这一份比上一份还旧时是 nil（不能交给播放器一份往回走的列表）；和上一份接不上（中间断了、换了流）就从这一份重新开始
    func merged(after previous: BiliLivePlaylist?, keep: Double = Self.keep) -> BiliLivePlaylist? {
        guard let previous, let first = segments.first else { return self }
        guard lastSequence >= previous.lastSequence else { return nil }
        guard let start = previous.segments.first?.sequence, first.sequence >= start, first.sequence <= previous.lastSequence + 1 else { return self }
        var total = duration
        var older: [Segment] = []
        for segment in previous.segments.reversed() where segment.sequence < first.sequence {
            guard total + segment.duration <= keep else { break }
            older.insert(segment, at: 0)
            total += segment.duration
        }
        var result = self
        result.segments = older + segments
        return result
    }

    /// 写成交给播放器的样子
    var text: String {
        var lines = ["#EXTM3U"] + header
        if let first = segments.first {
            lines.append("#EXT-X-MEDIA-SEQUENCE:\(first.sequence)")
            if first.discontinuity > 0 { lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(first.discontinuity)") }
        }
        var previous: Segment?
        for segment in segments {
            if let previous, segment.discontinuity != previous.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            if let map = segment.map, map != previous?.map { lines.append(map) }
            lines += segment.tags + [segment.uri]
            previous = segment
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: 总表

    /// 万一给的是总表（几种清晰度各一份列表）：每一份的地址换成 bililive://live/variant-N.m3u8，也走我们这里取；
    /// 真的地址按 N 的顺序返回。不是总表时是 nil
    static func rewriteMaster(_ text: String, base: URL) -> (text: String, variants: [URL])? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U", lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else { return nil }
        var variants: [URL] = []
        func route(_ uri: String) -> String {
            guard let url = URL(string: uri, relativeTo: base)?.absoluteURL else { return uri }
            variants.append(url)
            return "\(BiliHLS.LiveLoader.scheme)://live/variant-\(variants.count - 1).m3u8"
        }
        var output: [String] = []
        var expectingURI = false
        for line in lines {
            if line.hasPrefix("#") {
                expectingURI = line.hasPrefix("#EXT-X-STREAM-INF")
                output.append(line.contains("URI=\"") ? replacingURI(in: line, with: route) : line)
            } else if expectingURI {
                output.append(route(line))
                expectingURI = false
            } else {
                output.append(line)
            }
        }
        return (output.joined(separator: "\n") + "\n", variants)
    }

    // MARK: 地址

    private static func absolute(_ uri: String, base: URL) -> String? {
        URL(string: uri, relativeTo: base)?.absoluteURL.absoluteString
    }

    /// 标签里 URI="…" 的那一段换成绝对地址
    private static func rewritingURI(in line: String, base: URL) -> String {
        replacingURI(in: line) { absolute($0, base: base) ?? $0 }
    }

    private static func replacingURI(in line: String, with transform: (String) -> String) -> String {
        guard let open = line.range(of: "URI=\""), let close = line[open.upperBound...].firstIndex(of: "\"") else { return line }
        return line[..<open.upperBound] + transform(String(line[open.upperBound..<close])) + line[close...]
    }
}

extension BiliHLS {
    /// 直播的播放列表经过这里（自定义地址 bililive://），画面和声音的片段播放器自己直接去 CDN 取。
    /// 每次播放器来要列表，都现去取一份（不让 CDN 用存着的），旧的就再取一次，接在交出去的上一份后面再给它
    final class LiveLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        static let scheme = "bililive"
        /// 交给系统播放器的地址：真的地址带着签名，只在这里面用
        static let entry = URL(string: "\(scheme)://live/index.m3u8")!

        private let state: LiveState

        init(source: URL) { state = LiveState(source: source) }

        /// 到现在为止的计数（给日志用：只有次数、秒数，没有地址）
        func stats() async -> LiveStats { await state.stats }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
            guard let url = request.request.url, url.scheme == Self.scheme else { return false }
            let pending = Pending(request: request), name = url.lastPathComponent
            Task { [state] in pending.finish(with: await state.playlist(named: name)) }
            return true
        }

        /// 播放器来要的那一次（交给别的线程去答）
        private struct Pending: @unchecked Sendable {
            let request: AVAssetResourceLoadingRequest

            func finish(with data: Data?) {
                guard !request.isCancelled else { return }
                guard let data else {
                    request.finishLoading(with: URLError(.cannotLoadFromNetwork))
                    return
                }
                request.contentInformationRequest?.contentType = "public.m3u-playlist"
                request.contentInformationRequest?.contentLength = Int64(data.count)
                request.contentInformationRequest?.isByteRangeAccessSupported = false
                request.dataRequest?.respond(with: data)
                request.finishLoading()
            }
        }
    }

    struct LiveStats: Sendable {
        /// 取了几次列表；其中几次是旧的（又取了一次）、几次取完还是旧的（交了上一份）、几次没取到
        var fetched = 0, stale = 0, keptPrevious = 0, failed = 0
        /// 交出去的列表现在有几段、多少秒
        var segments = 0, seconds = 0.0
    }

    /// 列表的状态：交出去的上一份（总表时每一种清晰度各一份）、计数
    actor LiveState {
        private let source: URL
        private var variants: [URL] = []
        private var handedOut: [String: BiliLivePlaylist] = [:]
        private(set) var stats = LiveStats()

        init(source: URL) { self.source = source }

        func playlist(named name: String) async -> Data? {
            let url: URL
            if name.hasPrefix("variant-"), let index = Int(name.dropFirst("variant-".count).prefix { $0.isNumber }),
               variants.indices.contains(index) {
                url = variants[index]
            } else {
                url = source
            }
            guard var fetched = await Self.fetch(url) else {
                stats.failed += 1
                return handedOut[name].map { Data($0.text.utf8) }   // 没取到：先给上一份，播放器过一会儿再来要
            }
            stats.fetched += 1
            if let master = BiliLivePlaylist.rewriteMaster(fetched.text, base: url) {
                variants = master.variants
                return Data(master.text.utf8)
            }
            guard var fresh = BiliLivePlaylist.parse(fetched.text, base: url) else { return nil }
            if BiliLivePlaylist.isStale(fresh, age: fetched.age, comparedTo: handedOut[name]) {
                // CDN 给了一份旧的：不让它用存着的，再取一次（只一次，不然播放器等太久）
                stats.stale += 1
                if let again = await Self.fetch(url), let newer = BiliLivePlaylist.parse(again.text, base: url),
                   newer.lastSequence >= fresh.lastSequence {
                    fetched = again
                    fresh = newer
                }
            }
            guard let merged = fresh.merged(after: handedOut[name]) else {
                stats.keptPrevious += 1   // 还是比交出去的旧：给上一份，不往回走
                return handedOut[name].map { Data($0.text.utf8) }
            }
            handedOut[name] = merged
            stats.segments = merged.segments.count
            stats.seconds = merged.duration
            return Data(merged.text.utf8)
        }

        /// 取一份列表，带上"不要存着的"（实测这样 8 次里 8 次都是 age: 0），用不存东西的连接（见 probeSession）。
        /// 不带账号：直播的段和列表都不认登录
        private static func fetch(_ url: URL) async -> (text: String, age: Int)? {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 3)
            request.setValue(UserAgent.safari, forHTTPHeaderField: "User-Agent")
            request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await BilibiliNativePlayer.probeSession.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { return nil }
            return (text, Int(http.value(forHTTPHeaderField: "Age") ?? "") ?? 0)
        }
    }
}
