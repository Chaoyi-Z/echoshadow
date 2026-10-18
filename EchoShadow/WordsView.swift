import SwiftData
import SwiftUI

struct WordsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedWord.dueAt) private var words: [SavedWord]
    @State private var reviewing = false

    private var due: [SavedWord] { words.filter(\.isDue) }

    var body: some View {
        NavigationStack {
            Group {
                if words.isEmpty {
                    ContentUnavailableView("No saved words", systemImage: "character.book.closed",
                                           description: Text("Tap any word while practicing to save it here for spaced review."))
                } else {
                    List {
                        if !due.isEmpty {
                            Section {
                                Button {
                                    reviewing = true
                                } label: {
                                    Label("Review \(due.count) due word\(due.count == 1 ? "" : "s")", systemImage: "rectangle.on.rectangle.angled")
                                        .font(.headline)
                                }
                            }
                        }
                        Section("All words") {
                            ForEach(words) { w in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(w.word).font(.headline)
                                        Spacer()
                                        Text(w.isDue ? "due" : w.dueAt.formatted(.relative(presentation: .named)))
                                            .font(.caption)
                                            .foregroundStyle(w.isDue ? Color.accentColor : .secondary)
                                    }
                                    Text(w.context).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    Text(w.lessonTitle).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .onDelete { offsets in offsets.forEach { context.delete(words[$0]) } }
                        }
                    }
                }
            }
            .navigationTitle("Words")
            .sheet(isPresented: $reviewing) { ReviewView(words: due) }
        }
    }
}

struct ReviewView: View {
    let words: [SavedWord]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = SpeechVoice()
    @State private var position = 0
    @State private var showContext = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if position < words.count {
                    let w = words[position]
                    Text("\(position + 1) / \(words.count)").font(.caption).foregroundStyle(.secondary)
                    Text(w.word).font(.system(size: 42, weight: .bold, design: .rounded))
                    Button { voice.speak(w.word, rate: 0.9) } label: { Label("Hear it", systemImage: "speaker.wave.2") }
                        .buttonStyle(.bordered)
                    if showContext {
                        Text(w.context).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
                    } else {
                        Button("Show the sentence") { showContext = true }
                    }
                    Spacer()
                    HStack(spacing: 16) {
                        Button { answer(w, remembered: false) } label: { Text("Again").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).tint(.red)
                        Button { answer(w, remembered: true) } label: { Text("Got it").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).tint(.green)
                    }
                } else {
                    ContentUnavailableView("All done", systemImage: "checkmark.seal", description: Text("Come back when more words are due."))
                    Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func answer(_ w: SavedWord, remembered: Bool) {
        w.review(remembered: remembered)
        showContext = false
        position += 1
    }
}
