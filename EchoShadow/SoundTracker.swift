import Charts
import SwiftData
import SwiftUI

// MARK: - Phoneme catalogue

/// The American English sounds Azure scores, with an example word and a short articulation tip.
enum PhonemeCatalog {
    struct Info {
        let example: String
        let tip: String
    }

    static let table: [String: Info] = [
        "θ": Info(example: "think", tip: "Put the tongue tip lightly between your teeth and blow air out, with no voice. It is not /s/ or /f/."),
        "ð": Info(example: "this", tip: "Same tongue position as /θ/, but add voice: you should feel a buzz. It is not /d/ or /z/."),
        "ɹ": Info(example: "red", tip: "Pull the tongue back without touching the roof of the mouth and round the lips a little. The tip never taps."),
        "l": Info(example: "light", tip: "Press the tongue tip on the ridge behind the top teeth and let air flow around the sides. At the end of a word, keep the tip up."),
        "v": Info(example: "very", tip: "Rest the top teeth on the lower lip and add voice. Not /w/ and not /b/."),
        "w": Info(example: "we", tip: "Round the lips tightly, then open quickly. The teeth never touch the lip."),
        "f": Info(example: "fine", tip: "Top teeth on the lower lip, blow air out without voice."),
        "ɪ": Info(example: "sit", tip: "Short and relaxed, lips not spread. Shorter and lower than the vowel in 'seat'."),
        "i": Info(example: "see", tip: "Long, with the lips spread as in a smile."),
        "æ": Info(example: "cat", tip: "Drop the jaw wide and spread the lips, between 'eh' and 'ah'."),
        "ɛ": Info(example: "bed", tip: "Half-open mouth, short. Less open than /æ/."),
        "ʊ": Info(example: "book", tip: "Short, with loosely rounded lips. Shorter than the vowel in 'food'."),
        "u": Info(example: "blue", tip: "Long, with tightly rounded lips."),
        "ʌ": Info(example: "cup", tip: "A short, relaxed 'uh' with the mouth half open."),
        "ɑ": Info(example: "father", tip: "Open the jaw, tongue low and back."),
        "ɔ": Info(example: "law", tip: "Open mouth with slightly rounded lips."),
        "ə": Info(example: "about", tip: "The weak 'uh' in unstressed syllables. Keep it short and quiet, never a full vowel."),
        "ɝ": Info(example: "bird", tip: "A stressed 'er': hold the /r/ tongue position for the whole vowel."),
        "ɚ": Info(example: "butter", tip: "An unstressed 'er' at the end of words: light and short."),
        "eɪ": Info(example: "say", tip: "Glide from 'eh' up to 'ee'."),
        "aɪ": Info(example: "my", tip: "Glide from 'ah' up to 'ee'."),
        "aʊ": Info(example: "now", tip: "Glide from 'ah' to 'oo', rounding the lips."),
        "oʊ": Info(example: "go", tip: "Glide from 'oh' to 'oo', rounding the lips at the end."),
        "ɔɪ": Info(example: "boy", tip: "Glide from 'aw' to 'ee'."),
        "ŋ": Info(example: "sing", tip: "Back of the tongue against the soft palate, air through the nose. Don't add a /g/ at the end."),
        "n": Info(example: "no", tip: "Tongue tip on the ridge behind the teeth, air through the nose. Keep it at the end of words."),
        "m": Info(example: "me", tip: "Lips closed, air through the nose."),
        "z": Info(example: "zoo", tip: "Like /s/ but with voice; feel the buzz. This is the sound of most plural -s endings."),
        "s": Info(example: "see", tip: "Tongue tip close to the ridge behind the teeth, a thin stream of air."),
        "ʃ": Info(example: "she", tip: "Push the lips forward and pull the tongue slightly back."),
        "ʒ": Info(example: "vision", tip: "Like /ʃ/ with voice."),
        "tʃ": Info(example: "chair", tip: "Start with /t/ and release into /ʃ/."),
        "dʒ": Info(example: "jump", tip: "Start with /d/ and release into /ʒ/, with voice."),
        "j": Info(example: "yes", tip: "Tongue close to the roof of the mouth, then glide into the vowel."),
        "h": Info(example: "hat", tip: "Just breath, no scraping in the throat."),
        "p": Info(example: "pen", tip: "Close the lips and release with a small puff of air."),
        "b": Info(example: "bed", tip: "Close the lips and release with voice, no puff."),
        "t": Info(example: "ten", tip: "Tongue tip on the ridge, release with air. Don't drop it at the end of words."),
        "d": Info(example: "day", tip: "Like /t/ with voice. Keep it audible at the end of words like 'played'."),
        "k": Info(example: "cat", tip: "Back of the tongue against the soft palate, release with air."),
        "g": Info(example: "go", tip: "Like /k/ with voice."),
    ]

    /// Stores sounds in one spelling regardless of how Azure wrote them.
    static func normalize(_ raw: String) -> String {
        var p = raw.lowercased()
        for mark in ["ˈ", "ˌ", "ː", "."] { p = p.replacingOccurrences(of: mark, with: "") }
        p = p.replacingOccurrences(of: "ɡ", with: "g")
        if p == "r" { p = "ɹ" }
        return p
    }

    /// What the learner sees: /r/ instead of the IPA turned r.
    static func display(_ p: String) -> String { p == "ɹ" ? "r" : p }
    static func example(_ p: String) -> String { table[p]?.example ?? "" }
    static func tip(_ p: String) -> String { table[p]?.tip ?? "Listen to the original carefully and copy the mouth shape." }
    static func label(_ p: String) -> String {
        let e = example(p)
        return e.isEmpty ? "/\(display(p))/" : "/\(display(p))/ as in “\(e)”"
    }
}

// MARK: - Statistics

struct SoundStat: Identifiable, Hashable {
    let phoneme: String
    let average: Double
    let count: Int
    let recent: Double?
    let earlier: Double?
    let weakWords: [String]

    var id: String { phoneme }
    var trend: Double? {
        guard let recent, let earlier else { return nil }
        return recent - earlier
    }
}

enum SoundStats {
    /// Weakest sounds first. Uses the last 30 days when there is enough data there.
    static func compute(_ samples: [PhonemeSample], now: Date = .now, minCount: Int = 6) -> [SoundStat] {
        let cal = Calendar.current
        let month = cal.date(byAdding: .day, value: -30, to: now) ?? now
        let week = cal.date(byAdding: .day, value: -7, to: now) ?? now
        let windowed = samples.filter { $0.date >= month }
        let pool = windowed.count >= 20 ? windowed : samples
        let grouped = Dictionary(grouping: pool, by: \.phoneme)
        var stats: [SoundStat] = []
        for (phoneme, items) in grouped where items.count >= minCount {
            let avg = items.map(\.accuracy).reduce(0, +) / Double(items.count)
            let recentItems = items.filter { $0.date >= week }
            let earlierItems = items.filter { $0.date < week }
            let recent = recentItems.count >= 3 ? recentItems.map(\.accuracy).reduce(0, +) / Double(recentItems.count) : nil
            let earlier = earlierItems.count >= 3 ? earlierItems.map(\.accuracy).reduce(0, +) / Double(earlierItems.count) : nil
            let missed = items.filter { $0.accuracy < 60 }.map(\.word)
            let counts = Dictionary(missed.map { ($0, 1) }, uniquingKeysWith: +)
            let weakWords = counts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
            stats.append(SoundStat(phoneme: phoneme, average: avg, count: items.count, recent: recent, earlier: earlier, weakWords: weakWords))
        }
        return stats.sorted { $0.average < $1.average }
    }

    static func daily(_ samples: [PhonemeSample], phoneme: String) -> [(day: Date, average: Double)] {
        let cal = Calendar.current
        let items = samples.filter { $0.phoneme == phoneme }
        let grouped = Dictionary(grouping: items) { cal.startOfDay(for: $0.date) }
        return grouped.map { (day: $0.key, average: $0.value.map(\.accuracy).reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.day < $1.day }
    }
}

// MARK: - Drill generation

@MainActor
enum DrillGenerator {
    /// Sentences dense with the given sounds: written by the conversation model when one is set up,
    /// otherwise taken from a built-in bank.
    static func sentences(for phonemes: [String], weakWords: [String], perSound: Int = 4) async -> [String] {
        if let ai = await aiSentences(for: phonemes, weakWords: weakWords, perSound: perSound), ai.count >= 3 {
            return ai
        }
        return phonemes.flatMap { bankSentences(for: $0, weakWords: weakWords).prefix(perSound) }
    }

    static func makeLesson(phonemes: [String], weakWords: [String], context: ModelContext) async -> Lesson {
        let lines = await sentences(for: phonemes, weakWords: weakWords, perSound: phonemes.count > 1 ? 3 : 6)
        let names = phonemes.map { "/\(PhonemeCatalog.display($0))/" }.joined(separator: " ")
        let title = phonemes.count == 1
            ? "Drill \(names) · \(PhonemeCatalog.example(phonemes[0]))"
            : "Drill \(names)"
        let lesson = Lesson(title: title, source: .text, category: .drill)
        context.insert(lesson)
        for (i, line) in lines.enumerated() {
            let s = Sentence(index: i, start: Double(i), end: Double(i) + 1, text: line)
            s.lesson = lesson
            context.insert(s)
        }
        return lesson
    }

    private static func aiSentences(for phonemes: [String], weakWords: [String], perSound: Int) async -> [String]? {
        let settings = AppSettings.shared
        guard settings.chatConfigured, let provider = try? ChatProviderFactory.make(from: settings) else { return nil }
        provider.reset(instructions: "You write short pronunciation practice sentences for an adult learner of American English. Output only the sentences, one per line, with no numbering, quotes, headings or extra text.")
        let sounds = phonemes.map { PhonemeCatalog.label($0) }.joined(separator: "; ")
        var prompt = phonemes.count == 1
            ? "Write \(perSound) natural, everyday sentences of 6 to 12 words. Each sentence must contain the sound \(sounds) at least three times, in common words, at the start, middle and end of words."
            : "Write \(perSound) natural, everyday sentences of 6 to 12 words for each of these sounds, in this order: \(sounds). Each sentence must contain its sound at least three times, in common words."
        if !weakWords.isEmpty {
            prompt += " Where it fits naturally, use some of these words the learner found hard: \(weakWords.prefix(6).joined(separator: ", "))."
        }
        guard let reply = try? await provider.send(prompt) else { return nil }
        return parseLines(reply)
    }

    static func parseLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: #"^(\d+[.)]|[-*•])\s*"#, with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”*' "))
            guard !line.hasSuffix(":"), !line.contains("/") else { return nil }
            let words = line.split(separator: " ").count
            guard (4...25).contains(words) else { return nil }
            if let last = line.last, !".!?".contains(last) { line += "." }
            return line
        }
    }

    /// Hand-written sentences for the sounds that are hardest for most learners.
    static func bankSentences(for phoneme: String, weakWords: [String]) -> [String] {
        let bank: [String: [String]] = [
            "θ": ["I think three thin thieves thanked Theo.", "Thank you for thinking about the theory.", "The month of March is the third month.", "My throat feels thick when I'm tired.", "Both authors thought the method was worth it.", "He threw the thermometer through the window."],
            "ð": ["This is the weather they mentioned yesterday.", "My mother and father gathered there together.", "Those are the clothes I bought with them.", "Then they went further than the others.", "Rather than that, they'd rather breathe.", "Neither brother bothered to bathe."],
            "ɹ": ["Robert really wants to run around the river.", "Every rainy morning I read a red book.", "The results are ready for the review on Friday.", "Our research room is right around the corner.", "Rachel wrote a brief report on rare rocks.", "Try to arrive early for the rehearsal."],
            "l": ["Lily likes to listen to lovely little songs.", "Please leave the lab light on until eleven.", "Let's look at the last slide of the lecture.", "The large lemon fell on the floor.", "Laura will call the hotel later.", "I feel well when I walk a mile."],
            "v": ["Victor gave a very vivid overview of the evidence.", "I've never visited a village in Vermont.", "We have five valid values here.", "Every evening I review the video.", "Vivian moved over to the visitor's van.", "Have you received the revised version?"],
            "w": ["We went to work while it was wet and windy.", "Would you wait a while for William?", "Why was the window wide open?", "We wanted one warm sweater.", "Wendy walked away without a word.", "What will we watch this weekend?"],
            "ɪ": ["This big ship will sit in the city.", "It's a bit difficult to fit in.", "Bill lives in a little building.", "Did Jim finish his chips?", "The kids sit in the middle of the gym.", "Is this list in the system?"],
            "i": ["Please keep the green seat clean.", "We need three cheap sheets.", "She sees the sea each week.", "Pete eats peas and beans.", "Keep these keys for the meeting.", "We agreed to meet at the beach."],
            "æ": ["The black cat sat on Pam's map.", "Sam had a bad habit of packing late.", "That man has a happy laugh.", "Can you grab the last apple?", "Jack's lab has a fancy fan.", "Thanks for the snack and the jam."],
            "ɛ": ["Ten red pens are on the desk.", "Ben sent the letter yesterday.", "Get ready to test the best method.", "Every guest left at seven.", "Let's check the next set of results.", "Ted said the bread was fresh."],
            "ʊ": ["Could you put the good book on the wood?", "I took a look at the cookbook.", "He stood by the brook and shook.", "Would you push the full cart?", "The cook should look at the hood.", "Put your foot on the cushion."],
            "u": ["Sue knew the blue moon rose soon.", "Do you choose new shoes in June?", "The food at school is too cool.", "Who flew to Cuba in June?", "Lucy moved to a room with a view.", "The group used two new tools."],
            "ŋ": ["I'm thinking of singing a long song.", "Morning running is amazing.", "The young king is bringing rings.", "We're going shopping this evening.", "The banking meeting is starting.", "Something strange is hanging on the ceiling."],
            "z": ["These boys always choose the easy days.", "His dogs love cheese and peas.", "Is it the zoo or the museum?", "She uses those noisy machines.", "The results always surprise his friends.", "Please close the doors and windows."],
            "ʃ": ["She should wash the dishes in the shower.", "The fresh fish shop is on Shore Street.", "Sure, I'll share the shopping list.", "The machine makes special sugar.", "The station has a short shuttle.", "She wishes she could finish the session."],
            "ʒ": ["Usually I measure the pleasure of leisure.", "The garage has a beige television.", "That decision was a casual illusion.", "We watched the vision on television.", "Treasure the usual pleasure of a massage.", "The collision was a visual surprise."],
            "ɝ": ["The early bird heard the first word.", "Her work at the church was perfect.", "Thirty nurses learned German.", "I prefer to research birds.", "The girl turned the dirty shirt.", "First, return the journal by Thursday."],
            "n": ["Nine new nurses need a nap at noon.", "Ann can run in the rain.", "None of the men knew the answer.", "Can you turn on the green fan?", "Dan can't find the brown pen.", "Ten men ran down the lane."],
        ]
        if let lines = bank[phoneme] { return lines }
        let words = weakWords.isEmpty ? [PhonemeCatalog.example(phoneme)].filter { !$0.isEmpty } : weakWords
        guard !words.isEmpty else { return ["Listen carefully and repeat this sentence slowly."] }
        return words.prefix(6).map { "Say the word \($0) clearly, then say \($0) again." }
    }
}

// MARK: - Views

struct SoundRoute: Hashable {
    let phoneme: String
}

/// Progress-tab card: the five weakest sounds with trend, plus a one-tap drill.
struct WeakSoundsCard: View {
    let samples: [PhonemeSample]
    @Binding var drillLesson: Lesson?
    @Environment(\.modelContext) private var context
    @ObservedObject private var settings = AppSettings.shared
    @State private var generating = false

    private var stats: [SoundStat] { Array(SoundStats.compute(samples).prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sounds to practise").font(.headline)
                Spacer()
                if !stats.isEmpty {
                    Text("\(samples.count) sounds scored").font(.caption).foregroundStyle(.secondary)
                }
            }
            if stats.isEmpty {
                Text(settings.azureConfigured
                     ? "Record a few lesson sentences. Every recording is scored sound by sound, and your weakest sounds appear here."
                     : "Add an Azure Speech key in Settings to score each sound. Your weakest sounds will then appear here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(stats) { stat in
                    NavigationLink(value: SoundRoute(phoneme: stat.phoneme)) {
                        SoundRow(stat: stat)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    Task {
                        generating = true
                        defer { generating = false }
                        let top = stats.prefix(3)
                        drillLesson = await DrillGenerator.makeLesson(
                            phonemes: top.map(\.phoneme),
                            weakWords: top.flatMap(\.weakWords),
                            context: context)
                    }
                } label: {
                    HStack {
                        Label("Drill my 3 weakest sounds", systemImage: "target")
                        if generating { Spacer(); ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(generating)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SoundRow: View {
    let stat: SoundStat

    var body: some View {
        HStack(spacing: 12) {
            Text("/\(PhonemeCatalog.display(stat.phoneme))/")
                .font(.title3.weight(.semibold))
                .frame(width: 54, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(PhonemeCatalog.example(stat.phoneme)).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let trend = stat.trend, abs(trend) >= 1 {
                        Label("\(trend > 0 ? "+" : "")\(Int(trend.rounded()))", systemImage: trend > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(trend > 0 ? .green : .red)
                    }
                    Text("\(Int(stat.average.rounded()))").font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(soundColor(stat.average))
                }
                ProgressView(value: stat.average, total: 100).tint(soundColor(stat.average))
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

func soundColor(_ v: Double) -> Color { v >= 80 ? .green : (v >= 60 ? .orange : .red) }

/// One sound: score history, the words where it went wrong, how to make it, and a drill.
struct SoundDetailView: View {
    let phoneme: String
    let samples: [PhonemeSample]
    @Environment(\.modelContext) private var context
    @StateObject private var voice = SpeechVoice()
    @State private var generating = false
    @State private var drillLesson: Lesson?

    private var stat: SoundStat? { SoundStats.compute(samples, minCount: 1).first { $0.phoneme == phoneme } }
    private var history: [(day: Date, average: Double)] { SoundStats.daily(samples, phoneme: phoneme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("/\(PhonemeCatalog.display(phoneme))/").font(.system(size: 48, weight: .bold, design: .rounded))
                    Text("as in “\(PhonemeCatalog.example(phoneme))”").font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    Button { voice.speak(PhonemeCatalog.example(phoneme), rate: 0.8) } label: { Image(systemName: "speaker.wave.2.fill") }
                        .buttonStyle(.bordered)
                }
                if let stat {
                    HStack(spacing: 12) {
                        metric("\(Int(stat.average.rounded()))", "average", soundColor(stat.average))
                        metric("\(stat.count)", "times scored", .blue)
                        if let trend = stat.trend {
                            metric("\(trend >= 0 ? "+" : "")\(Int(trend.rounded()))", "this week", trend >= 0 ? .green : .red)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("How to make it", systemImage: "mouth").font(.headline)
                    Text(PhonemeCatalog.tip(phoneme))
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                if history.count >= 2 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Daily average").font(.headline)
                        Chart(history, id: \.day) { point in
                            LineMark(x: .value("Day", point.day, unit: .day), y: .value("Score", point.average))
                            PointMark(x: .value("Day", point.day, unit: .day), y: .value("Score", point.average))
                        }
                        .chartYScale(domain: 0...100)
                        .frame(height: 150)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }

                if let words = stat?.weakWords, !words.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Words where it went wrong").font(.headline)
                        FlowLayout(spacing: 8) {
                            ForEach(words, id: \.self) { w in
                                Button { voice.speak(w, rate: 0.85) } label: {
                                    Label(w, systemImage: "speaker.wave.1").font(.subheadline)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Button {
                    Task {
                        generating = true
                        defer { generating = false }
                        drillLesson = await DrillGenerator.makeLesson(phonemes: [phoneme], weakWords: stat?.weakWords ?? [], context: context)
                    }
                } label: {
                    HStack {
                        Label("Start a drill for this sound", systemImage: "target")
                        if generating { Spacer(); ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(generating)
                Text(AppSettings.shared.chatConfigured
                     ? "Drill sentences are written fresh by your conversation partner model."
                     : "Drill sentences come from the built-in bank. Set up a conversation model in Settings for fresh ones each time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sound /\(PhonemeCatalog.display(phoneme))/")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $drillLesson) { PracticeView(lesson: $0) }
    }

    private func metric(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
