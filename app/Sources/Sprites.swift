import AppKit

enum Sprites {
    // --- Menu bar icon framing (tune these to reposition the sprite) ---

    /// Height of the icon box. The menu bar clips anything taller, so this is
    /// the ceiling for how much of the sprite can be shown at once.
    static let canvasHeight: CGFloat = 24

    /// Fraction of the sprite, measured from its top, that gets framed into the
    /// bar. The sprite is deliberately shown cropped: fitting the whole body
    /// into 24pt makes the Pokemon unreadably small, so instead the head is
    /// scaled up to fill the bar and the body is cut off below.
    /// Lower it to zoom further into the face; raise it to show more body.
    static let headFraction: CGFloat = 0.58

    /// Where the crop window sits vertically, as a fraction of the leftover
    /// height: 0 pins it to the top of the sprite, 1 to the bottom.
    ///
    /// Top-anchoring only works for tall bipeds like Raichu. On quadrupeds the
    /// highest point is the back — Bulbasaur's bulb — so a pure top crop cuts
    /// the eyes off. Anchoring a third of the way down keeps the face in frame
    /// for both body plans.
    static let cropAnchor: CGFloat = 0.34

    /// Widest the sprite itself may get. A normal menu bar icon is ~24pt, so
    /// this leaves room for the level text beside it.
    static let maxWidth: CGFloat = 36

    /// Transparent space added to the right of the sprite. MenuBarExtra places
    /// the level text flush against the icon, which left Charizard's wing
    /// touching the "L"; padding the canvas is what separates them.
    static let trailingGap: CGFloat = 6

    /// Menu bar icon: the head of the sprite, scaled to fill the bar height.
    static func menuBarIcon(_ path: String,
                            canvas: CGFloat = canvasHeight,
                            fraction: CGFloat = headFraction,
                            anchor: CGFloat = cropAnchor) -> NSImage? {
        guard let data = FileManager.default.contents(atPath: path),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        rep.setProperty(.currentFrame, withValue: 0)

        let full = alphaBoundsTopOrigin(rep)
            ?? CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)

        // Rows covering the head, in top-origin coordinates.
        let headHeight = (full.height * fraction).rounded()
        let headTop = (full.minY + (full.height - headHeight) * anchor).rounded()

        // Narrow horizontally to what those rows actually contain, so the icon
        // is as wide as the head rather than as wide as the whole body.
        let head = horizontalBoundsTopOrigin(rep,
                                             fromRow: Int(headTop),
                                             toRow: Int(headTop + headHeight),
                                             fallback: full)

        // NSBitmapImageRep.draw(from:) expects bottom-origin coordinates, while
        // colorAt(x:y:) indexes rows from the top. Convert before drawing or the
        // crop lands on the wrong end of the sprite.
        let source = CGRect(x: head.minX,
                            y: CGFloat(rep.pixelsHigh) - (headTop + headHeight),
                            width: head.width,
                            height: headHeight)

        let scale = canvas / headHeight

        // Cap the width so wide, short Pokemon (Diglett crops to 57pt) do not
        // take over the bar. Anything past the cap is trimmed evenly from both
        // sides, keeping the face centred.
        var cropped = source
        if source.width * scale > maxWidth {
            let allowed = maxWidth / scale
            cropped.origin.x += ((source.width - allowed) / 2).rounded()
            cropped.size.width = allowed
        }

        let width = max(1, (cropped.width * scale).rounded())

        // Canvas is wider than the sprite; the sprite is drawn at x = 0 so the
        // extra room lands on the right, between it and the level text.
        let image = NSImage(size: NSSize(width: width + trailingGap, height: canvas))
        image.lockFocus()
        // Nearest-neighbour keeps pixel art crisp instead of blurring it.
        NSGraphicsContext.current?.imageInterpolation = .none
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: canvas),
                 from: NSRect(origin: cropped.origin, size: cropped.size),
                 operation: .sourceOver,
                 fraction: 1.0,
                 respectFlipped: true,
                 hints: [.interpolation: NSImageInterpolation.none.rawValue])
        image.unlockFocus()
        return image
    }

    /// Tight box of non-transparent pixels, with y measured from the top row.
    static func alphaBoundsTopOrigin(_ rep: NSBitmapImageRep) -> CGRect? {
        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.06 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func horizontalBoundsTopOrigin(_ rep: NSBitmapImageRep,
                                                  fromRow: Int,
                                                  toRow: Int,
                                                  fallback: CGRect) -> CGRect {
        var minX = rep.pixelsWide, maxX = -1
        for y in max(0, fromRow)..<min(rep.pixelsHigh, toRow) {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.06 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
            }
        }
        guard maxX >= minX else { return fallback }
        return CGRect(x: CGFloat(minX), y: fallback.minY,
                      width: CGFloat(maxX - minX + 1), height: fallback.height)
    }

    static func image(_ path: String?) -> NSImage? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    static func spritePath(speciesID: Int) -> String {
        "\(Config.repoPath)/assets/sprites/\(speciesID)-animated.gif"
    }
}
