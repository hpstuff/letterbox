import AppKit
import SwiftUI

/// User-chosen look: colors, fonts, text size and spacing. Persisted in UserDefaults.
/// `Theme` reads from `AppearanceSettings.shared`, so views redraw when a value changes.
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    var mode: AppearanceMode = .stored("themeMode", .system) {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "themeMode"); applyMode() }
    }
    var palette: ThemePalette = .stored("themePalette", .paper) {
        didSet { UserDefaults.standard.set(palette.rawValue, forKey: "themePalette"); applyMode() }
    }
    var font: ThemeFont = .stored("themeFont", .system) {
        didSet { UserDefaults.standard.set(font.rawValue, forKey: "themeFont") }
    }
    var textSize: ThemeTextSize = .stored("themeTextSize", .regular) {
        didSet { UserDefaults.standard.set(textSize.rawValue, forKey: "themeTextSize") }
    }
    var density: ThemeDensity = .stored("themeDensity", .regular) {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "themeDensity") }
    }

    /// Changes whenever anything that affects layout or color changes.
    var signature: String { [palette.rawValue, font.rawValue, textSize.rawValue, density.rawValue].joined(separator: "-") }

    /// Sets the app-wide light/dark appearance. Covers every window, including Settings.
    func applyMode() {
        if palette.alwaysDark {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            return
        }
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// An AppKit font matching `Theme.font`, for text views.
    func nsFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size * textSize.scale)
        let design: NSFontDescriptor.SystemDesign? = switch font {
        case .system: nil
        case .serif: .serif
        case .rounded: .rounded
        case .mono: .monospaced
        }
        guard let design, let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: 0) ?? base
    }

    func reset() {
        mode = .system
        palette = .paper
        font = .system
        textSize = .regular
        density = .regular
    }
}

private extension RawRepresentable where RawValue == String {
    static func stored(_ key: String, _ fallback: Self) -> Self {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? fallback
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum ThemeFont: String, CaseIterable, Identifiable {
    case system, serif, rounded, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .serif: "Serif"
        case .rounded: "Rounded"
        case .mono: "Monospaced"
        }
    }
    var design: Font.Design {
        switch self {
        case .system: .default
        case .serif: .serif
        case .rounded: .rounded
        case .mono: .monospaced
        }
    }
    /// Headlines stay serif in the default look; other styles use their own design.
    var headlineDesign: Font.Design { self == .system ? .serif : design }
}

enum ThemeTextSize: String, CaseIterable, Identifiable {
    case small, regular, large, larger
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Small"
        case .regular: "Default"
        case .large: "Large"
        case .larger: "Larger"
        }
    }
    var scale: CGFloat {
        switch self {
        case .small: 0.92
        case .regular: 1
        case .large: 1.1
        case .larger: 1.2
        }
    }
}

enum ThemeDensity: String, CaseIterable, Identifiable {
    case compact, regular, roomy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Compact"
        case .regular: "Default"
        case .roomy: "Roomy"
        }
    }
    var scale: CGFloat {
        switch self {
        case .compact: 0.75
        case .regular: 1
        case .roomy: 1.3
        }
    }
}

/// One full set of surface, ink and accent colors, each with a light and a dark value.
struct Palette {
    let canvas, rail, panel, raised, sunken: Color
    let text, text2, text3, onInk: Color
    let accent, urgent, success: Color
    /// Fill of primary buttons and toasts. Defaults to the text color.
    let ink: Color

    init(canvas: Color, rail: Color, panel: Color, raised: Color, sunken: Color,
         text: Color, text2: Color, text3: Color, onInk: Color,
         accent: Color, urgent: Color, success: Color, ink: Color) {
        self.canvas = canvas; self.rail = rail; self.panel = panel; self.raised = raised; self.sunken = sunken
        self.text = text; self.text2 = text2; self.text3 = text3; self.onInk = onInk
        self.accent = accent; self.urgent = urgent; self.success = success; self.ink = ink
    }

    init(canvas: (UInt32, UInt32), rail: (UInt32, UInt32), panel: (UInt32, UInt32), raised: (UInt32, UInt32), sunken: (UInt32, UInt32),
         text: (UInt32, UInt32), text2: (UInt32, UInt32), text3: (UInt32, UInt32), onInk: (UInt32, UInt32),
         accent: (UInt32, UInt32), urgent: (UInt32, UInt32), success: (UInt32, UInt32), ink: (UInt32, UInt32)? = nil) {
        func c(_ v: (UInt32, UInt32)) -> Color { Color(light: v.0, dark: v.1) }
        self.canvas = c(canvas); self.rail = c(rail); self.panel = c(panel); self.raised = c(raised); self.sunken = c(sunken)
        self.text = c(text); self.text2 = c(text2); self.text3 = c(text3); self.onInk = c(onInk)
        self.accent = c(accent); self.urgent = c(urgent); self.success = c(success)
        self.ink = c(ink ?? text)
    }
}

enum ThemePalette: String, CaseIterable, Identifiable {
    case paper, linen, slate, moss, plum, midnight, glass
    var id: String { rawValue }

    /// The standard macOS look: see-through sidebar and Liquid Glass controls on macOS 26+.
    var isGlass: Bool { self == .glass }

    /// Dark-only themes force the dark appearance, whatever the Appearance setting says.
    var alwaysDark: Bool { self == .midnight }

    var title: String {
        switch self {
        case .paper: "Paper"
        case .linen: "Linen"
        case .slate: "Slate"
        case .moss: "Moss"
        case .plum: "Plum"
        case .midnight: "Midnight"
        case .glass: "Liquid Glass"
        }
    }

    var subtitle: String {
        switch self {
        case .paper: "Quiet ink on white"
        case .linen: "Warm cream and terracotta"
        case .slate: "Cool blue-grey"
        case .moss: "Soft greens"
        case .plum: "Muted violet"
        case .midnight: "Near-black, always dark"
        case .glass: "Standard macOS look with glass controls"
        }
    }

    var colors: Palette {
        switch self {
        case .paper: Self.paperColors
        case .linen: Self.linenColors
        case .slate: Self.slateColors
        case .moss: Self.mossColors
        case .plum: Self.plumColors
        case .midnight: Self.midnightColors
        case .glass: Self.glassColors
        }
    }

    private static let paperColors = Palette(
        canvas: (0xF6F6F4, 0x0F0F10), rail: (0xF1F1EE, 0x131314), panel: (0xFFFFFF, 0x161617),
        raised: (0xFFFFFF, 0x1C1C1E), sunken: (0xF3F3F1, 0x121213),
        text: (0x141414, 0xECECEC), text2: (0x5C5C5C, 0xA2A2A2), text3: (0x949494, 0x6A6A6A), onInk: (0xFFFFFF, 0x141414),
        accent: (0x2F5BD3, 0x6E93F2), urgent: (0xB83A3A, 0xE06A66), success: (0x2E7550, 0x6BBF8E))

    private static let linenColors = Palette(
        canvas: (0xF5F0E6, 0x17140F), rail: (0xEFE8DA, 0x1B1712), panel: (0xFBF8F2, 0x1E1A15),
        raised: (0xFFFDF8, 0x25201A), sunken: (0xEEE7D9, 0x15120E),
        text: (0x2B2118, 0xEDE4D6), text2: (0x6B5B4A, 0xB3A593), text3: (0x9C8C78, 0x7A6D5C), onInk: (0xFFFDF8, 0x1B1712),
        accent: (0xB5532D, 0xE08A5E), urgent: (0xA8322B, 0xE5766B), success: (0x4F7A3A, 0x8DBE74),
        ink: (0x3A2C20, 0xEDE4D6))

    private static let slateColors = Palette(
        canvas: (0xEEF1F5, 0x0E1117), rail: (0xE7EBF0, 0x11151C), panel: (0xF9FAFC, 0x151A22),
        raised: (0xFFFFFF, 0x1A2029), sunken: (0xE9EDF2, 0x0F131A),
        text: (0x151B26, 0xE3E8F0), text2: (0x4F5B6D, 0x9AA6B8), text3: (0x8592A5, 0x657185), onInk: (0xFFFFFF, 0x0E1117),
        accent: (0x2E6FB8, 0x6FA8E8), urgent: (0xC0392B, 0xEF7564), success: (0x2C7A62, 0x64C3A2),
        ink: (0x1F3A5F, 0xC9D7EA))

    private static let mossColors = Palette(
        canvas: (0xF1F3EE, 0x0F120F), rail: (0xEAEEE6, 0x121612), panel: (0xFAFBF8, 0x161A16),
        raised: (0xFFFFFF, 0x1B201B), sunken: (0xECEFE7, 0x101310),
        text: (0x18201A, 0xE4EAE2), text2: (0x52604F, 0xA0AD9C), text3: (0x8A9786, 0x6B7868), onInk: (0xFFFFFF, 0x0F120F),
        accent: (0x3F7D4E, 0x7FC28F), urgent: (0xB0413A, 0xE27A6E), success: (0x3F7D4E, 0x7FC28F),
        ink: (0x2D4A33, 0xCFE0CC))

    private static let plumColors = Palette(
        canvas: (0xF5F2F7, 0x120F16), rail: (0xEFEBF2, 0x16121B), panel: (0xFCFAFD, 0x1A1620),
        raised: (0xFFFFFF, 0x211C28), sunken: (0xEEEAF1, 0x130F17),
        text: (0x1D1724, 0xECE6F2), text2: (0x5F566B, 0xABA2B8), text3: (0x958CA1, 0x756D81), onInk: (0xFFFFFF, 0x120F16),
        accent: (0x7A4FC2, 0xB193EE), urgent: (0xB83A5A, 0xE9758F), success: (0x2E7550, 0x6BBF8E),
        ink: (0x4A2F73, 0xDCCDF5))

    private static let midnightColors = Palette(
        canvas: (0x0A0A0A, 0x0A0A0A), rail: (0x0D0D0D, 0x0D0D0D), panel: (0x111111, 0x111111),
        raised: (0x181818, 0x181818), sunken: (0x070707, 0x070707),
        text: (0xEDEDED, 0xEDEDED), text2: (0xA0A0A0, 0xA0A0A0), text3: (0x666666, 0x666666), onInk: (0x0A0A0A, 0x0A0A0A),
        accent: (0x8AA0E0, 0x8AA0E0), urgent: (0xF07A7A, 0xF07A7A), success: (0x7CC79A, 0x7CC79A),
        ink: (0xE8E8E8, 0xE8E8E8))

    /// Standard macOS system colors in light mode, like Mail or Finder. Dark mode uses deeper
    /// near-black surfaces than the system grey. The sidebar is see-through (it shows the
    /// blurred desktop) and controls use Liquid Glass; the content stays plain.
    private static let glassColors = Palette(
        canvas: Color(light: .windowBackgroundColor, dark: 0x111113),
        rail: .clear,
        panel: Color(light: .textBackgroundColor, dark: 0x151517),
        raised: Color(light: .controlBackgroundColor, dark: 0x1C1C1E),
        sunken: Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.04),
        text: Color(nsColor: .labelColor),
        text2: Color(nsColor: .secondaryLabelColor),
        text3: Color(nsColor: .tertiaryLabelColor),
        onInk: .white,
        accent: .accentColor,
        urgent: Color(nsColor: .systemRed),
        success: Color(nsColor: .systemGreen),
        ink: .accentColor)
}

private extension Color {
    /// A system color in light mode and a fixed hex color in dark mode.
    init(light: NSColor, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return light }
            return NSColor(srgbRed: CGFloat((dark >> 16) & 0xFF) / 255, green: CGFloat((dark >> 8) & 0xFF) / 255,
                           blue: CGFloat(dark & 0xFF) / 255, alpha: 1)
        })
    }
}

extension View {
    /// Applies the user's appearance to a window's root view.
    func themed() -> some View {
        modifier(ThemedRoot())
    }
}

private struct ThemedRoot: ViewModifier {
    @State private var settings = AppearanceSettings.shared

    func body(content: Content) -> some View {
        content
            .id(settings.signature)
    }
}

/// The see-through sidebar of the Liquid Glass theme: the blurred desktop, as in Finder or Mail.
struct GlassSidebarBackground: View {
    var body: some View {
        if Snapshot.isActive {
            // Offscreen screenshots can't see the desktop, so show a neutral stand-in.
            Color(light: 0xE6E6E8, dark: 0x161618)
        } else {
            // In dark mode, a black tint makes the blur darker so it sits with the deep content.
            BehindWindowBlur()
                .overlay(Color(light: 0x000000, dark: 0x000000, lightAlpha: 0, darkAlpha: 0.45))
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// A glass surface in the Liquid Glass theme: real Liquid Glass on macOS 26+, frosted material before.
    /// A `tint` colors the glass (for primary actions). In other themes, a plain fill.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ shape: S, fill: Color, tint: Color? = nil, interactive: Bool = false) -> some View {
        if AppearanceSettings.shared.palette.isGlass {
            if #available(macOS 26, *) {
                self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
            } else if let tint {
                self.background(shape.fill(tint))
            } else {
                self.background(.ultraThinMaterial, in: shape)
            }
        } else {
            self.background(shape.fill(fill))
        }
    }

    @available(macOS 26, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    /// Lets nearby glass shapes blend and morph together on macOS 26+. Does nothing in other themes.
    @ViewBuilder
    func glassContainer(spacing: CGFloat? = nil) -> some View {
        if AppearanceSettings.shared.palette.isGlass {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: spacing) { self }
            } else {
                self
            }
        } else {
            self
        }
    }

    /// Turns a small text or label button into a glass capsule in the Liquid Glass theme.
    /// In other themes, the view is unchanged.
    @ViewBuilder
    func glassChip(height: CGFloat = 24) -> some View {
        if AppearanceSettings.shared.palette.isGlass {
            self.padding(.horizontal, 10)
                .frame(height: height)
                .glassSurface(Capsule(), fill: .clear, interactive: true)
        } else {
            self
        }
    }
}

extension EnvironmentValues {
    /// True inside a `GlassGroup`: controls skip their own glass, so the group reads as one shape.
    @Entry var inGlassGroup = false
}

/// A row of related controls on one shared glass capsule, like a macOS 26 toolbar group.
/// In other themes, a plain row.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        if Theme.isGlass {
            HStack(spacing: spacing) { content }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .glassSurface(Capsule(), fill: .clear)
                .environment(\.inGlassGroup, true)
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}
