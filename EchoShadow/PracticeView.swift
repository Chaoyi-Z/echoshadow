import AVKit
import SwiftData
import SwiftUI
import UIKit

struct PracticeView: View {
    @StateObject private var vm: PracticeViewModel
    @Environment(\.modelContext) private var context
    @State private var showList = false
    @State private var selectedWord: SelectedWord?
    @State private var showRunThrough = false
    private let review: ReviewContext?

    init(lesson: Lesson, only: [Sentence]? = nil, review: ReviewContext? = nil) {
        _vm = StateObject(wrappedValue: PracticeViewModel(lesson: lesson, only: only, isReview: review != nil))
        self.review = review
    }

    var body: some View {
        VStack(spacing: 0) {
            mediaArea
            ScrollView {
                VStack(spacing: 18) {
                    header
                    sentenceCard
                    if let score = vm.score { scoreCard(score) }
                    if vm.phase == .recording { liveTranscript }
                    controls
                }
                .padding()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(vm.lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if vm.lesson.kind == .rehearsal, review == nil {
                    Button { showRunThrough = true } label: { Label("Run-through", systemImage: "person.wave.2.fill") }
                        .help("Record the whole talk and get pacing and clarity feedback")
                }
                Button {
                    vm.dictation.toggle()
                    vm.revealed = false
                } label: {
                    Image(systemName: vm.dictation ? "eye.slash.fill" : "eye")
                }
                .help("Dictation mode hides some words until you record")
                if review == nil {
                    Button { showList = true } label: { Image(systemName: "list.bullet") }
                }
            }
        }
        .sheet(isPresented: $showList) { SentenceListView(vm: vm) }
        .fullScreenCover(isPresented: $showRunThrough) { RunThroughView(lesson: vm.lesson) }
        .sheet(item: $selectedWord) { WordSheet(selection: $0, lessonTitle: vm.lesson.title) }
        .alert("Something went wrong", isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onDisappear { vm.teardown() }
    }

    // MARK: Media

    @ViewBuilder private var mediaArea: some View {
        ZStack {
            Color.black
            if let yt = vm.youtube {
                YouTubePlayerView(controller: yt)
                if let err = yt.loadError {
                    Text(err).foregroundStyle(.white).padding().multilineTextAlignment(.center)
                }
            } else if let local = vm.local {
                if vm.lesson.isVideo {
                    PlayerLayerView(player: local.player)
                } else {
                    audioPlaceholder(time: local.currentTime)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.and.person.filled").font(.system(size: 44)).foregroundStyle(.white.opacity(0.9))
                    Text("Synthetic voice").font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func audioPlaceholder(time: Double) -> some View {
        VStack(spacing: 10) {
            Image(systemName: vm.phase == .listening ? "waveform" : "waveform.slash")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.9))
                .symbolEffect(.variableColor.iterative, isActive: vm.phase == .listening)
            Text(time.clockString).font(.footnote.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            if let review {
                Label("Review \(review.position + 1) of \(review.total)", systemImage: "arrow.counterclockwise")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Sentence \(vm.index + 1) of \(vm.sentences.count)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let s = vm.current, s.dueAt != nil, review == nil {
                Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.orange)
                    .help("In your review queue")
            }
            if let s = vm.current, s.attempts > 0 {
                Label("\(Int((s.bestScore * 100).rounded()))%", systemImage: "star.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(scoreColor(s.bestScore))
            }
        }
    }

    // MARK: Sentence

    private var sentenceCard: some View {
        let tokens = (vm.current?.text ?? "").split(separator: " ").map(String.init)
        let statusByWord: [String: ScoreResult.Status] = {
            var map: [String: ScoreResult.Status] = [:]
            for w in vm.score?.words ?? [] { map[w.text] = w.status }
            return map
        }()
        let assessments = vm.wordAssessments(for: tokens)
        return VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 6) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { i, token in
                    let hidden = vm.isHidden(wordAt: i, in: tokens)
                    let assessment = assessments[i]
                    Button {
                        if hidden { vm.revealed = true } else { selectedWord = SelectedWord(word: token, context: vm.current?.text ?? "", assessment: assessment) }
                    } label: {
                        VStack(spacing: 1) {
                            Text(hidden ? String(repeating: "•", count: max(3, token.count)) : token)
                                .font(.title2.weight(.medium))
                                .foregroundStyle(assessment.map { azureColor($0) } ?? color(for: statusByWord[token], hidden: hidden))
                            if let a = assessment, !hidden {
                                Text(a.isOmitted ? "—" : "\(Int(a.accuracy.rounded()))")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(azureColor(a))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if vm.pronunciation != nil {
                Text("Tap a word to see each sound.").font(.caption).foregroundStyle(.secondary)
            }
            if vm.hasMedia, let s = vm.current {
                Text("\(s.start.clockString) – \(s.end.clockString)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            if vm.isFreeVideo {
                Text("This transcript had no timestamps: use the video's own controls to watch, and Listen reads the sentence aloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if vm.dictation && !vm.revealed {
                Text("Dictation: listen, then record. Tap a hidden word to reveal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func azureColor(_ a: WordAssessment) -> Color {
        if a.isOmitted { return .red }
        return a.accuracy >= 80 ? .green : (a.accuracy >= 60 ? .orange : .red)
    }

    private func color(for status: ScoreResult.Status?, hidden: Bool) -> Color {
        if hidden { return .secondary }
        switch status {
        case .correct: return .green
        case .wrong: return .orange
        case .missing: return .red
        case nil: return .primary
        }
    }

    // MARK: Score

    private func scoreCard(_ score: ScoreResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int((score.percent * 100).rounded()))%")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor(score.percent))
                Text("\(score.correctCount) of \(score.words.count) words")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Button {
                    Task { await vm.compare() }
                } label: {
                    Label(vm.isComparing ? "Playing…" : "Original, then mine", systemImage: "arrow.left.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isComparing || vm.phase == .recording)
                Button {
                    vm.playMyRecording()
                } label: {
                    Label("Mine", systemImage: "person.wave.2")
                }
                .buttonStyle(.bordered)
            }
            if !vm.recognizedText.isEmpty {
                Text("Heard: “\(vm.recognizedText)”").font(.subheadline).italic().foregroundStyle(.secondary)
            }
            if vm.isAssessing {
                HStack { ProgressView(); Text("Scoring each sound…").font(.caption).foregroundStyle(.secondary) }
            } else if let p = vm.pronunciation {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(p.pronScore.rounded()))").font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(scoreColor(p.pronScore / 100))
                    Text("pronunciation").foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    miniScore("Accuracy", p.accuracy)
                    miniScore("Fluency", p.fluency)
                    miniScore("Complete", p.completeness)
                    if let prosody = p.prosody { miniScore("Prosody", prosody) }
                }
            } else if let err = vm.assessmentError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            if vm.addedToReview {
                Label("Added to tomorrow's review", systemImage: "arrow.counterclockwise.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup(isExpanded: $vm.showIntonation) {
                IntonationPanel(result: vm.intonation, loading: vm.isLoadingIntonation)
                    .padding(.top, 6)
            } label: {
                Label("Intonation", systemImage: "waveform.path.ecg").font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 14) {
                legend(.green, "matched")
                legend(.orange, "different")
                legend(.red, "missed")
            }.font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func miniScore(_ label: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(value.rounded()))").font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(scoreColor(value / 100))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 8, height: 8); Text(text).foregroundStyle(.secondary) }
    }

    private var liveTranscript: some View {
        Text(vm.recognizedText.isEmpty ? "Listening…" : vm.recognizedText)
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 16) {
            if vm.hasMedia {
                HStack {
                    Picker("Speed", selection: $vm.rate) {
                        Text("0.5×").tag(Float(0.5))
                        Text("0.75×").tag(Float(0.75))
                        Text("1×").tag(Float(1.0))
                        Text("1.25×").tag(Float(1.25))
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: $vm.loop) { Image(systemName: "repeat") }
                        .toggleStyle(.button)
                        .help("Loop this sentence")
                }
            } else {
                Picker("Speed", selection: $vm.rate) {
                    Text("Slow").tag(Float(0.7))
                    Text("Normal").tag(Float(1.0))
                    Text("Fast").tag(Float(1.2))
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 28) {
                if review == nil {
                    Button { vm.previous() } label: { Image(systemName: "backward.end.fill").font(.title2) }
                        .disabled(vm.index == 0)
                }
                Button { vm.toggleListen() } label: {
                    Image(systemName: vm.phase == .listening ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                .disabled(vm.phase == .recording || vm.isComparing || (vm.hasMedia && vm.youtube != nil && !(vm.youtube?.isReady ?? false)))
                if review == nil {
                    Button { vm.next() } label: { Image(systemName: "forward.end.fill").font(.title2) }
                        .disabled(vm.index >= vm.sentences.count - 1)
                }
            }

            Button {
                Task { await vm.toggleRecord() }
            } label: {
                Label(vm.phase == .recording ? "Stop & score" : "Record my voice",
                      systemImage: vm.phase == .recording ? "stop.fill" : "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.phase == .recording ? .red : .accentColor)

            if vm.score != nil && vm.phase != .recording {
                HStack {
                    Button("Try again") { Task { await vm.toggleRecord() } }.buttonStyle(.bordered)
                    Spacer()
                    if let review {
                        Button {
                            vm.teardown()
                            review.onNext()
                        } label: {
                            Label(review.position + 1 < review.total ? "Next review" : "Finish", systemImage: "arrow.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isAssessing)
                    } else {
                        Button { vm.next() } label: { Label("Next sentence", systemImage: "arrow.right") }
                            .buttonStyle(.bordered)
                            .disabled(vm.index >= vm.sentences.count - 1)
                    }
                }
            } else if let review, vm.phase != .recording {
                Button("Skip for now") {
                    vm.teardown()
                    review.onNext()
                }
                .font(.subheadline)
            }
        }
    }

    private func scoreColor(_ p: Double) -> Color {
        p >= 0.9 ? .green : (p >= 0.7 ? .orange : .red)
    }
}

struct SelectedWord: Identifiable {
    let id = UUID()
    let word: String
    let context: String
    var assessment: WordAssessment? = nil
}

// MARK: - Sentence list

struct SentenceListView: View {
    @ObservedObject var vm: PracticeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(vm.sentences.enumerated()), id: \.offset) { i, s in
                    Button {
                        vm.jump(to: i)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                            Text(s.text).foregroundStyle(i == vm.index ? Color.accentColor : .primary)
                            Spacer()
                            if s.attempts > 0 {
                                Text("\(Int((s.bestScore * 100).rounded()))%")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(s.bestScore >= 0.9 ? .green : (s.bestScore >= 0.7 ? .orange : .red))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sentences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Word sheet

struct WordSheet: View {
    let selection: SelectedWord
    let lessonTitle: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = SpeechVoice()
    @State private var showDictionary = false
    @State private var saved = false

    private var cleanWord: String {
        selection.word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(cleanWord).font(.largeTitle.bold())
                if let a = selection.assessment {
                    PhonemeRow(assessment: a)
                }
                Text(selection.context).foregroundStyle(.secondary)
                HStack {
                    Button { voice.speak(cleanWord, rate: 0.9) } label: { Label("Hear it", systemImage: "speaker.wave.2") }
                    Button { showDictionary = true } label: { Label("Define", systemImage: "book") }
                        .disabled(!UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: cleanWord))
                }
                .buttonStyle(.bordered)
                Button {
                    context.insert(SavedWord(word: cleanWord, context: selection.context, lessonTitle: lessonTitle))
                    saved = true
                } label: {
                    Label(saved ? "Saved for review" : "Save word", systemImage: saved ? "checkmark" : "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(saved)
                Spacer()
            }
            .padding()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showDictionary) { DictionaryView(term: cleanWord) }
        }
        .presentationDetents([.medium])
    }
}

/// Each sound of the word with its Azure accuracy score, red where it went wrong.
struct PhonemeRow: View {
    let assessment: WordAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if assessment.isOmitted {
                Label("You skipped this word", systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.subheadline)
            } else if assessment.phonemes.isEmpty {
                Text("Word accuracy \(Int(assessment.accuracy.rounded()))").font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(assessment.phonemes) { p in
                        VStack(spacing: 2) {
                            Text("/\(p.phoneme)/").font(.title3.weight(.semibold))
                            Text("\(Int(p.accuracy.rounded()))").font(.caption2.monospacedDigit())
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(color(p.accuracy).opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(color(p.accuracy))
                    }
                }
                Text("Word accuracy \(Int(assessment.accuracy.rounded())). Sounds in red are the ones to practise.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ v: Double) -> Color { v >= 80 ? .green : (v >= 60 ? .orange : .red) }
}

struct DictionaryView: UIViewControllerRepresentable {
    let term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }
    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
