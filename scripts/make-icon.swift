// Renders the Letterbox app icon.
// Usage: swift scripts/make-icon.swift <output-dir> [preview.png] [dark-preview.png]
//
// Writes two things into <output-dir>:
//   AppIcon.icon     An Icon Composer icon with a light and a dark look. macOS 26 and later
//                    switch between them with the system appearance.
//   AppIcon.iconset  The flat light icon, for older macOS and for builds without Xcode 26.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

/// Colors for one look of the icon.
struct Palette {
    let paperTop, paperBottom, ink, dot: NSColor

    static let light = Palette(paperTop: NSColor(red: 0.992, green: 0.989, blue: 0.980, alpha: 1),
                               paperBottom: NSColor(red: 0.925, green: 0.918, blue: 0.900, alpha: 1),
                               ink: NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1),
                               dot: NSColor(red: 0.18, green: 0.36, blue: 0.83, alpha: 1))
    /// Night paper: a charcoal tile with a paper-colored envelope.
    static let dark = Palette(paperTop: NSColor(red: 0.200, green: 0.198, blue: 0.192, alpha: 1),
                              paperBottom: NSColor(red: 0.094, green: 0.093, blue: 0.090, alpha: 1),
                              ink: NSColor(red: 0.950, green: 0.940, blue: 0.915, alpha: 1),
                              dot: NSColor(red: 0.33, green: 0.52, blue: 0.98, alpha: 1))
}

/// Draws into a square bitmap whose coordinates run 0...1024 at any pixel size.
func bitmap(_ px: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// The artwork sits on the macOS icon grid: an 824pt tile with a 100pt margin.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let env = CGRect(x: 262, y: 334, width: 500, height: 356)
let dot = CGRect(x: env.maxX - 54, y: env.maxY - 54, width: 108, height: 108)
let dotGap: CGFloat = 22

/// The envelope outline, with a clear gap where the unread dot sits.
func drawEnvelope(_ ctx: CGContext, _ ink: NSColor) {
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setStrokeColor(ink.cgColor)
    ctx.setLineWidth(30)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.addPath(CGPath(roundedRect: env, cornerWidth: 46, cornerHeight: 46, transform: nil))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: env.minX + 40, y: env.maxY - 44))
    ctx.addLine(to: CGPoint(x: env.midX, y: env.midY - 6))
    ctx.addLine(to: CGPoint(x: env.maxX - 40, y: env.maxY - 44))
    ctx.strokePath()
    ctx.setBlendMode(.clear)
    ctx.fillEllipse(in: dot.insetBy(dx: -dotGap, dy: -dotGap))
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func drawDot(_ ctx: CGContext, _ color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: dot)
}

/// The finished flat icon: paper tile, shadow, envelope and dot.
func flatIcon(_ px: Int, _ p: Palette) -> Data {
    bitmap(px) { ctx in
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.addPath(tilePath); ctx.setFillColor(p.paperBottom.cgColor); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        let paper = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [p.paperTop.cgColor, p.paperBottom.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(paper, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        ctx.restoreGState()
        ctx.addPath(tilePath)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()

        drawEnvelope(ctx, p.ink)
        drawDot(ctx, p.dot)
    }
}

/// One Icon Composer layer: the tile fills the whole canvas there, so the artwork is scaled up to match.
func layer(_ draw: @escaping (CGContext) -> Void) -> Data {
    bitmap(1024) { ctx in
        let k = 1024 / tile.width
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -tile.minX, y: -tile.minY)
        draw(ctx)
    }
}

func write(_ data: Data, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

func color(_ c: NSColor) -> String {
    let c = c.usingColorSpace(.sRGB)!
    return String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.redComponent, c.greenComponent, c.blueComponent)
}

// Flat light icon set.
let iconset = out.appendingPathComponent("AppIcon.iconset")
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    write(flatIcon(points * scale, .light), iconset.appendingPathComponent(name))
}

// Icon Composer icon: a paper fill per appearance, the envelope per appearance, and one blue dot.
let icon = out.appendingPathComponent("AppIcon.icon")
let assets = icon.appendingPathComponent("Assets")
write(layer { drawEnvelope($0, Palette.light.ink) }, assets.appendingPathComponent("envelope.png"))
write(layer { drawEnvelope($0, Palette.dark.ink) }, assets.appendingPathComponent("envelope-dark.png"))
write(layer { drawDot($0, Palette.light.dot) }, assets.appendingPathComponent("dot.png"))
write(layer { drawDot($0, Palette.dark.dot) }, assets.appendingPathComponent("dot-dark.png"))
let json = """
{
  "fill-specializations" : [
    { "value" : { "automatic-gradient" : "\(color(Palette.light.paperTop.blended(withFraction: 0.5, of: Palette.light.paperBottom)!))" } },
    { "appearance" : "dark", "value" : { "automatic-gradient" : "\(color(Palette.dark.paperTop.blended(withFraction: 0.5, of: Palette.dark.paperBottom)!))" } }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "name" : "dot",
          "image-name-specializations" : [
            { "value" : "dot.png" },
            { "appearance" : "dark", "value" : "dot-dark.png" }
          ]
        },
        {
          "name" : "envelope",
          "image-name-specializations" : [
            { "value" : "envelope.png" },
            { "appearance" : "dark", "value" : "envelope-dark.png" }
          ]
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}

"""
write(json.data(using: .utf8)!, icon.appendingPathComponent("icon.json"))

// Flat previews for the README.
for (path, palette) in zip(CommandLine.arguments.dropFirst(2), [Palette.light, Palette.dark]) {
    write(flatIcon(512, palette), URL(fileURLWithPath: path))
}
