import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Profile photos: a square Avatar.jpg about 512 pixels across in each profile's own folder (the first profile's is
/// Mac TV's folder in Application Support), shown wherever the profile's avatar is. Each is read once and kept,
/// so the avatars around the TV draw without going to the disk.
@MainActor
final class ProfilePhotos: ObservableObject {
    static let shared = ProfilePhotos()
    static let fileName = "Avatar.jpg"
    nonisolated static let side = 512

    /// Where each profile keeps its things, from the TVController: Mac TV's own places, or a test's folder.
    var spaces: ProfileSpaces? {
        didSet {
            photos = [:]
            objectWillChange.send()
        }
    }

    /// Each profile's photo once read, nil for a profile without one.
    private var photos: [String: NSImage?] = [:]

    func file(for id: String) -> URL { (spaces ?? .live).folder(for: id).appendingPathComponent(Self.fileName) }

    func photo(for id: String) -> NSImage? {
        if let known = photos[id] { return known }
        let image = NSImage(contentsOf: file(for: id))
        photos[id] = .some(image)
        return image
    }

    /// Makes a picked image this profile's photo. False when it isn't an image that could be read.
    @discardableResult
    func set(_ jpeg: Data, for id: String) -> Bool {
        guard let image = NSImage(data: jpeg) else { return false }
        let file = file(for: id)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The photo it replaces goes to the Trash too, never straight out of existence.
            if FileManager.default.fileExists(atPath: file.path) { _ = try (spaces ?? .live).trash(file) }
            try jpeg.write(to: file, options: .atomic)
        } catch {
            Log.app.failure("Saving a profile photo", error)
            return false
        }
        photos[id] = .some(image)
        objectWillChange.send()
        return true
    }

    /// Back to the letter on the profile's colour. The photo goes to the Trash, never straight out of existence (the
    /// Mac's Trash for Mac TV's own folder, a Trash folder inside a test's). False when it couldn't: it's kept.
    @discardableResult
    func remove(for id: String) -> Bool {
        let file = file(for: id)
        if FileManager.default.fileExists(atPath: file.path) {
            do { _ = try (spaces ?? .live).trash(file) } catch {
                Log.app.failure("Moving a profile photo to the Trash", error)
                return false
            }
        }
        photos[id] = .some(nil)
        objectWillChange.send()
        return true
    }

    /// Forgets what was read for a removed profile, whose folder (and photo) went with it.
    func forget(_ id: String) {
        photos[id] = nil
    }

    /// The middle square of an image, about `side` pixels across, as a JPEG: the photo's own orientation applied,
    /// read at the size it's needed rather than whole, so a large photo is quick.
    nonisolated static func squareJPEG(from url: URL, side: Int = side) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Big enough that the short side still covers `side`.
        let long = max(width, height), short = min(width, height)
        let wanted = min(long, Int((Double(side) * Double(long) / Double(short)).rounded(.up)))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: wanted]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let square = min(image.width, image.height)
        let crop = CGRect(x: (image.width - square) / 2, y: (image.height - square) / 2, width: square, height: square)
        let size = min(square, side)
        guard let cropped = image.cropping(to: crop), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let output = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

extension TVController {
    /// Choose Photo…: the Mac's open panel for images. The picked image's middle square becomes the profile's photo.
    func chooseProfilePhoto(for id: String) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.setProfilePhoto(from: url, for: id) }
        }
    }

    /// Reads and squares the image away from the main thread, then shows it everywhere the avatar is.
    func setProfilePhoto(from url: URL, for id: String) {
        Task.detached(priority: .userInitiated) {
            let jpeg = ProfilePhotos.squareJPEG(from: url)
            await MainActor.run { [weak self] in
                guard let jpeg, ProfilePhotos.shared.set(jpeg, for: id) else {
                    self?.showToast("Couldn’t Use That Image")
                    return
                }
                self?.objectWillChange.send()
            }
        }
    }
}
