import Foundation
import WebKit

struct FetchedArticle {
    let title: String
    let paragraphs: [String]
    let url: URL

    var text: String { paragraphs.joined(separator: "\n\n") }
    var wordCount: Int { paragraphs.reduce(0) { $0 + $1.split(separator: " ").count } }
    /// Listening time at a typical narration pace of about 150 words a minute.
    var minutes: Int { max(1, Int((Double(wordCount) / 150).rounded())) }
}

enum ArticleError: LocalizedError {
    case badURL
    case timeout
    case noText
    case load(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "That doesn't look like a web address. It should start with https://"
        case .timeout: return "The page took too long to load. Check the connection and try again."
        case .noText: return "Couldn't find the article text on this page. It may be behind a paywall or login. Copy the text and use the Text tab instead."
        case .load(let reason): return "Couldn't load the page: \(reason)"
        }
    }
}

/// Loads a web page in an off-screen web view (so JavaScript-built pages work) and extracts the readable text.
@MainActor
final class ArticleFetcher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<FetchedArticle, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var extractTask: Task<Void, Never>?
    private var pageURL: URL?

    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // A shared snippet may contain text around the link.
        if let r = s.range(of: #"https?://[^\s<>"]+"#, options: .regularExpression) { s = String(s[r]) }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    func fetch(_ input: String) async throws -> FetchedArticle {
        guard let url = Self.normalize(input) else { throw ArticleError.badURL }
        pageURL = url
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .all   // never autoplay audio or video off-screen
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = self
        webView = wv
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            wv.load(URLRequest(url: url, timeoutInterval: 30))
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                // Slow page: use whatever has rendered so far before giving up.
                self.extract(final: true)
            }
        }
    }

    private func finish(_ result: Result<FetchedArticle, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel()
        extractTask?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        cont.resume(with: result)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            // Give client-side rendering a moment, then try; try once more if the first pass found little.
            extractTask?.cancel()
            extractTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, !Task.isCancelled else { return }
                self.extract(final: false)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(.failure(ArticleError.load(error.localizedDescription))) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(.failure(ArticleError.load(error.localizedDescription))) }
    }

    private var attempts = 0

    private func extract(final: Bool) {
        guard continuation != nil, let webView else { return }
        attempts += 1
        webView.callAsyncJavaScript(Self.extractionScript, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            let dict = (try? result.get()) as? [String: Any]
            let rawTitle = (dict?["title"] as? String) ?? ""
            let raw = (dict?["paragraphs"] as? [String]) ?? []
            let paragraphs = Self.clean(raw)
            let words = paragraphs.reduce(0) { $0 + $1.split(separator: " ").count }
            if words >= 120 || final || self.attempts >= 3 {
                if words < 60 {
                    self.finish(.failure(ArticleError.noText))
                } else {
                    let title = Self.cleanTitle(rawTitle, host: self.pageURL?.host)
                    self.finish(.success(FetchedArticle(title: title, paragraphs: paragraphs, url: self.pageURL ?? URL(string: "https://example.com")!)))
                }
            } else {
                // Not much yet (lazy-loaded page): wait and look again.
                self.extractTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled else { return }
                    self.extract(final: false)
                }
            }
        }
    }

    /// Drops duplicates, boilerplate lines and the very long tail of huge pages.
    static func clean(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        var total = 0
        let boilerplate = ["subscribe", "sign up", "newsletter", "cookie", "all rights reserved", "advertisement",
                           "share this", "follow us", "read more", "related articles", "click here"]
        for p in raw {
            let t = TranscriptParser.cleanProse(p)
            guard t.count >= 3, !seen.contains(t) else { continue }
            let lower = t.lowercased()
            if t.count < 140, boilerplate.contains(where: { lower.contains($0) }) { continue }
            seen.insert(t)
            out.append(t)
            total += t.count
            if total > 60_000 { break }
        }
        return out
    }

    static func cleanTitle(_ raw: String, host: String?) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Headline | Site name" or "Headline - Site": keep the headline.
        for sep in [" | ", " – ", " — ", " - "] {
            if let r = t.range(of: sep, options: .backwards), t.distance(from: t.startIndex, to: r.lowerBound) > 15 {
                t = String(t[..<r.lowerBound])
                break
            }
        }
        if t.isEmpty { t = host ?? "Article" }
        return String(t.prefix(120))
    }

    /// Runs inside the page. Prefers the publisher's structured article body, then a readability-style pick of the
    /// block with the most paragraph text (climbing out of nested sections), then line breaks for pages without <p>.
    static let extractionScript = """
    const title = (document.querySelector('meta[property="og:title"]') || {}).content
        || (document.querySelector('h1') || {}).textContent || document.title || '';
    const text = el => (el.textContent || '').replace(/\\s+/g, ' ').trim();

    for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
        try {
            const data = JSON.parse(s.textContent);
            const items = Array.isArray(data) ? data : (data['@graph'] || [data]);
            for (const it of items) {
                if (it && typeof it.articleBody === 'string' && it.articleBody.length > 800) {
                    return { title, paragraphs: it.articleBody.split(/\\n+/) };
                }
            }
        } catch (e) {}
    }

    const skip = 'nav,header,footer,aside,form,figure,figcaption,noscript,script,style,svg,iframe,button,sup,' +
        '[role=navigation],[role=complementary],[aria-hidden=true],.advert,.ad,.ads,.share,.social,.newsletter,.related,' +
        '.comments,.promo,.references,.reflist,.mw-references-wrap,.navbox,.infobox,.toc,#toc,.mw-editsection,.hatnote,.thumb,.metadata,.gallery';
    const good = [];
    for (const p of document.querySelectorAll('p')) {
        if (p.closest(skip)) continue;
        const t = text(p);
        if (t.length < 40) continue;
        const links = [...p.querySelectorAll('a')].reduce((n, a) => n + text(a).length, 0);
        good.push({ p, s: t.length * (1 - Math.min(0.9, links / t.length)) });
    }
    const scores = new Map();
    for (const { p, s } of good) {
        const parent = p.parentElement, grand = parent && parent.parentElement;
        if (parent) scores.set(parent, (scores.get(parent) || 0) + s);
        if (grand) scores.set(grand, (scores.get(grand) || 0) + s / 2);
    }
    let root = null, best = 0;
    for (const [el, s] of scores) if (s > best) { best = s; root = el; }
    const within = el => good.reduce((n, g) => n + (el.contains(g.p) ? g.s : 0), 0);
    if (root) {
        // Nested sections and wrappers: take the highest ancestor that still adds 25% more paragraph text.
        let total = within(root);
        let el = root.parentElement;
        while (el && el !== document.body && el !== document.documentElement) {
            const up = within(el);
            if (up >= total * 1.25) { root = el; total = up; }
            el = el.parentElement;
        }
    }
    if (!root || best < 400) root = document.querySelector('article') || document.querySelector('main') || document.body;

    const stopAt = /^(references|see also|external links|further reading|notes|bibliography|sources|related|related stories|comments|footnotes|citations|additional images|gallery)$/i;
    const out = [];
    for (const el of root.querySelectorAll('h1,h2,h3,p,li,blockquote')) {
        if (el.closest(skip)) continue;
        if (el.tagName !== 'LI' && el.closest('li')) continue;
        const t = text(el);
        const heading = /^H[1-3]$/.test(el.tagName);
        if (heading && stopAt.test(t)) break;
        if ((heading && t.length > 3 && t.length < 200) || t.length >= 40) out.push(t);
    }
    const words = out.join(' ').split(/\\s+/).length;
    if (words >= 150) return { title, paragraphs: out };

    // Pages that use line breaks instead of <p>: rebuild paragraphs from blank lines.
    const clone = (document.querySelector('article') || document.querySelector('main') || document.body).cloneNode(true);
    clone.querySelectorAll(skip).forEach(e => e.remove());
    clone.querySelectorAll('br').forEach(br => br.replaceWith('\\n'));
    clone.querySelectorAll('p,div,li,h1,h2,h3,blockquote,tr').forEach(el => el.append('\\n\\n'));
    const blocks = (clone.textContent || '').split(/\\n\\s*\\n/).map(b => b.replace(/\\s+/g, ' ').trim()).filter(b => b.length >= 40);
    return { title, paragraphs: blocks.length > out.length ? blocks : out };
    """
}
