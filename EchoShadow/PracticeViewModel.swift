import Combine
import Foundation
import SwiftData
import SwiftUI

/// Present when a sentence is being practised as part of the cross-lesson review queue.
struct ReviewContext {
    let position: Int
    let total: Int
    let onNext: () -> Void
}

@MainActor
final class PracticeViewModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, recording, scored }

    let lesson: Lesson
    let isReview: Bool
    @Published private(set) var sentences: [Sentence]
    @Published private(set) var index: Int
    @Published var rate: Float = 1.0 { didSet { player?.setRate(rate) } }
    @Published var loop = false
    @Published var dictation = false
    @Published var revealed = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var score: ScoreResult?
    @Published private(set) var recognizedText = ""
    @Published var errorMessage: String?
    @Published private(set) var pronunciation: PronunciationResult?
    @Published private(set) var isAssessing = false
    @Published private(set) var assessmentError: String?
    /// Final score of the latest attempt (Azure when available, otherwise word match).
    @Published private(set) var lastAttemptScore: Double?
    /// True when the latest attempt put the sentence into tomorrow's review.
    @Published private(set) var addedToReview = false
    @Published private(set) var isComparing = false
    @Published private(set) var intonation: IntonationResult?
    @Published private(set) var isLoadingIntonation = false
    @Published var showIntonation = false {
        didSet { if showIntonation, intonation == nil, !isLoadingIntonation { Task { await loadIntonation() } } }
    }

    let youtube: YouTubePlayerController?
    let local: LocalPlayerController?
    let voice = SpeechVoice()
    let recorder = SpeechRecorder()

    private var player: (any MediaPlayer)? {
        if let youtube { return youtube }
        return local
    }
    private var cancellables = Set<AnyCancellable>()
    private var segmentStart: Double = 0
    private var segmentEnd: Double?
    private var ignoreTicksUntil = Date.distantPast

    var current: Sentence? { sentences.indices.contains(index) ? sentences[index] : nil }
    /// Whether Listen plays a span of the media (timed lesson) rather than the synthetic voice.
    var hasMedia: Bool { lesson.source != .text && lesson.isTimed }
    /// Untimed YouTube lesson: video is on screen with its own controls, sentences are read aloud.
    var isFreeVideo: Bool { lesson.source == .youtube && !lesson.isTimed }
    var isBusy: Bool { phase == .listening || phase == .recording }

    init(lesson: Lesson, only subset: [Sentence]? = nil, isReview: Bool = false) {
        self.lesson = lesson
        self.isReview = isReview
        let ordered = subset ?? lesson.orderedSentences
        self.sentences = ordered
        self.index = subset == nil ? min(max(0, lesson.currentIndex), max(0, ordered.count - 1)) : 0
        switch lesson.source {
        case .youtube:
            youtube = YouTubePlayerController(videoID: lesson.youtubeID ?? "", showsControls: !lesson.isTimed)
            local = nil
        case .localFile:
            local = lesson.fileName.map { LocalPlayerController(url: MediaStore.url(for: $0)) }
            youtube = nil
        case .text:
            youtube = nil
            local = nil
        }
        player?.onTime = { [weak self] t in self?.tick(t) }
        // Re-render the practice screen when a player or the voice changes state.
        youtube?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        local?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        voice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        try? AudioSession.configure()
    }

    // MARK: Playback

    private func tick(_ t: Double) {
        guard let end = segmentEnd, Date() >= ignoreTicksUntil, t >= end - 0.03 else { return }
        if loop {
            ignoreTicksUntil = Date().addingTimeInterval(0.5)
            player?.seek(to: segmentStart)
        } else {
            player?.pause()
            segmentEnd = nil
            if phase == .listening { phase = .idle }
        }
    }

    func listen() {
        guard let s = current else { return }
        if phase == .recording { return }
        if !hasMedia {
            phase = .listening
            voice.speak(s.text, rate: rate)
            // The voice relay flips isSpeaking back; mirror that into phase.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                while let vm = self, vm.voice.isSpeaking { try? await Task.sleep(for: .milliseconds(100)) }
                if let vm = self, vm.phase == .listening { vm.phase = vm.score == nil ? .idle : .scored }
            }
            return
        }
        guard lesson.isTimed else { return }
        segmentStart = s.start
        segmentEnd = s.end
        ignoreTicksUntil = Date().addingTimeInterval(0.5)
        player?.seek(to: s.start)
        player?.setRate(rate)
        player?.play()
        phase = .listening
    }

    func stopPlayback() {
        player?.pause()
        voice.stop()
        segmentEnd = nil
        if phase == .listening { phase = score == nil ? .idle : .scored }
    }

    func toggleListen() {
        if phase == .listening { stopPlayback() } else { listen() }
    }

    // MARK: Navigation

    func jump(to newIndex: Int) {
        guard sentences.indices.contains(newIndex) else { return }
        stopPlayback()
        if phase == .recording { recorder.cancel() }
        index = newIndex
        if !isReview { lesson.currentIndex = newIndex }
        score = nil
        pronunciation = nil
        assessmentError = nil
        lastAttemptScore = nil
        addedToReview = false
        intonation = nil
        recognizedText = ""
        revealed = false
        phase = .idle
    }

    func next() { jump(to: index + 1) }
    func previous() { jump(to: index - 1) }

    // MARK: Recording

    func toggleRecord() async {
        if phase == .recording { await finishRecording() } else { await startRecording() }
    }

    private func startRecording() async {
        stopPlayback()
        do {
            try await recorder.start { [weak self] partial in self?.recognizedText = partial }
            recognizedText = ""
            score = nil
            pronunciation = nil
            assessmentError = nil
            lastAttemptScore = nil
            addedToReview = false
            intonation = nil
            phase = .recording
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishRecording() async {
        let text = await recorder.stop()
        recognizedText = text
        guard let s = current else { phase = .idle; return }
        let result = WordAlignment.score(target: s.text, spoken: text)
        score = result
        revealed = true
        phase = .scored
        s.attempts += 1
        if result.percent > s.bestScore { s.bestScore = result.percent }
        lesson.lastPracticedAt = .now
        logPractice()
        if showIntonation { Task { await loadIntonation() } }
        await assessPronunciation(reference: s.text, sentence: s)
        let final = pronunciation.map { $0.pronScore / 100 } ?? result.percent
        lastAttemptScore = final
        // An empty recording is a mis-tap, not a weak sentence.
        if !text.isEmpty || pronunciation != nil {
            s.recordAttempt(score: final)
            addedToReview = final < 0.7
        }
    }

    /// Sound-by-sound scoring through Azure when a key is configured; silent otherwise.
    private func assessPronunciation(reference: String, sentence: Sentence) async {
        let settings = AppSettings.shared
        guard settings.azureConfigured else { return }
        isAssessing = true
        defer { isAssessing = false }
        do {
            let assessor = PronunciationAssessor(key: settings.azureKey, regionOrHost: settings.azureRegion)
            let result = try await assessor.assess(audioFile: recorder.recordingURL, referenceText: reference)
            pronunciation = result
            // Azure's overall score is the better record of progress when available.
            sentence.bestScore = max(sentence.bestScore, result.pronScore / 100)
            // Feed the weak-sound tracker.
            if let context = lesson.modelContext {
                for word in result.referenceWords where !word.isOmitted {
                    for p in word.phonemes {
                        context.insert(PhonemeSample(phoneme: PhonemeCatalog.normalize(p.phoneme), accuracy: p.accuracy, word: word.word.lowercased()))
                    }
                }
            }
        } catch {
            assessmentError = error.localizedDescription
        }
    }

    /// Azure word results lined up with the sentence's display tokens (nil where no match).
    func wordAssessments(for tokens: [String]) -> [WordAssessment?] {
        guard let words = pronunciation?.referenceWords else { return Array(repeating: nil, count: tokens.count) }
        var result: [WordAssessment?] = []
        var cursor = 0
        for token in tokens {
            let key = WordAlignment.normalize(token).joined()
            var found: WordAssessment?
            var probe = cursor
            while probe < words.count, probe < cursor + 3 {
                if WordAlignment.normalize(words[probe].word).joined() == key {
                    found = words[probe]
                    cursor = probe + 1
                    break
                }
                probe += 1
            }
            result.append(found)
        }
        return result
    }

    func playMyRecording() {
        stopPlayback()
        recorder.playRecording()
    }

    // MARK: Compare

    /// Plays the original sentence, then the learner's recording, back to back.
    func compare() async {
        guard recorder.hasRecording, phase != .recording, !isComparing else { return }
        isComparing = true
        defer { isComparing = false }
        let wasLooping = loop
        loop = false
        listen()
        try? await Task.sleep(for: .milliseconds(250))
        while phase == .listening { try? await Task.sleep(for: .milliseconds(100)) }
        loop = wasLooping
        try? await Task.sleep(for: .milliseconds(350))
        recorder.playRecording()
        try? await Task.sleep(for: .milliseconds(150))
        while recorder.isPlaying { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Why the original's pitch can't be drawn, when it can't.
    var originalPitchUnavailableReason: String? {
        lesson.source == .youtube && lesson.isTimed
            ? "YouTube doesn't give apps access to the video's audio, so only your curve is shown."
            : nil
    }

    func loadIntonation() async {
        guard let s = current, recorder.hasRecording else { return }
        isLoadingIntonation = true
        defer { isLoadingIntonation = false }
        let mineSamples = (try? await AudioLoader.monoSamples(url: recorder.recordingURL)) ?? []
        var reference: (samples: [Float], sampleRate: Double)?
        switch lesson.source {
        case .localFile:
            if let name = lesson.fileName,
               let samples = try? await AudioLoader.monoSamples(url: MediaStore.url(for: name), start: s.start, end: s.end) {
                reference = (samples, 16000)
            }
        case .text:
            reference = await ReferenceAudio.render(text: s.text, rate: rate)
        case .youtube:
            if !lesson.isTimed { reference = await ReferenceAudio.render(text: s.text, rate: rate) }
        }
        let note = originalPitchUnavailableReason
        let result = await Task.detached(priority: .userInitiated) {
            IntonationResult(
                mine: PitchTracker.contour(samples: mineSamples, sampleRate: 16000, speaker: "You"),
                original: reference.map { PitchTracker.contour(samples: $0.samples, sampleRate: $0.sampleRate, speaker: "Original") },
                note: nil)
        }.value
        if let note, !result.mine.isEmpty {
            intonation = IntonationResult(mine: result.mine, original: nil, note: note + " " + result.advice)
        } else {
            intonation = result
        }
    }

    private func logPractice() {
        guard let context = lesson.modelContext else { return }
        let today = Calendar.current.startOfDay(for: .now)
        let descriptor = FetchDescriptor<PracticeDay>(predicate: #Predicate { $0.day == today })
        if let day = try? context.fetch(descriptor).first {
            day.sentencesPracticed += 1
        } else {
            context.insert(PracticeDay(day: today, sentencesPracticed: 1))
        }
    }

    // MARK: Dictation helpers

    /// Words hidden in dictation mode: every other word of 4+ letters.
    func isHidden(wordAt i: Int, in tokens: [String]) -> Bool {
        guard dictation, !revealed else { return false }
        var count = 0
        for (k, w) in tokens.enumerated() {
            if WordAlignment.normalize(w).joined().count >= 4 {
                count += 1
                if k == i { return count % 2 == 1 }
            } else if k == i {
                return false
            }
        }
        return false
    }

    func teardown() {
        stopPlayback()
        if phase == .recording { recorder.cancel() }
    }
}
