import SwiftUI
import WebKit

/// Answers written by Claude as HTML. Claude builds whatever the answer needs (prose, tables, charts,
/// sliders, equations, diagrams); the app supplies the look, a sandbox, a small API back into the app,
/// and one fixed element: <paper-quote>, the paper's own words, checked against the PDF and beamed to it.
enum AnswerHTML {
    struct QuoteTag {
        var range: Range<String.Index>
        var page: Int?
        var location: String
        var text: String
    }

    /// Every <paper-quote page="12" where="Section II">exact words</paper-quote> in a fragment.
    static func quoteTags(in html: String) -> [QuoteTag] {
        guard let re = try? NSRegularExpression(pattern: #"<paper-quote\b([^>]*)>(.*?)</paper-quote\s*>"#,
                                                 options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let range = Range(m.range, in: html) else { return nil }
            let attrs = ns.substring(with: m.range(at: 1))
            let inner = ns.substring(with: m.range(at: 2))
            return QuoteTag(range: range, page: attribute("page", in: attrs).flatMap { Int($0) },
                            location: decode(attribute("where", in: attrs) ?? ""), text: plainText(inner))
        }
    }

    static func attribute(_ name: String, in attrs: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", options: .caseInsensitive),
              let m = re.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs))
        else { return nil }
        for g in [2, 3] { if let r = Range(m.range(at: g), in: attrs) { return String(attrs[r]) } }
        return nil
    }

    /// The text of the first <h1>, used as the answer's title.
    static func title(of html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"<h1\b[^>]*>(.*?)</h1\s*>"#, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html)
        else { return nil }
        let t = plainText(String(html[r]))
        return t.isEmpty ? nil : t
    }

    /// Demotes <h1> to <h2>, for a follow-up added under an existing answer.
    static func demoteHeadings(_ html: String) -> String {
        html.replacingOccurrences(of: #"<(/?)h1\b"#, with: "<$1h2", options: [.regularExpression, .caseInsensitive])
    }

    /// Text with tags removed and entities decoded; scripts and styles dropped.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<(script|style)\b.*?</\1\s*>"#, with: "",
                                          options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<br\s*/?>|</(p|h\d|li|tr|figcaption|div)>"#, with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decode(s)
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The answer as Claude wrote it, minus script bodies, for sending back as context.
    static func forContext(_ html: String) -> String {
        html.replacingOccurrences(of: #"(<script\b[^>]*>).*?(</script\s*>)"#, with: "$1/* code omitted */$2",
                                  options: [.regularExpression, .caseInsensitive])
    }

    static func decode(_ s: String) -> String {
        var s = s
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                       ("&ndash;", "–"), ("&mdash;", "—"), ("&minus;", "−"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The resolved tag the app stores in place of Claude's: the paper's exact words, its color and source.
    static func resolvedTag(_ block: AnswerBlock) -> String {
        var attrs = "data-qid=\"\(block.id.uuidString)\""
        if let span = block.span {
            let c = SourcePalette.rgb[((block.colorIndex ?? 0) % SourcePalette.rgb.count + SourcePalette.rgb.count) % SourcePalette.rgb.count]
            attrs += " data-found=\"1\" data-page=\"\(span.page + 1)\" data-rgb=\"\(Int(c.0)),\(Int(c.1)),\(Int(c.2))\""
        } else {
            attrs += " data-found=\"0\""
        }
        attrs += " data-where=\"\(escape(block.location ?? ""))\""
        return "<paper-quote \(attrs)><mark>\(escape(block.text))</mark></paper-quote>"
    }

    /// The code Claude ran, appended by the app (not by Claude) so it's always there to inspect.
    static func codeDisclosure(_ code: [String]) -> String {
        guard !code.isEmpty else { return "" }
        let body = escape(code.joined(separator: "\n\n"))
        return "\n<details class=\"pc-code\"><summary>Claude ran code for this answer</summary><pre>\(body)</pre></details>\n"
    }

    // MARK: The page around the fragment

    static func page(fragment: String, paperFont: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
        <style>\(css(paperFont: paperFont))</style>
        <script>\(bridgeJS)</script>
        </head><body>
        \(fragment)
        <script>\(afterJS)</script>
        </body></html>
        """
    }

    static func css(paperFont: String) -> String {
        """
        :root { color-scheme: light dark;
          --text: rgba(0,0,0,.86); --primary: #000; --secondary: rgba(0,0,0,.52); --tertiary: rgba(0,0,0,.3);
          --fill: rgba(0,0,0,.045); --fill-strong: rgba(0,0,0,.08); --separator: rgba(0,0,0,.1); --grid: rgba(0,0,0,.07);
          --accent: #0a84ff; --c1:#0a84ff; --c2:#ff9500; --c3:#30b0c7; --c4:#ff2d55; --c5:#af52de; --c6:#34c759; --c7:#8e8e93;
          --paper-font: "\(paperFont)", "Times New Roman", serif; }
        @media (prefers-color-scheme: dark) { :root {
          --text: rgba(255,255,255,.88); --primary: #fff; --secondary: rgba(255,255,255,.55); --tertiary: rgba(255,255,255,.32);
          --fill: rgba(255,255,255,.06); --fill-strong: rgba(255,255,255,.1); --separator: rgba(255,255,255,.12); --grid: rgba(255,255,255,.08); } }
        html, body { background: transparent; margin: 0; }
        body { font: 15px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; color: var(--text); padding: 4px 30px 56px;
          -webkit-font-smoothing: antialiased; overflow-wrap: break-word; }
        h1 { font-size: 26px; line-height: 1.2; font-weight: 700; color: var(--primary); margin: 0 0 14px; letter-spacing: -0.2px; }
        h2 { font-size: 19px; line-height: 1.3; font-weight: 650; color: var(--primary); margin: 26px 0 8px; }
        h3 { font-size: 15px; font-weight: 600; color: var(--primary); margin: 18px 0 4px; }
        p { margin: 0 0 12px; } ul, ol { margin: 0 0 12px; padding-left: 22px; } li { margin: 3px 0; }
        a { color: var(--accent); text-decoration: none; }
        strong { font-weight: 600; color: var(--primary); }
        code { font: 12.5px ui-monospace, Menlo, monospace; background: var(--fill); padding: 1px 4px; border-radius: 4px; }
        table { border-collapse: collapse; width: 100%; font-size: 13px; font-variant-numeric: tabular-nums; margin: 4px 0 12px; }
        th { text-align: left; font-weight: 600; color: var(--secondary); font-size: 12px; }
        th, td { padding: 5px 8px; border-bottom: 0.5px solid var(--separator); vertical-align: top; }
        td.num, th.num { text-align: right; }
        figure { margin: 14px 0; padding: 14px 16px; background: var(--fill); border-radius: 14px; }
        figure canvas, figure svg { max-width: 100%; }
        figcaption { font-size: 12px; color: var(--secondary); margin-top: 8px; line-height: 1.4; }
        button { font: 500 13px -apple-system, sans-serif; color: var(--text); background: var(--fill-strong); border: none;
          border-radius: 7px; padding: 5px 11px; cursor: default; }
        button:hover { background: var(--separator); } button:active { opacity: .7; }
        button.on, button[aria-pressed=true] { background: var(--accent); color: #fff; }
        input[type=range] { width: 100%; accent-color: var(--accent); }
        label { font-size: 13px; color: var(--secondary); }
        math { font-size: 1.08em; } math[display=block] { margin: 10px 0; }
        hr { border: none; border-top: 0.5px solid var(--separator); margin: 18px 0; }
        paper-quote { display: block; background: #fff; color: #101010; font: 16.5px/1.62 var(--paper-font);
          padding: 11px 14px; border-radius: 8px; box-shadow: 0 2px 6px rgba(0,0,0,.08); margin: 14px 0 7px; }
        paper-quote mark { color: inherit; background: transparent; padding: 1px 0; -webkit-box-decoration-break: clone; }
        .pq-source { display: flex; width: fit-content; gap: 5px; align-items: center; font: 500 12px -apple-system, sans-serif;
          color: var(--secondary); background: none; padding: 0; margin: 0 0 12px; }
        .pq-source:hover { background: none; color: var(--text); }
        details.pc-code { margin-top: 22px; font-size: 12px; color: var(--secondary); }
        details.pc-code summary { cursor: default; font-weight: 500; }
        details.pc-code pre { font: 11px/1.45 ui-monospace, Menlo, monospace; color: var(--text); background: var(--fill);
          padding: 10px 12px; border-radius: 8px; overflow-x: auto; white-space: pre; }
        """
    }

    /// `paper` API and theme, available before Claude's own scripts run.
    static let bridgeJS = #"""
    (function () {
      const post = (m) => { try { window.webkit.messageHandlers.paper.postMessage(m); } catch (e) {} };
      window.paper = {
        reveal: (page, text) => post({ type: 'reveal', page: Number(page) || 0, text: String(text || '') }),
        ask: (question) => post({ type: 'ask', question: String(question || '') }),
      };
      const css = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
      Object.defineProperty(window, 'paperTheme', { get: () => ({
        text: css('--text'), secondary: css('--secondary'), grid: css('--grid'), accent: css('--accent'),
        font: '-apple-system, BlinkMacSystemFont, sans-serif',
        colors: ['--c1','--c2','--c3','--c4','--c5','--c6','--c7'].map(css),
      }) });
      window.addEventListener('error', (e) => post({ type: 'error', message: String(e.message || e) }));
      window.__post = post;
    })();
    """#

    /// After the fragment: style quotes, add their source lines, and report where they are for the beams.
    static let afterJS = #"""
    (function () {
      const post = window.__post;
      if (window.Chart) { Chart.defaults.font.family = paperTheme.font; Chart.defaults.color = paperTheme.secondary; }
      document.querySelectorAll('paper-quote[data-qid]').forEach((q) => {
        const found = q.dataset.found === '1';
        if (found && q.dataset.rgb) q.querySelector('mark').style.background = 'rgba(' + q.dataset.rgb + ',0.3)';
        const src = document.createElement('button');
        src.className = 'pq-source';
        const where = q.dataset.where ? ' · ' + q.dataset.where : '';
        src.textContent = found ? ('Page ' + q.dataset.page + where + '  ↗') : 'Couldn’t find this exact text in the paper';
        if (found) src.onclick = () => post({ type: 'revealQuote', id: q.dataset.qid });
        q.after(src);
        q.addEventListener('mouseenter', () => post({ type: 'hover', id: q.dataset.qid }));
        q.addEventListener('mouseleave', () => post({ type: 'hover', id: null }));
      });
      let pending = false;
      const report = () => {
        if (pending) return; pending = true;
        requestAnimationFrame(() => {
          pending = false;
          const quotes = [...document.querySelectorAll('paper-quote[data-qid]')].map((q) => {
            const r = q.getBoundingClientRect();
            return { id: q.dataset.qid, x: r.x, y: r.y, w: r.width, h: r.height };
          });
          post({ type: 'rects', quotes });
        });
      };
      addEventListener('scroll', report, { passive: true });
      addEventListener('resize', report);
      new ResizeObserver(report).observe(document.body);
      report();
      window.__scrollToEnd = () => window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' });
    })();
    """#
}

/// A sandboxed web view showing one answer. It has no network access beyond two script CDNs, no storage,
/// and no navigation; it can only call the `paper` API.
struct AnswerWebView: NSViewRepresentable {
    let model: AppModel
    let version: AnswerVersion
    var scrollToEnd = false

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakHandler(context.coordinator), name: "paper")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        context.coordinator.web = web
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.model = model
        let key = "\(version.id)|\(version.html?.count ?? 0)"
        if c.loadedKey != key {
            let wasSameThread = c.loadedVersionPrefix != nil && (version.html ?? "").hasPrefix(c.loadedVersionPrefix ?? "\u{0}")
            c.loadedKey = key
            c.loadedVersionPrefix = version.html
            c.scrollToEndOnLoad = scrollToEnd || wasSameThread || ProcessInfo.processInfo.environment["PC_SCROLL_END"] != nil
            web.loadHTMLString(AnswerHTML.page(fragment: version.html ?? "", paperFont: model.paperFontName), baseURL: nil)
        }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "paper")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var model: AppModel
        weak var web: WKWebView?
        var loadedKey: String?
        var loadedVersionPrefix: String?
        var scrollToEndOnLoad = false

        init(model: AppModel) { self.model = model }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            MainActor.assumeIsolated { handle(type, body) }
        }

        @MainActor
        private func handle(_ type: String, _ body: [String: Any]) {
            switch type {
            case "rects":
                let origin = model.geometry.sheetViewport.origin
                var frames: [UUID: CGRect] = [:]
                for q in body["quotes"] as? [[String: Any]] ?? [] {
                    guard let s = q["id"] as? String, let id = UUID(uuidString: s) else { continue }
                    let n = { (k: String) in CGFloat((q[k] as? NSNumber)?.doubleValue ?? 0) }
                    frames[id] = CGRect(x: origin.x + n("x"), y: origin.y + n("y"), width: n("w"), height: n("h"))
                }
                model.geometry.slipFrames = frames
            case "hover":
                if let s = body["id"] as? String, let id = UUID(uuidString: s),
                   let block = model.openThread?.current?.blocks.first(where: { $0.id == id }) {
                    model.geometry.hoveredSource = model.sourceID(for: block)
                } else {
                    model.geometry.hoveredSource = nil
                }
            case "revealQuote":
                if let s = body["id"] as? String, let id = UUID(uuidString: s),
                   let span = model.openThread?.current?.blocks.first(where: { $0.id == id })?.span {
                    model.pdf.reveal(span)
                }
            case "reveal":
                let page = (body["page"] as? NSNumber)?.intValue ?? 0
                if let text = body["text"] as? String, let span = model.index?.locate(text, preferredPage: page > 0 ? page - 1 : nil) {
                    model.pdf.reveal(span)
                } else if page > 0, let doc = model.document, let p = doc.page(at: page - 1) {
                    model.pdf.go(to: p)
                }
            case "ask":
                if let q = body["question"] as? String, !q.isEmpty, !model.isComposing {
                    model.mode = model.openThread == nil ? .compose : .extend
                    model.question = q
                    model.send()
                }
            case "error":
                NSLog("Answer page script error: %@", body["message"] as? String ?? "")
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if scrollToEndOnLoad {
                scrollToEndOnLoad = false
                webView.evaluateJavaScript("setTimeout(() => window.__scrollToEnd && window.__scrollToEnd(), 120)")
            }
        }

        /// Only the answer itself loads. A clicked web link opens in the browser; nothing else navigates.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            if action.navigationType == .linkActivated {
                if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(url?.scheme == "about" && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }
    }

    /// WKUserContentController retains its handlers; this breaks the cycle with the coordinator.
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            target?.userContentController(c, didReceive: m)
        }
    }
}
