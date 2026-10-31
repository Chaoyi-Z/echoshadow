import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Lesson.createdAt, order: .reverse) private var lessons: [Lesson]
    @Query private var allSentences: [Sentence]
    @State private var showAdd = false
    @State private var showSettings = false
    @Binding var importRequest: LessonPrefill?

    init(importRequest: Binding<LessonPrefill?> = .constant(nil)) {
        _importRequest = importRequest
    }

    private var due: [Sentence] { ReviewQueue.due(from: allSentences) }

    var body: some View {
        NavigationStack {
            Group {
                if lessons.isEmpty {
                    ContentUnavailableView {
                        Label("No lessons yet", systemImage: "waveform.badge.plus")
                    } description: {
                        Text("Add a YouTube video, an audio or video file, any text, or a talk script, then shadow it sentence by sentence.")
                    } actions: {
                        Button("Add a lesson") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            if due.isEmpty {
                                ReviewBanner(dueCount: 0, upcomingCount: ReviewQueue.upcoming(from: allSentences))
                            } else {
                                NavigationLink(value: ReviewRoute()) {
                                    ReviewBanner(dueCount: due.count, upcomingCount: 0)
                                }
                            }
                        }
                        ForEach(LessonCategory.allCases, id: \.self) { category in
                            // Bookmarked first, then newest.
                            let items = lessons.filter { $0.kind == category }
                                .sorted { ($0.isBookmarked ? 1 : 0, $0.createdAt) > ($1.isBookmarked ? 1 : 0, $1.createdAt) }
                            if !items.isEmpty {
                                Section(category.sectionTitle) {
                                    ForEach(items) { lesson in
                                        NavigationLink(value: lesson) { LessonRow(lesson: lesson) }
                                            .swipeActions(edge: .leading) {
                                                Button {
                                                    lesson.isBookmarked.toggle()
                                                } label: {
                                                    Label(lesson.isBookmarked ? "Remove bookmark" : "Bookmark",
                                                          systemImage: lesson.isBookmarked ? "bookmark.slash" : "bookmark")
                                                }
                                                .tint(.orange)
                                            }
                                    }
                                    .onDelete { offsets in delete(offsets.map { items[$0] }) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Echo Shadow")
            .navigationDestination(for: Lesson.self) { PracticeView(lesson: $0) }
            .navigationDestination(for: ReviewRoute.self) { _ in ReviewSessionView(due: due) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showAdd) { AddLessonView() }
            .sheet(item: $importRequest) { AddLessonView(prefill: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func delete(_ items: [Lesson]) {
        for lesson in items {
            if let name = lesson.fileName { MediaStore.remove(name) }
            context.delete(lesson)
        }
    }
}

struct LessonRow: View {
    let lesson: Lesson

    private var symbol: String {
        switch lesson.kind {
        case .rehearsal: return "person.wave.2"
        case .drill: return "target"
        case .article: return "newspaper"
        case .lesson: return lesson.source.symbol
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).foregroundStyle(Color.accentColor)
                Text(lesson.title).font(.headline).lineLimit(2)
                if lesson.isBookmarked {
                    Spacer()
                    Image(systemName: "bookmark.fill").foregroundStyle(.orange).accessibilityLabel("Bookmarked")
                }
            }
            if lesson.kind == .article {
                HStack(spacing: 12) {
                    if let site = lesson.siteName { Text(site) }
                    Text("~\(max(1, Int((Double(lesson.wordCount) / 150).rounded()))) min listen")
                    if lesson.currentIndex > 0, lesson.sentences.count > 1 {
                        Text("Resume at \(lesson.currentIndex + 1) of \(lesson.sentences.count)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("\(lesson.practicedCount)/\(lesson.sentences.count) sentences")
                if let avg = lesson.averageScore {
                    Text("avg \(Int((avg * 100).rounded()))%")
                }
                if lesson.kind == .rehearsal, let runs = lesson.runs, !runs.isEmpty {
                    Text("\(runs.count) run-through\(runs.count == 1 ? "" : "s")")
                }
                if let last = lesson.lastPracticedAt {
                    Text(last, format: .relative(presentation: .named))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(lesson.practicedCount), total: Double(max(1, lesson.sentences.count)))
                .tint(.accentColor)
        }
        .padding(.vertical, 4)
    }
}
