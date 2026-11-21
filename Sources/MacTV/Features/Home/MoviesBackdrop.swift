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

    /// On the Top Shelf's grid (ShelfGrid): as tall as 得到's book, centred between the top bar and the dock, its right
    /// edge where the other apps' artwork ends.
    private var cover: some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let height = ShelfGrid.book.height, width = min(height * aspect, height)
        return Image(nsImage: image)
            .resizable()
            .aspectRatio(aspect, contentMode: .fit)
            .frame(width: width, height: width / aspect)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
            .frame(width: width, height: height)
            .position(x: ShelfGrid.artRight(canvas) - width / 2, y: ShelfGrid.artMidY(canvas))
    }
}
