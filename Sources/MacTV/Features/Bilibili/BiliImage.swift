import AppKit
import ImageIO
import SwiftUI

/// 封面和头像的图片。和系统自带的网络图片视图相比多做两件事，都是为了滑动和切换时不掉帧：
/// 1. 解码好的图片留在内存里：切换左边栏、来回翻卡片时，看过的图立刻就有，不用再取、再解码；
/// 2. 解码在后台做完才交给界面，不占用画动画的那条线。
struct BiliImage: View {
    let url: URL?
    @State private var loaded: (url: URL, image: NSImage)?

    var body: some View {
        let ready = url.flatMap { BiliImageCache.shared.image(for: $0) } ?? (loaded?.url == url ? loaded?.image : nil)
        ZStack {
            if let ready {
                Image(nsImage: ready).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.05)
            }
        }
        .task(id: url) {
            guard let url, BiliImageCache.shared.image(for: url) == nil else { return }
            if let image = await BiliImageCache.shared.load(url), !Task.isCancelled { loaded = (url, image) }
        }
    }
}

/// 会换图的地方用它（播放界面的封面和背景）：到手后新图在上面慢慢浮现，上一张垫在下面——
/// 不会两张半透明地叠在一起。
///
/// holdWhileLoading：新图还没下载好时上一张要不要留着。网易云的页面背景和播放界面都用 false：
/// 宁可暗一下也不让上一页 / 上一首的图配着新的内容（下一首的封面会提前下好，按顺序切歌时不会暗）。
/// 没有图了（url 为空）一律淡出，绝不留着上一张。
struct FadingImage: View {
    let url: URL?
    var holdWhileLoading = true
    /// 现在被别的东西整个盖着（看不见）：直接换，不淡入淡出。不然等盖着的东西拿开时，
    /// 上一张还在、新的才开始浮现，看起来像先亮一下（或暗一下）再变
    var instant = false
    @State private var back: NSImage?
    @State private var front: NSImage?
    @State private var frontURL: URL?
    @State private var shown = 1.0

    var body: some View {
        ZStack {
            Color.white.opacity(0.05)
            if let back { Image(nsImage: back).resizable().aspectRatio(contentMode: .fill) }
            if let front { Image(nsImage: front).resizable().aspectRatio(contentMode: .fill).opacity(shown) }
        }
        .task(id: url) {
            guard let url else { fadeOut(); return }
            guard url != frontURL else { return }
            if instant {
                back = nil
                if let image = BiliImageCache.shared.image(for: url) {
                    front = image
                    frontURL = url
                    shown = 1
                    return
                }
                // 新图还没下好：上一张马上拿掉（盖着的东西一拿开就不会露出它），下好了再浮现
                front = nil
                frontURL = nil
            }
            var image = BiliImageCache.shared.image(for: url)
            if image == nil {
                if !holdWhileLoading { fadeOut() }
                image = await BiliImageCache.shared.load(url)
            }
            guard let image, !Task.isCancelled else { return }
            // 上一张已经淡出了就不再垫回去（不然它会突然又冒出来）
            back = frontURL == nil ? nil : front
            front = image
            frontURL = url
            shown = 0
            try? await Task.sleep(for: .milliseconds(16))   // 先让新图以透明的样子出现一帧，再开始浮现
            withAnimation(.easeInOut(duration: 0.45)) { shown = 1 }
            // 新图完全浮现以后，把垫在下面的旧图拿掉。不然整块淡入淡出时（比如播放界面收起），
            // 上下两层一起变透明，上一首的封面会透出来
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled, frontURL == url { back = nil }
        }
    }

    /// 淡出到空：垫在下面的那张马上拿掉，上面那张淡出
    private func fadeOut() {
        guard frontURL != nil || back != nil else { return }
        back = nil
        frontURL = nil
        withAnimation(.easeOut(duration: 0.15)) { shown = 0 }
    }
}

@MainActor
final class BiliImageCache {
    static let shared = BiliImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var loading: [URL: Task<NSImage?, Never>] = [:]

    /// 解码好的图很占内存（一张大封面两三兆）：按实际大小算，总共最多 64 MB，超了先丢最久没用的。
    /// 这台 Mac 内存紧张时（系统发警告）整个清掉，看到的图再取就是了
    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// 放掉所有解码好的图（内存紧张时，见 TVController.memoryPressure；长时间不用时）
    func trim() { cache.removeAllObjects() }

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let cached = image(for: url) { return cached }
        if let running = loading[url] { return await running.value }
        let task = Task<NSImage?, Never> { await Self.fetch(url) }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4)) }
        return image
    }

    /// 取图并当场解码成位图（不留到第一次显示时再解码）
    private nonisolated static func fetch(_ url: URL) async -> sending NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 900]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
    }
}
