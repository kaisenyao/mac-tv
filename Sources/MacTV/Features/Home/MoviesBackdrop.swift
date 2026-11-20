import SwiftUI

/// A frame from a film, full bleed, drifting slowly the way Apple TV's Top Shelf does (the Movies tile).
struct ShowBackdrop: View {
    let image: NSImage
    let since: Date
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        DriftingPicture(image: image, since: since)
            .frame(width: canvas.width, height: canvas.height)
    }
}

/// A film's poster, the way Apple TV shows an album: the poster large on the right, over its own
/// colours blurred across the screen (the Movies tile).
struct AlbumBackdrop: View {
    let image: NSImage
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: canvas.width, height: canvas.height)
                .blur(radius: 80)
                .saturation(1.3)
                .overlay(Color.black.opacity(0.35))
                .clipped()
            // Still: the cross-fade from one poster to the next is the motion.
            cover
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    private var cover: some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        return Image(nsImage: image)
            .resizable()
            .aspectRatio(aspect, contentMode: .fit)
            .frame(width: aspect >= 1 ? 560 : 640 * aspect, height: aspect >= 1 ? 560 / aspect : 640)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 150)
            .padding(.trailing, 150)
    }
}
