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

/// 会换图的地方用它（播放界面的封面和背景）：新图到手之前，上一张原样留着；
/// 到手后新图在上面慢慢浮现，上一张一直垫在下面——不会先空一下，也不会两张半透明地叠在一起。
struct FadingImage: View {
    let url: URL?
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
            guard let url, url != frontURL else { return }
            var image = BiliImageCache.shared.image(for: url)
            if image == nil { image = await BiliImageCache.shared.load(url) }
            guard let image, !Task.isCancelled else { return }
            back = front
            front = image
            frontURL = url
            shown = 0
            try? await Task.sleep(for: .milliseconds(16))   // 先让新图以透明的样子出现一帧，再开始浮现
            withAnimation(.easeInOut(duration: 0.45)) { shown = 1 }
        }
    }
}

@MainActor
final class BiliImageCache {
    static let shared = BiliImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var loading: [URL: Task<NSImage?, Never>] = [:]

    private init() { cache.countLimit = 500 }

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let cached = image(for: url) { return cached }
        if let running = loading[url] { return await running.value }
        let task = Task<NSImage?, Never> { await Self.fetch(url) }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
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
