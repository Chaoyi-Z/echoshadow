import AVFoundation
import Foundation
import Speech

enum RecorderError: LocalizedError {
    case denied
    case unavailable
    case noInput

    var errorDescription: String? {
        switch self {
        case .denied: return "Microphone or speech recognition permission was denied. Enable both in Settings ▸ Echo Shadow."
        case .unavailable: return "Speech recognition is not available right now."
        case .noInput: return "No microphone input is available."
        }
    }
}

/// Records the user's voice to a file while streaming it to the speech recognizer.
/// In continuous mode a new recognition segment starts whenever Apple ends one (about once a minute),
/// so a single turn can run for several minutes without losing text.
final class SpeechRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var onPartial: (@MainActor (String) -> Void)?
    private var continuous = false
    private var running = false
    private var generation = 0
    /// Text from segments that have finished, and the segment in progress.
    private var committed = ""
    private var currentSegment = ""
    private var latest = ""
    private(set) var lastError: Error?
    private(set) var startedAt: Date?
    /// Voice activity from the microphone level (guarded by `lock`, written on the audio thread).
    private var lastVoice = Date()
    private var noiseFloor: Float = 0.004
    private var playback: AVAudioPlayer?
    let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("my-recording.caf")

    static func requestPermissions() async -> Bool {
        let speech = await FileTranscriber.requestAuthorization()
        let mic: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        return speech && mic
    }

    var hasRecording: Bool { FileManager.default.fileExists(atPath: recordingURL.path) }
    var isPlaying: Bool { playback?.isPlaying ?? false }

    func start(continuous: Bool = false, onPartial: @escaping @MainActor (String) -> Void) async throws {
        guard await Self.requestPermissions() else { throw RecorderError.denied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw RecorderError.unavailable
        }
        try AudioSession.configure()
        guard AVAudioSession.sharedInstance().isInputAvailable else { throw RecorderError.noInput }
        playback?.stop()

        self.recognizer = recognizer
        self.onPartial = onPartial
        self.continuous = continuous
        committed = ""
        currentSegment = ""
        latest = ""
        lastError = nil

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        try? FileManager.default.removeItem(at: recordingURL)
        let file = try AVAudioFile(forWriting: recordingURL, settings: format.settings)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let rms = Self.rms(buffer)
            self.lock.lock()
            let current = self.request
            // Track the background noise slowly; anything well above it counts as the learner's voice.
            if rms < self.noiseFloor {
                self.noiseFloor = self.noiseFloor * 0.9 + rms * 0.1
            } else {
                self.noiseFloor = self.noiseFloor * 0.998 + rms * 0.002
            }
            if rms > max(0.008, self.noiseFloor * 3) { self.lastVoice = Date() }
            self.lock.unlock()
            current?.append(buffer)
            try? file.write(from: buffer)
        }
        lock.lock()
        lastVoice = Date()
        noiseFloor = 0.004
        lock.unlock()
        engine.prepare()
        try engine.start()
        running = true
        startedAt = Date()
        startSegment()
    }

    private func startSegment() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = continuous
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        lock.lock()
        request = req
        lock.unlock()
        generation += 1
        let mine = generation
        // Callbacks arrive on the main queue (the recognizer's default).
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, mine == self.generation else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty { self.currentSegment = text }
                self.latest = self.joined()
                let full = self.latest
                if let handler = self.onPartial { Task { @MainActor in handler(full) } }
                if result.isFinal { self.segmentEnded() }
            } else if let error {
                // "No speech"/cancel errors after endAudio are normal; keep the text we heard.
                let ns = error as NSError
                if !(ns.domain == "kAFAssistantErrorDomain" && [1110, 1101, 216, 203, 209, 301].contains(ns.code)) { self.lastError = error }
                self.segmentEnded()
            }
        }
    }

    private func joined() -> String {
        [committed, currentSegment].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Apple ended a segment (time limit, silence or error). Keep its text and, while recording, start the next one.
    private func segmentEnded() {
        generation += 1
        committed = joined()
        currentSegment = ""
        latest = committed
        if running && continuous { startSegment() }
    }

    /// Seconds since the microphone last heard the learner's voice (including "um" and slow words).
    var secondsSinceVoice: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastVoice)
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        return (sum / Float(n)).squareRoot()
    }

    /// Seconds since recording started.
    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// Stops recording and returns everything recognized during the turn.
    func stop() async -> String {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let current = request
        lock.unlock()
        current?.endAudio()
        // Give the recognizer a moment to deliver its final hypothesis.
        try? await Task.sleep(for: .milliseconds(800))
        let result = joined().isEmpty ? latest : joined()
        generation += 1
        task?.cancel()
        task = nil
        lock.lock()
        request = nil
        lock.unlock()
        startedAt = nil
        return result
    }

    func cancel() {
        running = false
        generation += 1
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
        task?.cancel()
        task = nil
        startedAt = nil
    }

    func playRecording() {
        guard hasRecording else { return }
        try? AudioSession.configure()
        playback = try? AVAudioPlayer(contentsOf: recordingURL)
        playback?.play()
    }
}

// MARK: - Scoring

struct ScoreResult {
    enum Status { case correct, wrong, missing }
    struct Word: Identifiable {
        let id = UUID()
        let text: String
        let status: Status
    }
    let words: [Word]
    let extras: [String]
    let percent: Double

    var correctCount: Int { words.filter { $0.status == .correct }.count }
}

enum WordAlignment {
    private static let numberWords: [String: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six", "7": "seven",
        "8": "eight", "9": "nine", "10": "ten", "11": "eleven", "12": "twelve", "13": "thirteen", "14": "fourteen",
        "15": "fifteen", "16": "sixteen", "17": "seventeen", "18": "eighteen", "19": "nineteen", "20": "twenty",
        "30": "thirty", "40": "forty", "50": "fifty", "60": "sixty", "70": "seventy", "80": "eighty", "90": "ninety",
        "100": "hundred", "1000": "thousand"
    ]

    static func normalize(_ s: String) -> [String] {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))
        var cleaned = ""
        for scalar in lowered.unicodeScalars {
            cleaned.unicodeScalars.append(allowed.contains(scalar) ? scalar : " ")
        }
        return cleaned.split(separator: " ")
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
            .map { numberWords[$0] ?? $0 }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let tolerance = max(a.count, b.count) >= 7 ? 2 : (min(a.count, b.count) >= 4 ? 1 : 0)
        return tolerance > 0 && levenshtein(a, b) <= tolerance
    }

    static func score(target: String, spoken: String) -> ScoreResult {
        let tokens = target.split(separator: " ").map(String.init).filter { !normalize($0).isEmpty }
        let t = tokens.map { normalize($0).joined() }
        let s = normalize(spoken)
        let n = t.count, m = s.count
        guard n > 0 else { return ScoreResult(words: [], extras: s, percent: 0) }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        if m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let cost = similar(t[i - 1], s[j - 1]) ? 0 : 1
                    dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
                }
            }
        }

        var statuses = Array(repeating: ScoreResult.Status.missing, count: n)
        var extras: [String] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let match = similar(t[i - 1], s[j - 1])
                if dp[i][j] == dp[i - 1][j - 1] + (match ? 0 : 1) {
                    statuses[i - 1] = match ? .correct : .wrong
                    i -= 1; j -= 1
                    continue
                }
            }
            if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
                statuses[i - 1] = .missing
                i -= 1
            } else if j > 0 {
                extras.append(s[j - 1])
                j -= 1
            } else {
                i -= 1
            }
        }
        let words = zip(tokens, statuses).map { ScoreResult.Word(text: $0, status: $1) }
        let correct = statuses.filter { $0 == .correct }.count
        return ScoreResult(words: words, extras: extras.reversed(), percent: Double(correct) / Double(n))
    }
}
