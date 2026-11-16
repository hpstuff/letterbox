import AppKit
import SwiftUI

extension Color {
    /// An appearance-adaptive color from hex values.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// A quiet, paper-and-ink palette by default. Colour is reserved for meaning:
/// one accent for unread/focus and one muted red for urgency.
/// Values come from the user's chosen appearance (see `AppearanceSettings`).
enum Theme {
    private static var settings: AppearanceSettings { .shared }
    private static var p: Palette { settings.palette.colors }
    static var isGlass: Bool { settings.palette.isGlass }

    // Surfaces
    static var canvas: Color { p.canvas }
    static var rail: Color { p.rail }
    static var panel: Color { p.panel }
    static var raised: Color { p.raised }
    static var sunken: Color { p.sunken }
    static let hover = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.035, darkAlpha: 0.045)
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.08)
    static let strongLine = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.14)

    // Ink
    static var text: Color { p.text }
    static var text2: Color { p.text2 }
    static var text3: Color { p.text3 }
    static var ink: Color { p.ink }
    static var onInk: Color { p.onInk }

    // Accents (used sparingly)
    static var accent: Color { p.accent }
    static let accentSoft = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.055, darkAlpha: 0.075)
    static var accentText: Color { text }
    static var brand: LinearGradient { LinearGradient(colors: [ink, ink], startPoint: .top, endPoint: .bottom) }
    static var aurora: LinearGradient { LinearGradient(colors: [text2, text2], startPoint: .top, endPoint: .bottom) }
    static let auroraSoft = LinearGradient(colors: [Color.clear, Color.clear], startPoint: .top, endPoint: .bottom)

    // Semantic
    static var urgent: Color { p.urgent }
    static var high: Color { text }
    static var normal: Color { text2 }
    static var success: Color { p.success }

    // Type & spacing

    /// A UI font at `size`, scaled by the user's text size and drawn in their chosen font style.
    static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design? = nil) -> Font {
        .system(size: size * settings.textSize.scale, weight: weight, design: design ?? settings.font.design)
    }

    /// Spacing scaled by the user's density setting, rounded to half points.
    static func s(_ value: CGFloat) -> CGFloat {
        (value * settings.density.scale * 2).rounded() / 2
    }

    static func priorityColor(_ p: Int) -> Color {
        switch p {
        case 3: return urgent
        case 2: return text
        default: return text3
        }
    }

    static func priorityLabel(_ p: Int) -> String {
        switch p {
        case 3: return "Urgent"
        case 2: return "Important"
        case 1: return "Normal"
        default: return "Low"
        }
    }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        font(size: size, weight: weight)
    }

    /// Editorial serif for headlines.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        font(size: size, weight: weight, design: settings.font.headlineDesign)
    }

    static var micro: Font { font(size: 10.5, weight: .semibold) }
}

// MARK: - Surfaces & controls

struct PanelBackground: ViewModifier {
    var radius: CGFloat = 12
    var fill: Color = Theme.raised

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func panel(radius: CGFloat = 12, fill: Color = Theme.raised) -> some View {
        modifier(PanelBackground(radius: radius, fill: fill))
    }

    func microLabel() -> some View {
        font(Theme.micro).tracking(0.6).textCase(.uppercase).foregroundStyle(Theme.text3)
    }

    /// Kept for call sites that mark Claude output; now just a quiet panel.
    func aurora(radius: CGFloat = 12, animated: Bool = false) -> some View {
        modifier(PanelBackground(radius: radius, fill: Theme.sunken))
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color = Theme.text2
    var size: CGFloat = 30
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.font(size: 13, weight: .regular))
                .foregroundStyle(active ? Theme.text : tint)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(active ? Theme.accentSoft : (hovering ? Theme.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct GlassPill: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.glassSurface(Capsule(), fill: .clear, interactive: true)
        } else {
            content
        }
    }
}

struct PillButton: View {
    enum Style { case primary, secondary, ai, ghost }
    let title: String
    var symbol: String?
    var style: Style = .secondary
    var compact = false
    var expand = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    /// Secondary buttons become glass capsules in the Liquid Glass theme.
    private var glassy: Bool { Theme.isGlass && (style == .secondary || style == .ai) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.s(6)) {
                if let symbol { Image(systemName: symbol).font(Theme.font(size: compact ? 10.5 : 11.5, weight: .medium)) }
                Text(title).font(Theme.font(size: compact ? 12 : 12.5, weight: .medium))
            }
            .padding(.horizontal, compact ? 10 : 13)
            .frame(maxWidth: expand ? .infinity : nil)
            .frame(height: compact ? 26 : 30)
            .foregroundStyle(style == .primary ? Theme.onInk : Theme.text)
            .background {
                if !glassy {
                    RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous)
                        .fill(style == .primary ? Theme.ink.opacity(hovering ? 0.86 : 1) : (hovering ? Theme.hover : (style == .ghost ? .clear : Theme.raised)))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous)
                    .strokeBorder(style == .primary || style == .ghost || glassy ? .clear : Theme.strongLine, lineWidth: 1)
            )
            .modifier(GlassPill(enabled: glassy))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct TagChip: View {
    let text: String
    var symbol: String?
    var color: Color = Theme.text2

    var body: some View {
        HStack(spacing: Theme.s(4)) {
            if let symbol { Image(systemName: symbol).font(Theme.font(size: 8.5, weight: .semibold)) }
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.font(size: 10.5, weight: .medium))
        .padding(.horizontal, Theme.s(6))
        .frame(height: 18)
        .foregroundStyle(color)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Small monochrome mark for Claude-generated content.
struct SparkleIcon: View {
    var size: CGFloat = 12
    var body: some View {
        Image(systemName: "sparkle")
            .font(Theme.font(size: size * 0.9, weight: .medium))
            .foregroundStyle(Theme.text3)
    }
}

/// A restrained progress indicator while Claude is working.
struct ThinkingBar: View {
    @State private var x: CGFloat = -0.35
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Theme.hairline)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.text3)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: x * geo.size.width)
                }
                .clipShape(Capsule())
        }
        .frame(height: 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { x = 0.7 }
        }
    }
}

/// A monogram tile in neutral tones.
struct AvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 34
    var ring: Color?

    var body: some View {
        Circle()
            .fill(Theme.sunken)
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .overlay(
                Text(Self.initials(name: name, email: email))
                    .font(Theme.font(size: size * 0.36, weight: .medium))
                    .foregroundStyle(Theme.text2)
            )
            .overlay(alignment: .topTrailing) {
                if let ring {
                    Circle().fill(ring)
                        .frame(width: max(7, size * 0.22), height: max(7, size * 0.22))
                        .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 2))
                        .offset(x: 1, y: -1)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func initials(name: String, email: String) -> String {
        let source = name.isEmpty ? (email.split(separator: "@").first.map(String.init) ?? "?") : name
        let words = source.split { !$0.isLetter && !$0.isNumber }.prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: Theme.s(9)) {
            Image(systemName: toast.symbol)
                .font(Theme.font(size: 12, weight: .medium))
                .foregroundStyle(Theme.onInk.opacity(0.75))
            Text(toast.message)
                .font(Theme.font(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.onInk)
                .lineLimit(2)
        }
        .padding(.horizontal, Theme.s(16))
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .frame(maxWidth: 480)
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: Theme.s(8)) {
            Image(systemName: "magnifyingglass").font(Theme.font(size: 12)).foregroundStyle(Theme.text3)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.font(size: 13))
                .focused(focus)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘F").font(Theme.font(size: 10.5)).foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, Theme.s(10))
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focus.wrappedValue ? Theme.strongLine : Theme.hairline, lineWidth: 1))
    }
}

/// Section heading used across panes.
struct SectionHeader: View {
    let title: String
    var count: Int = 0
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s(8)) {
            Text(title).font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            if count > 0 { Text("\(count)").font(Theme.font(size: 12).monospacedDigit()).foregroundStyle(Theme.text3) }
            if let subtitle { Text(subtitle).font(Theme.font(size: 12)).foregroundStyle(Theme.text3) }
            Spacer()
        }
    }
}

/// A vertical scroll view that renders statically while screenshots are being taken.
struct MaybeScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if Snapshot.isActive {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content }
        }
    }
}
