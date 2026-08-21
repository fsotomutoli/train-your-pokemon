import AppKit

// Renders menu bar icons to a single contact sheet so the framing can be judged
// across several Pokemon at once, instead of round-tripping through screenshots.
// Each row is one sprite drawn at menu bar size and magnified.
//
//   swiftc -parse-as-library -o preview preview.swift Sources/Sprites.swift .build/Config.swift
//   ./preview <out.png> <fraction> <anchor> <sprite.gif>...

@main
struct Preview {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 5 else {
            print("usage: preview <out.png> <fraction> <anchor> <sprite.gif>...")
            exit(1)
        }
        let out = args[1]
        let fraction = CGFloat(Double(args[2]) ?? 0.58)
        let anchor = CGFloat(Double(args[3]) ?? 0.34)
        let sprites = Array(args[4...])

        let zoom: CGFloat = 6
        let gap: CGFloat = 6

        let icons = sprites.compactMap {
            Sprites.menuBarIcon($0, fraction: fraction, anchor: anchor)
        }
        guard !icons.isEmpty else { print("no icons"); exit(1) }

        let rowHeight = Sprites.canvasHeight * zoom + gap
        let width = (icons.map(\.size.width).max() ?? 24) * zoom + gap * 2
        let height = rowHeight * CGFloat(icons.count) + gap

        let sheet = NSImage(size: NSSize(width: width, height: height))
        sheet.lockFocus()
        // Menu bar backdrop, so transparent regions read as empty space.
        NSColor(calibratedRed: 0.16, green: 0.65, blue: 0.68, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.current?.imageInterpolation = .none

        for (index, icon) in icons.enumerated() {
            // Rows fill from the top; NSImage origin is bottom-left.
            let y = height - rowHeight * CGFloat(index + 1)
            let rect = NSRect(x: gap, y: y,
                              width: icon.size.width * zoom,
                              height: icon.size.height * zoom)
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        sheet.unlockFocus()

        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("could not encode png")
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: out))
        print("\(icons.count) icons (fraction \(fraction), anchor \(anchor)) -> \(out)")
    }
}
