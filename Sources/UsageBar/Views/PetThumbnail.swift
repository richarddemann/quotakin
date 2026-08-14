import AppKit
import SwiftUI
import UsageCore

/// A small, static preview of a pet pack: its first declared idle frame,
/// cropped from the spritesheet and drawn nearest-neighbor to match
/// `PetSpriteView`'s pixel-art look.
///
/// Resolution is by pack id so callers can build straight from
/// `PetAssets.availablePacks` (which yields ids). If the pack or its sheet is
/// missing, a neutral placeholder renders instead of crashing.
struct PetThumbnail: View {
    let packID: String
    /// Target size in points. Defaults preserve the 192:208 sprite-cell aspect.
    var size = CGSize(width: 34, height: 37)

    var body: some View {
        Group {
            if let pack = PetAssets.pack(withID: packID),
               let image = PetAssets.spritesheetImage(for: pack) {
                thumbnailCanvas(image: image, sourceRect: PetThumbnailPresentation.sourceRect(for: pack.manifest))
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    private func thumbnailCanvas(image cgImage: CGImage, sourceRect: CGRect) -> some View {
        Canvas { context, canvasSize in
            guard let cropped = cgImage.cropping(to: sourceRect) else {
                return
            }

            context.withCGContext { cgContext in
                cgContext.interpolationQuality = .none
                // CGContext draws bottom-left origin inside Canvas's flipped
                // top-left space; flip so the sprite isn't upside down.
                cgContext.translateBy(x: 0, y: canvasSize.height)
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.draw(cropped, in: CGRect(origin: .zero, size: canvasSize))
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .overlay(
                Image(systemName: "pawprint")
                    .font(.system(size: min(size.width, size.height) * 0.5))
                    .foregroundStyle(.secondary)
            )
    }
}

struct PetThumbnailPresentation {
    static func sourceRect(for manifest: PetManifest) -> CGRect {
        let frameWidth = manifest.frame?.width ?? PetSpriteGrid.cellWidth
        let frameHeight = manifest.frame?.height ?? PetSpriteGrid.cellHeight
        let columns = manifest.frame?.columns ?? PetSpriteGrid.columns
        let spriteIndex = manifest.animations?[PetTrackName.idle.rawValue]?.frames.first ?? 0

        return CGRect(
            x: (spriteIndex % columns) * frameWidth,
            y: (spriteIndex / columns) * frameHeight,
            width: frameWidth,
            height: frameHeight
        )
    }
}

#Preview("PetThumbnail") {
    let ids = PetAssets.availablePacks.map(\.id)
    return VStack(alignment: .leading, spacing: Space.xs) {
        ForEach(ids, id: \.self) { id in
            HStack(spacing: Space.xs) {
                PetThumbnail(packID: id)
                Text(id)
            }
        }
        HStack(spacing: Space.xs) {
            PetThumbnail(packID: "__missing_pack__")
            Text("missing → placeholder")
        }
    }
    .padding()
}
