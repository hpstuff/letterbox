import Foundation

/// Moves every color in an HTML email onto the app's theme, keeping the sender's design.
///
/// Each color keeps its place on a light-to-dark scale, but the scale now runs from the theme's
/// pane color (where white was) to the theme's ink (where black was). Grays pick up the theme's
/// tint; colored boxes and buttons keep their hue.
///
/// In a dark theme the scale is flipped, with two guards so text stays readable:
/// - text colors only get lighter: black text turns light, white text on a dark box stays light;
/// - box colors only get darker: white boxes turn dark, a navy header or a button keeps its color.
///
/// Colors are rewritten in `<style>` blocks, `style="…"` attributes and the old `bgcolor`/`color`
/// attributes. Images are not touched.
struct EmailRecolor {
    struct RGBA: Equatable {
        var r, g, b, a: Double
    }

    /// What a color paints: text (and icons) or a surface (backgrounds, borders, shadows).
    enum Role { case text, surface }

    private let light: Lab
    private let darkEnd: Lab
    private let chromaKeep: Double
    private let dark: Bool

    /// - Parameters:
    ///   - background: the pane color the email sits on.
    ///   - text: the theme's text color.
    ///   - dark: true when the theme is dark (the scale is flipped).
    init(background: RGBA, text: RGBA, dark: Bool) {
        light = Lab(background)
        var end = Lab(text)
        // In a light theme black stays almost black (with the ink's tint), so body text keeps its contrast.
        if !dark { end.L = 0 }
        darkEnd = end
        chromaKeep = dark ? 0.85 : 1
        self.dark = dark
    }

    func map(_ c: RGBA, _ role: Role) -> RGBA {
        let lab = Lab(c)
        var d = min(max(1 - lab.L, 0), 1)
        // Dark-theme text leans toward the ink, so gray body text stays easy to read.
        if dark && role == .text { d = 1 - (1 - d) * (1 - d) }
        let base = Lab(L: light.L + (darkEnd.L - light.L) * d,
                       a: light.a + (darkEnd.a - light.a) * d,
                       b: light.b + (darkEnd.b - light.b) * d)
        var L = base.L
        if dark {
            switch role {
            case .text: L = max(L, min(lab.L, darkEnd.L))
            case .surface: L = min(L, lab.L)
            }
        }
        // Grays take the theme's tint; colors keep their own hue. A color made much darker also
        // gets less strong, or it falls outside what a screen shows and its hue shifts (orange to red).
        let w = min(hypot(lab.a, lab.b) / 0.06, 1)
        let k = chromaKeep * (L < lab.L && lab.L > 0 ? max(L / lab.L, 0.35) : 1)
        let out = Lab(L: L,
                      a: lab.a * k * w + base.a * (1 - w),
                      b: lab.b * k * w + base.b * (1 - w))
        var rgb = out.rgb
        rgb.a = c.a
        return rgb
    }

    // MARK: HTML

    func apply(_ html: String) -> String {
        var s = Self.replace(Self.styleBlock, in: html) { m, text in
            let open = text.substring(with: m.range(at: 1))
            let css = text.substring(with: m.range(at: 2))
            let close = text.substring(with: m.range(at: 3))
            return open + recolorCSS(css) + close
        }
        s = Self.replace(Self.styleAttr, in: s) { m, text in
            let lead = text.substring(with: m.range(at: 1))
            let quote = text.substring(with: m.range(at: 2))
            let css = text.substring(with: m.range(at: 3))
            return lead + quote + recolorCSS(css) + quote
        }
        s = Self.replace(Self.colorAttr, in: s) { m, text in
            let lead = text.substring(with: m.range(at: 1))
            let quote = text.substring(with: m.range(at: 2))
            let value = text.substring(with: m.range(at: 3))
            guard let c = Self.parse(value, bareHex: true) else { return text.substring(with: m.range) }
            let lower = lead.lowercased()
            let role: Role = lower.contains("bgcolor") || lower.contains("bordercolor") ? .surface : .text
            return lead + quote + Self.format(map(c, role)) + quote
        }
        return s
    }

    /// Rewrites colors in the values of color-like properties only, so selectors such as `#fade` stay.
    func recolorCSS(_ css: String) -> String {
        Self.replace(Self.declaration, in: css) { m, text in
            let prop = text.substring(with: m.range(at: 1))
            let value = text.substring(with: m.range(at: 2))
            let name = prop.lowercased()
            let isText = ["color", "text-decoration", "caret", "fill", "stroke"].contains { name.hasPrefix($0) }
            return prop + recolorValue(value, isText ? .text : .surface)
        }
    }

    private func recolorValue(_ value: String, _ role: Role) -> String {
        Self.replace(Self.colorToken, in: value) { m, text in
            let token = text.substring(with: m.range)
            guard let c = Self.parse(token, bareHex: false) else { return token }
            return Self.format(map(c, role))
        }
    }

    // MARK: Patterns

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let styleBlock = re("(<style[^>]*>)(.*?)(</style\\s*>)")
    private static let styleAttr = re("(\\sstyle\\s*=\\s*)([\"'])(.*?)\\2")
    private static let colorAttr = re("(\\s(?:bgcolor|color|text|link|vlink|alink|bordercolor)\\s*=\\s*)([\"']?)(#?[0-9a-z]+)\\2(?=[\\s/>])")
    private static let declaration = re(
        "((?<![-\\w])(?:background(?:-color)?|color|border(?:-(?:top|right|bottom|left|block|inline))?(?:-color)?|outline(?:-color)?|"
        + "text-decoration(?:-color)?|column-rule(?:-color)?|caret-color|fill|stroke|box-shadow|text-shadow)\\s*:)([^;}{]*)")
    private static let colorToken = re(
        "#[0-9a-f]{3,8}\\b|rgba?\\([^)]*\\)|(?<![\\w#./-])(?:" + named.keys.joined(separator: "|") + ")(?![\\w./-])")

    private static func replace(_ re: NSRegularExpression, in s: String, _ f: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f(m, ns)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: Parsing

    private static let named: [String: UInt32] = [
        "white": 0xFFFFFF, "black": 0x000000, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
        "yellow": 0xFFFF00, "orange": 0xFFA500, "gray": 0x808080, "grey": 0x808080, "silver": 0xC0C0C0,
        "navy": 0x000080, "maroon": 0x800000, "purple": 0x800080, "teal": 0x008080, "lime": 0x00FF00,
        "aqua": 0x00FFFF, "fuchsia": 0xFF00FF, "olive": 0x808000, "whitesmoke": 0xF5F5F5, "gainsboro": 0xDCDCDC,
        "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3, "darkgray": 0xA9A9A9, "darkgrey": 0xA9A9A9,
        "dimgray": 0x696969, "dimgrey": 0x696969, "snow": 0xFFFAFA, "ivory": 0xFFFFF0, "beige": 0xF5F5DC,
    ]

    static func parse(_ raw: String, bareHex: Bool) -> RGBA? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let v = named[s] { return rgb(v) }
        if s.hasPrefix("rgb") { return parseFunction(s) }
        var hex = Substring(s)
        if hex.hasPrefix("#") { hex = hex.dropFirst() } else if !bareHex { return nil }
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        switch hex.count {
        case 3, 4:
            let v = hex.map { Double(Int(String($0), radix: 16)!) * 17 / 255 }
            return RGBA(r: v[0], g: v[1], b: v[2], a: v.count == 4 ? v[3] : 1)
        case 6, 8:
            guard let n = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 6 { return rgb(UInt32(n)) }
            var c = rgb(UInt32(n >> 8))
            c.a = Double(n & 0xFF) / 255
            return c
        default:
            return nil
        }
    }

    private static func parseFunction(_ s: String) -> RGBA? {
        guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
        let parts = s[s.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        func num(_ p: String, scale: Double) -> Double? {
            if p.hasSuffix("%") { return Double(p.dropLast()).map { $0 / 100 } }
            return Double(p).map { $0 / scale }
        }
        guard let r = num(parts[0], scale: 255), let g = num(parts[1], scale: 255), let b = num(parts[2], scale: 255) else { return nil }
        let a = parts.count > 3 ? num(parts[3], scale: 1) ?? 1 : 1
        return RGBA(r: r, g: g, b: b, a: a)
    }

    static func rgb(_ v: UInt32) -> RGBA {
        RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: 1)
    }

    static func format(_ c: RGBA) -> String {
        func b(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        if c.a >= 1 { return String(format: "#%02x%02x%02x", b(c.r), b(c.g), b(c.b)) }
        return "rgba(\(b(c.r)), \(b(c.g)), \(b(c.b)), \((c.a * 1000).rounded() / 1000))"
    }
}

/// OKLab: a color space where equal steps look equal, so lightness can be moved without shifting hue.
private struct Lab {
    var L, a, b: Double

    init(L: Double, a: Double, b: Double) { self.L = L; self.a = a; self.b = b }

    init(_ c: EmailRecolor.RGBA) {
        func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = lin(c.r), g = lin(c.g), bl = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    var rgb: EmailRecolor.RGBA {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gam(_ x: Double) -> Double {
            let x = min(max(x, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return .init(r: gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                     g: gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                     b: gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
                     a: 1)
    }
}
