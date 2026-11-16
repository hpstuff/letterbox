import SwiftUI
import WebKit

/// Renders message HTML with scripts disabled, links opened in the browser,
/// `cid:` images served from the message itself, and optional remote blocking.
struct MessageWebView: NSViewRepresentable {
    let document: String
    let key: String
    let inline: [String: Attachment]
    let blockRemote: Bool
    var onMailto: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.cid, forURLScheme: "letterbox-cid")
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        view.allowsBackForwardNavigationGestures = false
        RemoteContentBlocker.prepare()
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let c = context.coordinator
        c.onMailto = onMailto
        c.cid.parts = inline
        let loadKey = "\(key)|\(blockRemote)"
        guard c.loadedKey != loadKey else { return }
        c.loadedKey = loadKey
        let controller = view.configuration.userContentController
        controller.removeAllContentRuleLists()
        if blockRemote, let rules = RemoteContentBlocker.rules { controller.add(rules) }
        view.loadHTMLString(document, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let cid = CIDSchemeHandler()
        var loadedKey: String?
        var onMailto: ((URL) -> Void)?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            if action.navigationType == .linkActivated || (action.targetFrame?.isMainFrame ?? true) && url.scheme != "about" {
                if url.scheme == "mailto" {
                    onMailto?(url)
                } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }
}

final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    var parts: [String: Attachment] = [:]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let raw = url.absoluteString.replacingOccurrences(of: "letterbox-cid:", with: "")
        let key = (raw.removingPercentEncoding ?? raw).lowercased()
        guard let part = parts[key] else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: part.mimeType, expectedContentLength: part.data.count, textEncodingName: nil))
        task.didReceive(part.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

enum RemoteContentBlocker {
    nonisolated(unsafe) static var rules: WKContentRuleList?
    private nonisolated(unsafe) static var started = false

    static func prepare() {
        guard !started else { return }
        started = true
        let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "letterbox.block-remote", encodedContentRuleList: json) { list, _ in
            rules = list
        }
    }
}

enum MessageHTML {
    private static let cidPattern = try! NSRegularExpression(pattern: "(src\\s*=\\s*[\"']?)cid:", options: .caseInsensitive)
    private static let headTag = try! NSRegularExpression(pattern: "<head[^>]*>", options: .caseInsensitive)
    private static let urlPattern = try! NSRegularExpression(pattern: "\\b(https?://[^\\s<>\"']+[^\\s<>\"'.,;:!?)\\]])", options: .caseInsensitive)
    private static let emailPattern = try! NSRegularExpression(pattern: "\\b([A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,})\\b", options: .caseInsensitive)

    @MainActor private static var documents: [String: String] = [:]
    @MainActor private static var remote: [String: Bool] = [:]

    /// The message as a full HTML page. `themed` moves HTML mail onto the app's colors and font,
    /// for the light or dark look given by `dark`. Plain-text mail always follows the theme.
    @MainActor static func cachedDocument(for message: ParsedMessage, key: String, themed: Bool, dark: Bool) -> String {
        let css = EmailThemeCSS.current
        let cacheKey = "\(key)|\(themed ? "\(css.hashValue)|\(dark)" : "original")"
        if let hit = documents[cacheKey] { return hit }
        if documents.count > 30 { documents.removeAll() }
        let doc = document(for: message, themeCSS: css, recolor: themed ? EmailThemeCSS.recolor(dark: dark) : nil)
        documents[cacheKey] = doc
        return doc
    }

    @MainActor static func cachedHasRemote(_ message: ParsedMessage, key: String) -> Bool {
        if let hit = remote[key] { return hit }
        if remote.count > 30 { remote.removeAll() }
        let value = hasRemoteContent(message)
        remote[key] = value
        return value
    }

    static func isHTML(_ message: ParsedMessage) -> Bool {
        message.html.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }

    /// `recolor` is nil for the sender's original design.
    static func document(for message: ParsedMessage, themeCSS: String, recolor: EmailRecolor?) -> String {
        if isHTML(message), let html = message.html {
            guard let recolor else { return htmlDocument(html, head: htmlHead) }
            return htmlDocument(recolor.apply(html), head: meta + "<style>\(themeCSS)</style>", tail: themeOverrides)
        }
        return textDocument(message.text ?? "", themeCSS: themeCSS)
    }

    static func hasRemoteContent(_ message: ParsedMessage) -> Bool {
        guard let html = message.html else { return false }
        return html.range(of: "src=[\"']?https?:", options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: "url\\(['\"]?https?:", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let meta = """
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none'">
    """

    /// The sender's own design, on white.
    private static let htmlHead = meta + """
    <style>
      :root { color-scheme: light only; }
      html { -webkit-text-size-adjust: 100%; background: #ffffff; }
      body { margin: 0; padding: 20px 26px 32px; font: 14px/1.5 -apple-system, system-ui, "Helvetica Neue", sans-serif; color: #1d1d1f; overflow-wrap: anywhere; }
      img { max-width: 100%; height: auto; }
      pre { white-space: pre-wrap; }
      blockquote[type=cite] { margin: 6px 0; padding-left: 12px; border-left: 3px solid #d0d0d6; color: #555; }
      a { color: #0a64d6; }
    </style>
    """

    /// Theme rules for HTML mail whose colors `EmailRecolor` already moved onto the theme.
    /// Defaults use `:where` (no weight), so the email's own recolored styles win. The font, the page
    /// edge and quoted replies are forced: they use `!important` plus `b` = `body:not(#lb)`, which
    /// matches every body but adds id weight, and the rules go last in the page.
    private static let themeOverrides: String = {
        let b = "body:not(#lb)"
        return """
        <style>
          :where(html) { color: var(--lb-text); font-size: var(--lb-size); line-height: 1.5; }
          :where(a[href]) { color: var(--lb-accent); }
          html, \(b) { background: transparent !important; }
          \(b) { margin: 0 !important; padding: 20px 26px 32px !important; font-family: var(--lb-font) !important; overflow-wrap: anywhere; }
          \(b) :where(*:not(img, picture, svg, svg *, video, canvas)) { font-family: inherit !important; }
          \(b) :where(pre, code, tt, kbd, samp), \(b) :where(pre, code, tt, kbd, samp) * { font-family: ui-monospace, Menlo, monospace !important; }
          \(b) :where(pre) { white-space: pre-wrap; }
          \(b) :where(blockquote[type=cite]) { margin: 6px 0; padding-left: 12px; border-left: 3px solid var(--lb-line2) !important; color: var(--lb-text2) !important; }
          \(b) :where(hr) { border: 0 !important; border-top: 1px solid var(--lb-line2) !important; }
          \(b) img { max-width: 100%; height: auto; }
        </style>
        """
    }()

    private static func htmlDocument(_ html: String, head htmlHead: String, tail: String = "") -> String {
        let ns = html as NSString
        var body = cidPattern.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: ns.length), withTemplate: "$1letterbox-cid:")
        let bns = body as NSString
        if let m = headTag.firstMatch(in: body, range: NSRange(location: 0, length: bns.length)) {
            let insertAt = m.range.location + m.range.length
            body = bns.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: htmlHead)
        } else {
            body = "<!doctype html><html><head>\(htmlHead)</head><body>\(body)</body></html>"
        }
        // A <style> after </html> is moved into <body> by the parser, but still applies, and last.
        return body + tail
    }

    private static func textDocument(_ text: String, themeCSS: String) -> String {
        var html = ""
        var depth = 0
        var inSignature = false
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(rawLine)
            var level = 0
            while line.hasPrefix(">") {
                level += 1
                line = line.dropFirst()
                if line.hasPrefix(" ") { line = line.dropFirst() }
            }
            while depth < level { html += "<blockquote>"; depth += 1 }
            while depth > level { html += "</blockquote>"; depth -= 1 }
            if line == "-- " && level == 0 && !inSignature {
                inSignature = true
                html += "<div class=\"sig\">"
            }
            html += linkify(HTMLText.escape(String(line))) + "\n"
        }
        while depth > 0 { html += "</blockquote>"; depth -= 1 }
        if inSignature { html += "</div>" }

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'">
        <style>\(themeCSS)</style>
        <style>
          body { margin: 0; padding: 20px 26px 32px; font-family: var(--lb-font); font-size: var(--lb-size); line-height: 1.55;
                 white-space: pre-wrap; overflow-wrap: anywhere; color: var(--lb-text); }
          blockquote { margin: 2px 0; padding-left: 12px; border-left: 3px solid var(--lb-line2); color: var(--lb-text2); }
          .sig { color: var(--lb-text3); }
          a { color: var(--lb-accent); text-decoration: none; }
          a:hover { text-decoration: underline; }
        </style></head><body>\(html)</body></html>
        """
    }

    private static func linkify(_ s: String) -> String {
        let ns = s as NSString
        var out = urlPattern.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "<a href=\"$1\">$1</a>")
        if !out.contains("<a ") {
            let ons = out as NSString
            out = emailPattern.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ons.length), withTemplate: "<a href=\"mailto:$1\">$1</a>")
        }
        return out
    }
}

/// The user's theme as CSS variables (`--lb-*`), with light and dark values,
/// so mail pages follow the app's colors, font and text size.
enum EmailThemeCSS {
    @MainActor private static var cache: (signature: String, css: String)?

    @MainActor static var current: String {
        let settings = AppearanceSettings.shared
        if let cache, cache.signature == settings.signature { return cache.css }
        let css = make(settings)
        cache = (settings.signature, css)
        return css
    }

    @MainActor private static func make(_ settings: AppearanceSettings) -> String {
        let p = settings.palette.colors
        let size = (14 * settings.textSize.scale * 10).rounded() / 10
        func vars(dark: Bool) -> String {
            func v(_ name: String, _ color: Color) -> String { "--lb-\(name): \(rgba(color, dark: dark));" }
            return [
                v("text", p.text), v("text2", p.text2), v("text3", p.text3), v("accent", p.accent),
                v("line", Theme.hairline), v("line2", Theme.strongLine),
            ].joined(separator: " ")
        }
        return """
        :root { color-scheme: \(settings.palette.alwaysDark ? "dark" : "light dark"); -webkit-text-size-adjust: 100%;
                --lb-font: \(fontStack(settings.font)); --lb-size: \(size)px; \(vars(dark: settings.palette.alwaysDark)) }
        @media (prefers-color-scheme: dark) { :root { \(vars(dark: true)) } }
        """
    }

    private static func fontStack(_ font: ThemeFont) -> String {
        switch font {
        case .system: #"-apple-system, system-ui, "Helvetica Neue", sans-serif"#
        case .serif: #"ui-serif, "New York", Georgia, serif"#
        case .rounded: #"ui-rounded, "SF Pro Rounded", -apple-system, system-ui, sans-serif"#
        case .mono: #"ui-monospace, "SF Mono", Menlo, monospace"#
        }
    }

    /// Moves email colors onto the theme's pane and text colors.
    @MainActor static func recolor(dark: Bool) -> EmailRecolor {
        let settings = AppearanceSettings.shared
        let p = settings.palette.colors
        let isDark = dark || settings.palette.alwaysDark
        return EmailRecolor(background: resolve(p.panel, dark: isDark), text: resolve(p.text, dark: isDark), dark: isDark)
    }

    private static func rgba(_ color: Color, dark: Bool) -> String {
        let c = resolve(color, dark: dark)
        func b(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return "rgba(\(b(c.r)), \(b(c.g)), \(b(c.b)), \((c.a * 1000).rounded() / 1000))"
    }

    /// Resolves an appearance-adaptive color for light or dark mode.
    private static func resolve(_ color: Color, dark: Bool) -> EmailRecolor.RGBA {
        var out = EmailRecolor.RGBA(r: 0, g: 0, b: 0, a: 1)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            out = .init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
        }
        return out
    }
}
