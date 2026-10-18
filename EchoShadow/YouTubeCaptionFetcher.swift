import Foundation

enum CaptionError: LocalizedError {
    case noTracks
    case blocked
    case empty

    var errorDescription: String? {
        switch self {
        case .noTracks: return "This video has no captions. Paste the transcript instead."
        case .blocked: return "YouTube currently blocks automatic caption download. Open the video in YouTube, tap ⋯ ▸ Show transcript, select all, copy, and paste it below."
        case .empty: return "The caption track was empty. Paste the transcript instead."
        }
    }
}

enum YouTubeCaptionFetcher {
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func videoID(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func valid(_ id: String) -> String? {
            id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil ? id : nil
        }
        if let id = valid(s) { return id }
        // Share-sheet text often wraps the link in a title; pull the id out of any YouTube URL in the text.
        if let r = s.range(of: #"(?:youtu\.be/|v=|shorts/|embed/|live/)([A-Za-z0-9_-]{11})"#, options: .regularExpression) {
            let match = String(s[r])
            if let id = match.range(of: "[A-Za-z0-9_-]{11}$", options: .regularExpression).map({ String(match[$0]) }) { return valid(id) }
        }
        guard let url = URL(string: s), let host = url.host?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            return url.pathComponents.dropFirst().first.flatMap(valid)
        }
        if host.contains("youtube") {
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
                return valid(v)
            }
            let comps = url.pathComponents
            if let i = comps.firstIndex(where: { ["shorts", "embed", "live", "v"].contains($0) }), i + 1 < comps.count {
                return valid(comps[i + 1])
            }
        }
        return nil
    }

    static func fetchTitle(videoID: String) async -> String? {
        var comps = URLComponents(string: "https://www.youtube.com/oembed")!
        comps.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"), URLQueryItem(name: "format", value: "json")]
        guard let url = comps.url, let response = try? await URLSession.shared.data(from: url) else { return nil }
        let json = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any]
        return json?["title"] as? String
    }

    /// Best-effort caption download. YouTube changes this often, so callers must offer paste as a fallback.
    static func fetchCaptions(videoID: String) async throws -> [Cue] {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=en")!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { throw CaptionError.blocked }
        guard let tracks = captionTracks(in: html), !tracks.isEmpty else { throw CaptionError.noTracks }

        let english = tracks.filter { ($0["languageCode"] as? String)?.hasPrefix("en") == true }
        let chosen = english.first { ($0["kind"] as? String) != "asr" } ?? english.first ?? tracks[0]
        guard var base = chosen["baseUrl"] as? String else { throw CaptionError.blocked }
        base = base.replacingOccurrences(of: "\\u0026", with: "&")
        if base.hasPrefix("/") { base = "https://www.youtube.com" + base }   // YouTube now serves relative paths
        if !base.contains("fmt=") { base += "&fmt=json3" }
        guard let url = URL(string: base) else { throw CaptionError.blocked }

        var capReq = URLRequest(url: url)
        capReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (capData, _) = try await URLSession.shared.data(for: capReq)
        return try cues(fromJSON3: capData)
    }

    /// Parses YouTube's json3 caption format into cues.
    static func cues(fromJSON3 data: Data) throws -> [Cue] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { throw CaptionError.empty }

        var cues: [Cue] = []
        for e in events {
            guard let startMs = e["tStartMs"] as? Double else { continue }
            let segs = (e["segs"] as? [[String: Any]]) ?? []
            let text = TranscriptParser.clean(segs.compactMap { $0["utf8"] as? String }.joined())
            guard !text.isEmpty else { continue }
            let dur = e["dDurationMs"] as? Double
            cues.append(Cue(start: startMs / 1000, end: dur.map { (startMs + $0) / 1000 }, text: text))
        }
        for i in cues.indices where i + 1 < cues.count {
            if let e = cues[i].end { cues[i].end = min(e, cues[i + 1].start) } else { cues[i].end = cues[i + 1].start }
        }
        guard !cues.isEmpty else { throw CaptionError.empty }
        return cues
    }

    private static func captionTracks(in html: String) -> [[String: Any]]? {
        guard let keyRange = html.range(of: "\"captionTracks\":") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        var i = keyRange.upperBound
        while i < html.endIndex {
            let c = html[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "[" { if depth == 0 { start = i }; depth += 1 }
                else if c == "]" {
                    depth -= 1
                    if depth == 0, let s = start {
                        let slice = String(html[s...i])
                        return try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [[String: Any]]
                    }
                }
            }
            i = html.index(after: i)
        }
        return nil
    }
}

// MARK: - In-page fetch (works where the plain request is refused)

import WebKit

/// Loads the mobile watch page in an offscreen web view and asks the page itself to download its
/// caption track. Running inside youtube.com's origin carries the session context YouTube requires.
@MainActor
final class WebCaptionFetcher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[Cue], Error>?
    private var timeoutTask: Task<Void, Never>?

    func fetch(videoID: String) async throws -> [Cue] {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .all     // never autoplay audio off-screen
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = self
        webView = wv
        let url = URL(string: "https://m.youtube.com/watch?v=\(videoID)&hl=en")!
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            wv.load(URLRequest(url: url))
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                self?.finish(.failure(CaptionError.blocked))
            }
        }
    }

    private func finish(_ result: Result<[Cue], Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        cont.resume(with: result)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { extract(from: webView) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    private func extract(from webView: WKWebView) {
        guard continuation != nil else { return }
        let body = """
        let pr = window.ytInitialPlayerResponse;
        let tracks = pr && pr.captions && pr.captions.playerCaptionsTracklistRenderer && pr.captions.playerCaptionsTracklistRenderer.captionTracks;
        if (!tracks) {
          const html = document.documentElement.innerHTML;
          const i = html.indexOf('"captionTracks":');
          if (i >= 0) {
            let depth = 0, inStr = false, esc = false, start = -1;
            for (let k = i + 16; k < html.length; k++) {
              const c = html[k];
              if (inStr) { if (esc) esc = false; else if (c === '\\\\') esc = true; else if (c === '"') inStr = false; }
              else if (c === '"') inStr = true;
              else if (c === '[') { if (depth === 0) start = k; depth++; }
              else if (c === ']') { depth--; if (depth === 0) { try { tracks = JSON.parse(html.slice(start, k + 1)); } catch (e) {} break; } }
            }
          }
        }
        if (!tracks || !tracks.length) return { error: 'noTracks' };
        const en = tracks.filter(t => (t.languageCode || '').startsWith('en'));
        const pick = en.find(t => t.kind !== 'asr') || en[0] || tracks[0];
        let url = pick.baseUrl.replace(/\\\\u0026/g, '&');
        if (url.startsWith('/')) url = location.origin + url;
        if (!url.includes('fmt=')) url += '&fmt=json3';
        const r = await fetch(url, { credentials: 'include' });
        const text = await r.text();
        return { json3: text, status: r.status };
        """
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(error))
            case .success(let value):
                guard let dict = value as? [String: Any] else { self.finish(.failure(CaptionError.blocked)); return }
                if dict["error"] != nil { self.finish(.failure(CaptionError.noTracks)); return }
                guard let text = dict["json3"] as? String, !text.isEmpty else { self.finish(.failure(CaptionError.blocked)); return }
                do {
                    self.finish(.success(try YouTubeCaptionFetcher.cues(fromJSON3: Data(text.utf8))))
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }
}
