import Foundation

/// One caption cue: a start time, an optional end time, and its text.
struct Cue: Equatable {
    var start: Double
    var end: Double?
    var text: String
}

/// A sentence ready to be stored: where it starts and ends in the media, and its text.
struct SentenceDraft: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
    var text: String
}

enum TranscriptParser {
    // 0:00 · 12:34 · 1:02:03 · 00:00:01.500 · 00:00:01,500
    private static let stampPattern = #"(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?"#

    /// Parses pasted text that may be SRT/VTT or a copy of YouTube's "Show transcript" panel.
    /// Returns an empty array when no timestamps are found (treat as plain text).
    static func parse(_ raw: String) -> [Cue] {
        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.contains("-->") { return parseSRT(text) }
        return parseYouTube(text)
    }

    static func parseTimestamp(_ s: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "^" + stampPattern + "$") else { return nil }
        guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            return String(s[r])
        }
        let h = Double(group(1) ?? "") ?? 0
        let min = Double(group(2) ?? "") ?? 0
        let sec = Double(group(3) ?? "") ?? 0
        var frac = 0.0
        if let f = group(4), let v = Double(f) { frac = v / pow(10, Double(f.count)) }
        return h * 3600 + min * 60 + sec + frac
    }

    private static func parseYouTube(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        var pendingStart: Double?
        // A stamp at the start of a line, optionally wrapped in [] or (), optionally followed by text with or without a space.
        let leading = try? NSRegularExpression(pattern: #"^[\[(]?("# + stampPattern + #")[\])]?\s*(.*)$"#)
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let m = leading?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let stampRange = Range(m.range(at: 1), in: line),
               let t = parseTimestamp(String(line[stampRange])) {
                let rest = Range(m.range(at: 6), in: line).map { String(line[$0]) } ?? ""
                // Guard against plain text that merely starts with a number-colon pattern like "3:1 ratio".
                if let first = rest.first, first.isNumber || first == ":" { /* fall through to plain text */ } else {
                    let body = clean(rest)
                    if body.isEmpty { pendingStart = t } else { cues.append(Cue(start: t, end: nil, text: body)); pendingStart = nil }
                    continue
                }
            }
            let body = clean(line)
            if body.isEmpty { continue }
            if let t = pendingStart {
                cues.append(Cue(start: t, end: nil, text: body))
                pendingStart = nil
            } else if let last = cues.indices.last {
                cues[last].text += " " + body
            }
        }
        for i in cues.indices where i + 1 < cues.count { cues[i].end = cues[i + 1].start }
        return cues
    }

    private static func parseSRT(_ text: String) -> [Cue] {
        guard let arrow = try? NSRegularExpression(pattern: "^(" + stampPattern + #")\s*-->\s*("# + stampPattern + ")") else { return [] }
        var cues: [Cue] = []
        var current: Cue?
        func flush() {
            if let c = current, !c.text.isEmpty { cues.append(c) }
            current = nil
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let m = arrow.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                flush()
                let a = Range(m.range(at: 1), in: line).map { String(line[$0]) } ?? ""
                let b = Range(m.range(at: 6), in: line).map { String(line[$0]) } ?? ""
                current = Cue(start: parseTimestamp(a) ?? 0, end: parseTimestamp(b), text: "")
                continue
            }
            if line.isEmpty { flush(); continue }
            if line.uppercased().hasPrefix("WEBVTT") || line.hasPrefix("NOTE") { continue }
            if current == nil, Int(line) != nil { continue }
            if current != nil {
                let body = clean(line)
                if !body.isEmpty { current!.text += (current!.text.isEmpty ? "" : " ") + body }
            }
        }
        flush()
        return cues
    }

    /// Removes bracketed sound tags, HTML tags and stray caption markers.
    static func clean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"♪[^♪]*♪"#] {
            t = t.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: ">>", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Groups timed cues into sentence-sized chunks for shadowing.
    /// - Parameter paragraphCues: each cue is a paragraph of prose, so a cue boundary always ends a sentence.
    static func buildSentences(from cues: [Cue], mediaDuration: Double? = nil, paragraphCues: Bool = false) -> [SentenceDraft] {
        struct Word { let text: String; let time: Double; let cueIndex: Int; let cueEnd: Double? }
        var words: [Word] = []
        for (ci, cue) in cues.enumerated() {
            let parts = cue.text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            let end = cue.end ?? (cue.start + Double(parts.count) * 0.4)
            let dur = max(0, end - cue.start)
            for (i, p) in parts.enumerated() {
                words.append(Word(text: p, time: cue.start + dur * Double(i) / Double(parts.count), cueIndex: ci, cueEnd: cue.end))
            }
        }
        guard !words.isEmpty else { return [] }

        let terminators = words.filter { endsSentence($0.text) }.count
        let punctuated = Double(terminators) >= Double(words.count) / 30.0

        var drafts: [SentenceDraft] = []
        var current: [Word] = []
        func flush(nextStart: Double?) {
            guard let first = current.first, let last = current.last else { return }
            let fallbackEnd = last.cueEnd ?? mediaDuration ?? (last.time + 2.5)
            let end = nextStart ?? fallbackEnd
            drafts.append(SentenceDraft(start: first.time, end: max(end, first.time + 0.5), text: current.map(\.text).joined(separator: " ")))
            current.removeAll()
        }
        /// For a very long sentence: the last comma, semicolon, colon or dash that leaves two reasonable halves.
        func clauseBreak() -> Int? {
            guard current.count > 14 else { return nil }
            for k in stride(from: current.count - 4, through: 10, by: -1) {
                let t = current[k].text
                if t == "—" || t == "–" || t.hasSuffix(",") || t.hasSuffix(";") || t.hasSuffix(":") || t.hasSuffix("—") { return k }
            }
            return nil
        }
        for (i, w) in words.enumerated() {
            current.append(w)
            let next = i + 1 < words.count ? words[i + 1] : nil
            var shouldBreak = false
            if punctuated {
                let paragraphEnds = next.map { $0.cueIndex != w.cueIndex } ?? true
                shouldBreak = endsSentence(w.text) && (current.count >= 3 || paragraphEnds)
                if !shouldBreak, paragraphEnds, paragraphCues || current.count >= 24 { shouldBreak = true }
                if !shouldBreak, current.count >= 32, let k = clauseBreak() {
                    // Split a long sentence at a clause boundary rather than mid-phrase.
                    let rest = Array(current[(k + 1)...])
                    current = Array(current[...k])
                    flush(nextStart: rest.first?.time)
                    current = rest
                    continue
                }
                if !shouldBreak, current.count >= 45 { shouldBreak = true }
            } else if let n = next {
                let gap = n.time - w.time
                let cueBoundary = n.cueIndex != w.cueIndex
                shouldBreak = (cueBoundary && current.count >= 8) || (gap > 1.5 && current.count >= 3) || current.count >= 18
            }
            if shouldBreak || next == nil { flush(nextStart: next?.time) }
        }
        return drafts
    }

    /// Splits plain text (no timing) into sentences. Times are placeholders.
    static func splitPlainText(_ text: String) -> [SentenceDraft] {
        let paragraphs = text
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { cleanProse($0) }
            .filter { !$0.isEmpty }
        let cues = paragraphs.enumerated().map { Cue(start: Double($0.offset) * 1000, end: Double($0.offset) * 1000 + 999, text: $0.element) }
        return buildSentences(from: cues, paragraphCues: true).enumerated().map { SentenceDraft(start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element.text) }
    }

    /// Light cleanup for written text: keeps parentheses (unlike caption cleanup), drops footnote markers like [12].
    static func cleanProse(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[(\d+|[a-z]|citation needed|note \d+)\]"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func endsSentence(_ word: String) -> Bool {
        let t = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’»"))
        guard let last = t.last else { return false }
        if last == "?" || last == "!" || last == "…" { return true }
        if last == "." {
            let core = t.dropLast()
            if core.count <= 2, core.first?.isUppercase == true { return false }   // Mr. Dr. U.
            if core.contains(".") { return false }                                   // U.S. e.g.
            return !core.isEmpty
        }
        return false
    }
}
