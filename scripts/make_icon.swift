import AppKit
import CoreGraphics

// Draw the Usage Manager app icon (white "LLM" pill on a dark squircle) at every required size into an .iconset directory.
// Usage: swift make_icon.swift <output_iconset_dir>

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func drawIcon(pixels: Int, to path: String) {
    let S = CGFloat(pixels)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))
    ctx.setShouldAntialias(true)

    // Rounded-square plate with ~9.5% transparent margin (macOS icon grid).
    let m = (S * 0.095).rounded()
    let plate = CGRect(x: m, y: m, width: S - 2 * m, height: S - 2 * m)
    let radius = plate.width * 0.2237

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.008), blur: S * 0.02, color: rgb(0, 0, 0, 0.22))
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(rgb(28, 28, 30))
    ctx.fillPath()
    ctx.restoreGState()

    // White pill with "LLM" knocked in black — same mark as the menu-bar icon.
    let pillH = plate.height * 0.36, pillW = plate.width * 0.78
    let pill = CGRect(x: plate.midX - pillW / 2, y: plate.midY - pillH / 2, width: pillW, height: pillH)
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil))
    ctx.setFillColor(rgb(255, 255, 255))
    ctx.fillPath()
    let font = NSFont.systemFont(ofSize: pillH * 0.62, weight: .heavy)
    let text = NSAttributedString(string: "LLM", attributes: [.font: font, .foregroundColor: NSColor.black])
    let ts = text.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    text.draw(at: NSPoint(x: pill.midX - ts.width / 2, y: pill.midY - ts.height / 2))
    NSGraphicsContext.restoreGraphicsState()

    guard let img = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: pixels, height: pixels)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: make_icon.swift <iconset_dir>\n".utf8)); exit(1) }
let dir = args[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

let targets: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in targets { drawIcon(pixels: px, to: dir + "/" + name) }
print("icons written to \(dir)")
