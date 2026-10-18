import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Something handed to the app from outside (share sheet, "Open in", or an echoshadow:// link).
struct LessonPrefill: Identifiable, Equatable {
    enum Content: Equatable {
        case youtube(String)
        case file(URL)
        case text(String)
    }
    let id = UUID()
    let content: Content
    var title: String?
}

struct AddLessonView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case youtube = "YouTube", file = "Audio/Video", text = "Text", script = "Script"
        var id: String { rawValue }
    }

    var prefill: LessonPrefill?
    @State private var appliedPrefill = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @State private var kind: Kind = .youtube
    @State private var title = ""
    @State private var urlText = ""
    @State private var transcript = ""
    @State private var plainText = ""
    @State private var cues: [Cue] = []
    @State private var storedFileName: String?
    @State private var isVideo = false
    @State private var showImporter = false
    @State private var busy = false
    @State private var progress = 0.0
    @State private var status: String?
    @State private var errorText: String?

    private var videoID: String? { YouTubeCaptionFetcher.videoID(from: urlText) }

    /// Sentences that will be saved, derived from whatever source is filled in.
    private var drafts: [SentenceDraft] {
        switch kind {
        case .youtube:
            if !cues.isEmpty { return TranscriptParser.buildSentences(from: cues) }
            let parsed = TranscriptParser.parse(transcript)
            if !parsed.isEmpty { return TranscriptParser.buildSentences(from: parsed) }
            return TranscriptParser.splitPlainText(transcript)
        case .file:
            return TranscriptParser.buildSentences(from: cues)
        case .text, .script:
            return TranscriptParser.splitPlainText(plainText)
        }
    }

    /// A YouTube lesson whose pasted transcript has no timestamps becomes a text lesson.
    private var youtubeHasTiming: Bool {
        !cues.isEmpty || !TranscriptParser.parse(transcript).isEmpty
    }

    private var canSave: Bool {
        guard !busy, !drafts.isEmpty else { return false }
        switch kind {
        case .youtube: return videoID != nil || !youtubeHasTiming
        case .file: return storedFileName != nil
        case .text, .script: return true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Source", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .onChange(of: kind) { _, _ in
                    cues = []
                    errorText = nil
                    // A title that arrived with an import belongs to that import, not to a different source.
                    if let t = prefill?.title, title == t { title = "" }
                }

                switch kind {
                case .youtube:
                    youtubeSection
                    transcriptSection
                case .file: fileSection
                case .text: textSection
                case .script: scriptSection
                }

                Section("Title") {
                    TextField("Lesson title", text: $title)
                }

                Section {
                    if busy {
                        HStack {
                            ProgressView(value: progress)
                            Text(status ?? "Working…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    } else if !drafts.isEmpty {
                        Label("\(drafts.count) sentences ready. Tap Save.", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        if kind == .youtube && !youtubeHasTiming {
                            Label("No timestamps in this transcript. The video will be included with its own controls, but Listen will use a synthetic voice. For playback synced to each sentence, copy the transcript with timestamps shown (toggle in YouTube's transcript panel).", systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    } else {
                        Label(emptyHint, systemImage: "info.circle").foregroundStyle(.orange).font(.footnote)
                    }
                }
            }
            .navigationTitle("New lesson")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie, .audiovisualContent], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { Task { await importFile(url) } }
            }
            .interactiveDismissDisabled(busy)
            .task { await applyPrefill() }
        }
    }

    private func applyPrefill() async {
        guard let prefill, !appliedPrefill else { return }
        appliedPrefill = true
        if let t = prefill.title, title.isEmpty { title = t }
        switch prefill.content {
        case .youtube(let link):
            kind = .youtube
            urlText = link
        case .text(let text):
            kind = .text
            plainText = text
        case .file(let url):
            kind = .file
            // Let the segmented picker settle before the importer resets cues on kind change.
            try? await Task.sleep(for: .milliseconds(100))
            await importFile(url)
        }
    }

    private var emptyHint: String {
        switch kind {
        case .youtube:
            return videoID == nil
                ? "Step 1: paste a YouTube link."
                : "Step 2: paste the video's transcript below. Save turns on once sentences are detected."
        case .file: return "Choose an audio or video file to transcribe."
        case .text: return "Type or paste some English text."
        case .script: return "Paste the script of your talk or presentation."
        }
    }

    // MARK: Sections

    private var youtubeSection: some View {
        Section {
            TextField("YouTube link or video ID", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onChange(of: urlText) { _, _ in
                    cues = []
                    errorText = nil
                    if let id = videoID, title.isEmpty || title.hasPrefix("YouTube ") {
                        Task {
                            if let t = await YouTubeCaptionFetcher.fetchTitle(videoID: id), videoID == id { title = t }
                        }
                    }
                }
            Button {
                Task { await fetchCaptions() }
            } label: {
                Label(cues.isEmpty ? "Try fetching captions automatically" : "Captions fetched (\(cues.count) cues)", systemImage: cues.isEmpty ? "captions.bubble" : "checkmark.circle.fill")
            }
            .disabled(videoID == nil || busy)
            if let id = videoID {
                Button {
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(id)") { openURL(url) }
                } label: {
                    Label("Open video to copy its transcript", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            Text("Step 1: video")
        } footer: {
            Text("YouTube usually blocks automatic caption download, so the transcript needs to be pasted. On a computer or in Safari with “Request Desktop Website”: open the video ▸ description ▸ Show transcript ▸ select all ▸ copy. Then paste it in Step 2.")
        }
    }

    private var transcriptSection: some View {
        Section {
            TextEditor(text: $transcript)
                .frame(minHeight: 120)
                .font(.footnote)
                .autocorrectionDisabled()
                .onChange(of: transcript) { _, _ in errorText = nil }
        } header: {
            Text(cues.isEmpty ? "Step 2: transcript (paste here)" : "Transcript (optional, captions already fetched)")
        } footer: {
            Text("Timestamps like 0:12 keep sentences in sync with the video. SRT/VTT subtitles work too. No transcript handy? The Audio/Video tab transcribes a downloaded file entirely on this phone.")
        }
    }

    private var fileSection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label(storedFileName == nil ? "Choose audio or video file" : "File imported", systemImage: storedFileName == nil ? "folder" : "checkmark.circle.fill")
            }
            .disabled(busy)
        } header: {
            Text("File")
        } footer: {
            Text("The file is copied into the app and transcribed on this device with Apple's speech recognizer. Longer files take a while.")
        }
    }

    private var textSection: some View {
        Section {
            TextEditor(text: $plainText).frame(minHeight: 160)
        } header: {
            Text("Text to shadow")
        } footer: {
            Text("Any English text. A synthetic voice reads each sentence for you to repeat.")
        }
    }

    private var scriptSection: some View {
        Section {
            TextEditor(text: $plainText).frame(minHeight: 200)
        } header: {
            Text("Talk script")
        } footer: {
            Text("Paste the script of a conference talk, lab meeting or presentation. Shadow it sentence by sentence with pronunciation scores, then use Run-through (top right in the lesson) to record the whole talk and get feedback on pace, pauses, fillers and clarity.")
        }
    }

    // MARK: Actions

    private func fetchCaptions() async {
        guard let id = videoID else { return }
        busy = true; status = "Fetching captions…"; progress = 0.3; errorText = nil
        defer { busy = false }
        async let fetchedTitle = YouTubeCaptionFetcher.fetchTitle(videoID: id)
        let webFetcher = WebCaptionFetcher()
        do {
            // Strategy 1: ask the YouTube page itself (carries the session context YouTube requires).
            cues = try await webFetcher.fetch(videoID: id)
        } catch let firstError {
            do {
                // Strategy 2: plain request to the caption endpoint.
                cues = try await YouTubeCaptionFetcher.fetchCaptions(videoID: id)
            } catch {
                errorText = (firstError as? CaptionError)?.errorDescription ?? error.localizedDescription
            }
        }
        if title.isEmpty, let t = await fetchedTitle { title = t }
        progress = 1
    }

    private func importFile(_ url: URL) async {
        busy = true; errorText = nil; progress = 0; status = "Copying file…"
        defer { busy = false }
        do {
            if let old = storedFileName { MediaStore.remove(old) }
            let name = try MediaStore.importFile(from: url)
            storedFileName = name
            isVideo = MediaStore.isVideo(url)
            if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
            status = "Transcribing on device…"
            cues = try await FileTranscriber().transcribe(url: MediaStore.url(for: name)) { p in
                progress = p
                status = "Transcribing on device… \(Int(p * 100))%"
            }
        } catch {
            errorText = error.localizedDescription
            cues = []
        }
    }

    private func save() {
        let sentences = drafts
        guard !sentences.isEmpty else { return }
        let lesson: Lesson
        switch kind {
        case .youtube:
            if let id = videoID {
                lesson = Lesson(title: title.isEmpty ? "YouTube \(id)" : title, source: .youtube, youtubeID: id, isTimed: youtubeHasTiming)
            } else {
                lesson = Lesson(title: title.isEmpty ? "Text lesson" : title, source: .text)
            }
        case .file:
            lesson = Lesson(title: title.isEmpty ? "Imported file" : title, source: .localFile, fileName: storedFileName, isVideo: isVideo)
        case .text:
            lesson = Lesson(title: title.isEmpty ? String(plainText.prefix(40)) : title, source: .text)
        case .script:
            lesson = Lesson(title: title.isEmpty ? "Talk: " + String(plainText.prefix(34)) : title, source: .text, category: .rehearsal)
        }
        context.insert(lesson)
        for (i, d) in sentences.enumerated() {
            let s = Sentence(index: i, start: d.start, end: d.end, text: d.text)
            s.lesson = lesson
            context.insert(s)
        }
        dismiss()
    }

    private func cancel() {
        if let name = storedFileName { MediaStore.remove(name) }
        dismiss()
    }
}
