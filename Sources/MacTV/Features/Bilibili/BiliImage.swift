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
