import AVFoundation
import SwiftData
import SwiftUI

// MARK: - Recording a whole talk

@MainActor
final class LongRecorder: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var isRecording = false
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("run-through.m4a")
    static let maxDuration: TimeInterval = 20 * 60

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var player: AVAudioPlayer?
    var onAutoStop: (() -> Void)?

    func start() async throws {
        guard await SpeechRecorder.requestPermissions() else { throw RecorderError.denied }
        try AudioSession.configure()
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw RecorderError.noInput }
        recorder = r
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                self.elapsed = r.currentTime
                // -50 dB..0 dB mapped to 0..1
                self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
                if r.currentTime >= Self.maxDuration { self.onAutoStop?() }
            }
        }
    }

    /// Stops and returns the recorded length in seconds.
    func stop() -> TimeInterval {
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        level = 0
        return duration
    }

    func cancel() {
        _ = stop()
        try? FileManager.default.removeItem(at: url)
    }

    func play() {
        try? AudioSession.configure()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func stopPlaying() { player?.stop() }
}

// MARK: - Analysis

struct RehearsalReport {
    let duration: Double
    let wordCount: Int
    let wordsPerMinute: Double
    let coverage: Double
    let longPauses: Int
    let longestPause: Double
    let fillers: Int
    let fillerBreakdown: [String: Int]
    let sentenceCoverage: [(text: String, coverage: Double)]
    let transcript: String

    var paceLabel: String {
        switch wordsPerMinute {
        case ..<115: return "slow"
        case ..<130: return "a little slow"
        case ..<165: return "good pace"
        case ..<185: return "a little fast"
        default: return "fast"
        }
    }

    var weakSentences: [(text: String, coverage: Double)] {
        sentenceCoverage.filter { $0.coverage < 0.6 }
    }
}

enum RehearsalAnalyzer {
    static let fillerWords: Set<String> = ["um", "uh", "uhm", "umm", "er", "erm", "ah", "hmm", "mm"]
    static let longPause = 1.5

    static func analyze(cues: [Cue], duration: Double, script: [String]) -> RehearsalReport {
        let spokenRaw = cues.flatMap { $0.text.split(separator: " ").map(String.init) }
        let spoken = spokenRaw.map { WordAlignment.normalize($0).joined() }.filter { !$0.isEmpty }
        var breakdown: [String: Int] = [:]
        for w in spoken where fillerWords.contains(w) { breakdown[w, default: 0] += 1 }
        let content = spoken.filter { !fillerWords.contains($0) }

        var pauses = 0
        var longest = 0.0
        for (a, b) in zip(cues, cues.dropFirst()) {
            let gap = b.start - (a.end ?? a.start)
            if gap >= longPause { pauses += 1 }
            longest = max(longest, gap)
        }

        // Script tokens, remembering which sentence each belongs to.
        var tokens: [String] = []
        var owner: [Int] = []
        for (i, sentence) in script.enumerated() {
            for t in sentence.split(separator: " ") {
                let n = WordAlignment.normalize(String(t)).joined()
                guard !n.isEmpty else { continue }
                tokens.append(n)
                owner.append(i)
            }
        }
        let matched = ScriptAligner.matches(script: tokens, spoken: content)
        var perSentence = Array(repeating: (hit: 0, total: 0), count: script.count)
        for (k, hit) in matched.enumerated() {
            perSentence[owner[k]].total += 1
            if hit { perSentence[owner[k]].hit += 1 }
        }
        let sentenceCoverage = script.enumerated().map { i, text in
            (text: text, coverage: perSentence[i].total == 0 ? 1 : Double(perSentence[i].hit) / Double(perSentence[i].total))
        }
        let coverage = tokens.isEmpty ? 0 : Double(matched.filter { $0 }.count) / Double(tokens.count)
        let minutes = max(duration, 1) / 60
        return RehearsalReport(
            duration: duration,
            wordCount: content.count,
            wordsPerMinute: Double(content.count) / minutes,
            coverage: coverage,
            longPauses: pauses,
            longestPause: longest,
            fillers: breakdown.values.reduce(0, +),
            fillerBreakdown: breakdown,
            sentenceCoverage: sentenceCoverage,
            transcript: cues.map(\.text).joined(separator: " "))
    }
}

/// Word-level alignment of a whole script against what was said, fast enough for a 20-minute talk.
enum ScriptAligner {
    static func matches(script a: [String], spoken b: [String]) -> [Bool] {
        let n = a.count, m = b.count
        guard n > 0 else { return [] }
        guard m > 0 else { return Array(repeating: false, count: n) }

        // Compare each distinct word pair once instead of once per cell.
        let uniqueA = Array(Set(a)), uniqueB = Array(Set(b))
        let indexA = Dictionary(uniqueKeysWithValues: uniqueA.enumerated().map { ($1, $0) })
        let indexB = Dictionary(uniqueKeysWithValues: uniqueB.enumerated().map { ($1, $0) })
        let ub = uniqueB.count
        var similar = [Bool](repeating: false, count: uniqueA.count * ub)
        for (i, wa) in uniqueA.enumerated() {
            for (j, wb) in uniqueB.enumerated() where WordAlignment.similar(wa, wb) { similar[i * ub + j] = true }
        }
        let ida = a.map { indexA[$0]! }, idb = b.map { indexB[$0]! }

        guard n * m <= 9_000_000 else { return windowed(ida, idb, similar: similar, ub: ub) }

        let width = m + 1
        var dirs = [UInt8](repeating: 2, count: (n + 1) * width)   // 0 match, 3 substitute, 1 skip script word, 2 extra spoken word
        var prev = [Int32](repeating: 0, count: width)
        var cur = [Int32](repeating: 0, count: width)
        for j in 0...m { prev[j] = Int32(j) }
        for i in 1...n {
            cur[0] = Int32(i)
            dirs[i * width] = 1
            let rowA = ida[i - 1] * ub
            for j in 1...m {
                let hit = similar[rowA + idb[j - 1]]
                let diag = prev[j - 1] + (hit ? 0 : 1)
                let up = prev[j] + 1
                let left = cur[j - 1] + 1
                if diag <= up && diag <= left {
                    cur[j] = diag
                    dirs[i * width + j] = hit ? 0 : 3
                } else if up <= left {
                    cur[j] = up
                    dirs[i * width + j] = 1
                } else {
                    cur[j] = left
                    dirs[i * width + j] = 2
                }
            }
            swap(&prev, &cur)
        }
        var matched = [Bool](repeating: false, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            switch dirs[i * width + j] {
            case 0: matched[i - 1] = true; i -= 1; j -= 1
            case 3: i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        return matched
    }

    /// Fallback for very long inputs: match each script word within a moving window of the speech.
    private static func windowed(_ a: [Int], _ b: [Int], similar: [Bool], ub: Int) -> [Bool] {
        var matched = [Bool](repeating: false, count: a.count)
        var cursor = 0
        for (k, word) in a.enumerated() {
            let lo = max(0, cursor - 5), hi = min(b.count, cursor + 25)
            if lo < hi, let hit = (lo..<hi).first(where: { similar[word * ub + b[$0]] }) {
                matched[k] = true
                cursor = hit + 1
            } else {
                cursor = min(b.count, cursor + 1)
            }
        }
        return matched
    }
}

@MainActor
enum RehearsalCoach {
    static func feedback(script: String, report: RehearsalReport) async -> String? {
        let settings = AppSettings.shared
        guard settings.chatConfigured, let provider = try? ChatProviderFactory.make(from: settings) else { return nil }
        let limit = settings.chatProvider == .apple ? 1200 : 5000
        provider.reset(instructions: "You are a supportive presentation coach for a non-native English-speaking scientist rehearsing a talk. Be concrete and brief. Plain text only, no markdown, no asterisks.")
        let weak = report.weakSentences.prefix(4).map { "- \($0.text)" }.joined(separator: "\n")
        let prompt = """
        Here is my talk script and what I actually said in a full run-through, with measurements.

        Measurements: \(Int(report.duration.rounded())) seconds, \(Int(report.wordsPerMinute.rounded())) words per minute, \
        \(Int((report.coverage * 100).rounded()))% of the script delivered, \(report.longPauses) pauses over \(RehearsalAnalyzer.longPause) seconds, \
        \(report.fillers) filler sounds.

        Script:
        \(String(script.prefix(limit)))

        What I said (speech recognition, may contain errors):
        \(String(report.transcript.prefix(limit)))

        Sentences I skipped or garbled:
        \(weak.isEmpty ? "none" : weak)

        There is no time limit or target length, so don't comment on total duration. Talks land well at 130 to 160 words per minute.
        Give me 4 to 6 short, specific points on clarity, pacing, emphasis and wording, quoting my words where useful, then one sentence of encouragement. Under 180 words.
        """
        guard let reply = try? await provider.send(prompt) else { return nil }
        return reply.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Screen

struct RunThroughView: View {
    enum Stage: Equatable {
        case ready, recording, transcribing(Double), done, failed(String)
    }

    let lesson: Lesson
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @StateObject private var recorder = LongRecorder()
    @State private var stage: Stage = .ready
    @State private var report: RehearsalReport?
    @State private var feedback: String?
    @State private var loadingFeedback = false
    @State private var savedRun: RehearsalRun?

    private var script: [String] { lesson.orderedSentences.map(\.text) }
    private var pastRuns: [RehearsalRun] { (lesson.runs ?? []).sorted { $0.date > $1.date } }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .ready: readyView
                case .recording: recordingView
                case .transcribing(let p): progressView(p)
                case .done: reportView
                case .failed(let message): failedView(message)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Run-through")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(stage == .recording ? "Cancel" : "Close") {
                        if stage == .recording { recorder.cancel(); stage = .ready } else { recorder.stopPlaying(); dismiss() }
                    }
                }
            }
        }
        .onAppear { recorder.onAutoStop = { Task { await finish() } } }
        .interactiveDismissDisabled(stage == .recording)
    }

    // MARK: Stages

    private var readyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Deliver the whole talk as if you were presenting. When you stop, Echo Shadow transcribes it on this phone and measures pace, pauses, fillers and how much of the script you delivered, then asks your conversation partner for coaching.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    Task {
                        do {
                            try await recorder.start()
                            stage = .recording
                        } catch {
                            stage = .failed(error.localizedDescription)
                        }
                    }
                } label: {
                    Label("Start run-through", systemImage: "record.circle").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                if !pastRuns.isEmpty {
                    Text("Previous run-throughs").font(.headline).padding(.top, 8)
                    ForEach(pastRuns) { run in RunRow(run: run) }
                }
                Text("Script").font(.headline).padding(.top, 8)
                Text(script.joined(separator: " ")).font(.body).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var recordingView: some View {
        VStack(spacing: 16) {
            HStack {
                Circle().fill(.red).frame(width: 12, height: 12)
                Text(recorder.elapsed.clockString).font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                Spacer()
                LevelMeter(level: recorder.level).frame(width: 90, height: 10)
            }
            .padding(.horizontal)
            ScrollView {
                Text(script.joined(separator: "\n\n"))
                    .font(.title3)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            Button {
                Task { await finish() }
            } label: {
                Label("Stop & analyse", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding(.top)
    }

    private func progressView(_ p: Double) -> some View {
        VStack(spacing: 14) {
            ProgressView(value: p).padding(.horizontal, 40)
            Text("Transcribing on this phone… \(Int(p * 100))%").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't analyse the run-through", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { stage = .ready }.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var reportView: some View {
        if let report {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        tile(report.duration.clockString, "duration", .blue)
                        tile("\(Int(report.wordsPerMinute.rounded()))", "words/min · \(report.paceLabel)", report.paceLabel == "good pace" ? .green : .orange)
                        tile("\(Int((report.coverage * 100).rounded()))%", "of script delivered", report.coverage >= 0.85 ? .green : (report.coverage >= 0.6 ? .orange : .red))
                        tile("\(report.longPauses)", "pauses over \(String(format: "%.1f", RehearsalAnalyzer.longPause)) s", report.longPauses <= 3 ? .green : .orange)
                        tile("\(report.fillers)", "filler sounds", report.fillers <= 3 ? .green : .orange)
                        tile(String(format: "%.1f s", report.longestPause), "longest pause", report.longestPause < 3 ? .green : .orange)
                    }
                    Text("Talks usually land well at 130–160 words per minute. Apple's recognizer leaves out some “um” and “uh”, so the filler count is a minimum.")
                        .font(.caption).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Coach", systemImage: "graduationcap").font(.headline)
                        if loadingFeedback {
                            HStack { ProgressView(); Text("Asking your partner model…").font(.subheadline).foregroundStyle(.secondary) }
                        } else if let feedback {
                            Text(feedback)
                        } else {
                            Text("Set up a conversation partner in Settings to get written coaching on each run-through.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    if !report.weakSentences.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sentences to rework").font(.headline)
                            ForEach(Array(report.weakSentences.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top) {
                                    Text(item.text).font(.subheadline)
                                    Spacer()
                                    Text("\(Int((item.coverage * 100).rounded()))%").font(.caption.weight(.semibold)).foregroundStyle(.red)
                                }
                            }
                            Text("Shadow these one at a time in the lesson, then try another run-through.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }

                    DisclosureGroup("What the recognizer heard") {
                        Text(report.transcript).font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    HStack {
                        Button { recorder.play() } label: { Label("Play recording", systemImage: "play.fill") }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button { recorder.stopPlaying(); stage = .ready } label: { Label("Run again", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Actions

    private func finish() async {
        guard stage == .recording else { return }
        let duration = recorder.stop()
        guard duration >= 3 else { stage = .failed("The recording was too short. Speak for at least a few seconds."); return }
        stage = .transcribing(0)
        do {
            var cues: [Cue]
            do {
                cues = try await FileTranscriber().transcribe(url: recorder.url) { p in stage = .transcribing(p) }
            } catch {
                #if DEBUG
                // The simulator has no speech service; the demo flag substitutes a sample delivery.
                guard ProcessInfo.processInfo.arguments.contains("-seedDemo") else { throw error }
                cues = DemoData.sampleDelivery(of: script)
                #else
                throw error
                #endif
            }
            let lines = script
            let result = await Task.detached(priority: .userInitiated) {
                RehearsalAnalyzer.analyze(cues: cues, duration: duration, script: lines)
            }.value
            report = result
            stage = .done
            let run = RehearsalRun(duration: result.duration, wordsPerMinute: result.wordsPerMinute, coverage: result.coverage,
                                   longPauses: result.longPauses, fillers: result.fillers, transcript: result.transcript)
            run.lesson = lesson
            context.insert(run)
            lesson.lastPracticedAt = .now
            savedRun = run
            loadingFeedback = true
            feedback = await RehearsalCoach.feedback(script: lines.joined(separator: " "), report: result)
            loadingFeedback = false
            run.feedback = feedback ?? ""
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }
}

struct RunRow: View {
    let run: RehearsalRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.date, format: .dateTime.month().day().hour().minute()).font(.subheadline.weight(.semibold))
                Spacer()
                Text(run.duration.clockString).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("\(Int(run.wordsPerMinute.rounded())) wpm")
                Text("\(Int((run.coverage * 100).rounded()))% delivered")
                Text("\(run.longPauses) pauses")
                Text("\(run.fillers) fillers")
            }
            .font(.caption).foregroundStyle(.secondary)
            if !run.feedback.isEmpty {
                DisclosureGroup("Coach notes") { Text(run.feedback).font(.caption).padding(.top, 2) }
                    .font(.caption)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(level > 0.85 ? Color.red : Color.green)
                    .frame(width: geo.size.width * CGFloat(level))
            }
        }
    }
}
