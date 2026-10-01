import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Typesets LaTeX into PNG images using a bundled copy of MathJax running in a hidden WKWebView.
///
/// The web view loads `mathjax/render.html` once and is reused; each render is a single
/// `renderTeX(...)` JavaScript call that returns a PNG data URL (see render.html).
///
/// Example:
/// ```swift
/// let renderer = MathRenderer()
/// let eq = try await renderer.render("\\int_0^1 x^2\\,dx = \\frac13", fontSize: 13)
/// // eq.png is PNG data at 2× with 144-dpi metadata; eq.size is its size in points.
/// ```
@MainActor
final class MathRenderer {
    struct Equation {
        let png: Data
        let size: CGSize   // in points
    }

    enum RenderError: LocalizedError {
        case resourcesMissing, badResult, latex(String)
        var errorDescription: String? {
            switch self {
            case .resourcesMissing: return "MathJax resources not found in the app bundle."
            case .badResult: return "MathJax returned an unexpected result."
            case .latex(let message): return message
            }
        }
    }

    /// Pixel density of generated images.
    var scale: CGFloat = 2
    /// Render with \displaystyle (taller fractions, limits above/below ∑ and ∫).
    var displayStyle = false

    private let webView: WKWebView
    private var loaded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let loadDelegate = LoadDelegate()

    /// WebKit content-blocker rules: block every request, then re-allow only local files and
    /// inline data URLs. Together with the page's Content-Security-Policy (render.html) and the
    /// navigation policy below, the renderer cannot reach the network.
    private static let offlineRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^file:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    init() {
        let config = WKWebViewConfiguration()
        // Nothing (cache, cookies, local storage) is written to disk.
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 400), configuration: config)
        loadDelegate.onFinish = { [weak self] in
            guard let self else { return }
            self.loaded = true
            self.waiters.forEach { $0.resume() }
            self.waiters.removeAll()
        }
        webView.navigationDelegate = loadDelegate
        guard let dir = MathRenderer.resourceDirectory() else { return }

        // Install the block list before the page loads; if it can't be compiled, don't load at all.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PriNotesOffline", encodedContentRuleList: MathRenderer.offlineRules
        ) { [weak self] list, error in
            guard let self else { return }
            guard let list else {
                Log.write("offline rule list failed to compile: \(error?.localizedDescription ?? "?") — renderer disabled")
                return
            }
            self.webView.configuration.userContentController.add(list)
            self.webView.loadFileURL(dir.appendingPathComponent("render.html"), allowingReadAccessTo: dir)
        }
    }

    /// Debug: try to reach the network from inside the renderer page; returns one line per attempt.
    func networkProbe() async -> [String] {
        if !loaded { await withCheckedContinuation { waiters.append($0) } }
        let script = """
        const results = [];
        for (const url of ['https://example.com/', 'http://1.1.1.1/', 'https://cdn.jsdelivr.net/npm/mathjax@3/package.json']) {
          try { const r = await fetch(url, {cache: 'no-store'}); results.push('fetch ' + url + ' → REACHED (' + r.status + ')'); }
          catch (e) { results.push('fetch ' + url + ' → blocked (' + e.message + ')'); }
        }
        const img = await new Promise(res => { const i = new Image(); i.onload = () => res('LOADED'); i.onerror = () => res('blocked');
                                                i.src = 'https://example.com/favicon.ico'; });
        results.push('image https://example.com/favicon.ico → ' + img);
        const script = await new Promise(res => { const s = document.createElement('script'); s.onload = () => res('LOADED');
                                                  s.onerror = () => res('blocked'); s.src = 'https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js';
                                                  document.head.appendChild(s); });
        results.push('script https://cdn.jsdelivr.net/… → ' + script);
        return results;
        """
        let result = try? await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
        return result as? [String] ?? ["probe failed to run"]
    }

    /// Locate `mathjax/` inside the .app bundle, or in the source tree when run via `swift run`.
    static func resourceDirectory() -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("mathjax"),
           fm.fileExists(atPath: res.appendingPathComponent("render.html").path) {
            return res
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/mathjax")
            if fm.fileExists(atPath: candidate.appendingPathComponent("render.html").path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Render `latex` so that it visually matches text of `fontSize` points.
    ///
    /// - Parameters:
    ///   - dark: draw white glyphs (for dark mode) instead of black; the background is transparent.
    ///   - embedSource: store `latex` in the PNG's description metadata so it can be re-edited later.
    func render(_ latex: String, fontSize: CGFloat, dark: Bool, embedSource: Bool = true) async throws -> Equation {
        guard MathRenderer.resourceDirectory() != nil else { throw RenderError.resourcesMissing }
        if !loaded { await withCheckedContinuation { waiters.append($0) } }

        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                "return await renderTeX(tex, fontPx, scale, display, ink);",
                arguments: ["tex": latex, "fontPx": Double(fontSize), "scale": Double(scale),
                            "display": displayStyle, "ink": dark ? "#fff" : "#000"],
                contentWorld: .page)
        } catch {
            // JS exceptions arrive as WKError with the message in userInfo.
            let ns = error as NSError
            var message = ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ns.localizedDescription
            if message.hasPrefix("Error: ") { message.removeFirst("Error: ".count) }
            throw RenderError.latex(message)
        }

        guard let dict = result as? [String: Any],
              let dataURL = dict["png"] as? String,
              let width = dict["width"] as? Double, let height = dict["height"] as? Double,
              let comma = dataURL.firstIndex(of: ","),
              let raw = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            throw RenderError.badResult
        }
        let png = reencode(raw, dpi: 72 * scale, source: embedSource ? latex : nil)
        return Equation(png: png, size: CGSize(width: width, height: height))
    }

    /// Convert `latex` to MathML with the bundled MathJax (offline, like `render`).
    ///
    /// Example:
    /// ```swift
    /// let mml = try await renderer.mathML("x_b^2", display: false)
    /// // "<math xmlns=\"http://www.w3.org/1998/Math/MathML\">\n  <msubsup>…"
    /// ```
    func mathML(_ latex: String, display: Bool) async throws -> String {
        guard MathRenderer.resourceDirectory() != nil else { throw RenderError.resourcesMissing }
        if !loaded { await withCheckedContinuation { waiters.append($0) } }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await texToMathML(tex, display);",
                arguments: ["tex": latex, "display": display], contentWorld: .page)
            guard let mml = result as? String else { throw RenderError.badResult }
            return mml
        } catch let error as RenderError {
            throw error
        } catch {
            let ns = error as NSError
            var message = ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ns.localizedDescription
            if message.hasPrefix("Error: ") { message.removeFirst("Error: ".count) }
            throw RenderError.latex(message)
        }
    }

    /// Prefix of the PNG description that marks an equation made by this app.
    static let sourceTag = "prinotes-latex:"

    /// Prefixes of earlier versions (the app was once called Notes Markdown). Equation images already
    /// in people's notes carry these, so they are still recognised for ⌃⌘E.
    static let legacySourceTags = ["notesmarkdown-latex:"]

    /// Re-encode PNG data with DPI metadata (so apps that honour it show the image at point size)
    /// and, optionally, the LaTeX source in the PNG description.
    private func reencode(_ png: Data, dpi: CGFloat, source: String?) -> Data {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return png }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return png }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if let source {
            props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGDescription: MathRenderer.sourceTag + source]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : png
    }

    /// The LaTeX stored in an image's metadata by `render`, if present (any format ImageIO reads).
    static func embeddedSource(in imageData: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let candidates = [
            (props[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGDescription],
            (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFImageDescription],
        ]
        for case let text as String in candidates {
            for tag in [sourceTag] + legacySourceTags where text.hasPrefix(tag) {
                return String(text.dropFirst(tag.count))
            }
        }
        return nil
    }

    /// SHA-256 of the decoded RGBA pixels — identifies an equation image even if an app
    /// re-encodes the file (as long as it doesn't resample it).
    static func pixelHash(of imageData: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined()
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }

        /// The page may only ever navigate to local files.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }
    }
}
