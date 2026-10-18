import Combine
import SwiftUI

struct Scenario: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let role: String

    static let all: [Scenario] = [
        Scenario(id: "smalltalk", title: "Small talk with a colleague", symbol: "cup.and.saucer",
                 role: "a friendly colleague chatting in the office kitchen before a meeting"),
        Scenario(id: "labmeeting", title: "Lab meeting questions", symbol: "testtube.2",
                 role: "a curious senior scientist asking the learner about their research project after a lab meeting; keep questions concrete and ask follow-ups about methods and results"),
        Scenario(id: "interview", title: "Job interview", symbol: "briefcase",
                 role: "a hiring manager interviewing the learner for a research position; ask one interview question at a time"),
        Scenario(id: "coffee", title: "Ordering at a café", symbol: "takeoutbag.and.cup.and.straw",
                 role: "a barista at a busy café taking the learner's order and making small talk"),
        Scenario(id: "doctor", title: "Doctor's appointment", symbol: "stethoscope",
                 role: "a doctor at a clinic asking the learner about their symptoms"),
        Scenario(id: "travel", title: "Airport check-in", symbol: "airplane",
                 role: "an airline check-in agent helping the learner with their flight"),
        Scenario(id: "free", title: "Free conversation", symbol: "bubble.left.and.bubble.right",
                 role: "an easygoing conversation partner who follows whatever topic the learner brings up"),
    ]

    var instructions: String {
        """
        You are \(role). You are also a warm, patient English conversation partner for an adult learner at an intermediate level.
        Stay in the scenario. Speak like a real native speaker: natural phrasing, contractions, one to three short sentences per turn, \
        and always end with a question or an invitation so the learner keeps talking. Do not correct the learner's grammar or \
        pronunciation during the conversation unless they ask; they will ask for feedback at the end. Plain text only, no lists or markdown.
        """
    }

    static let opening = "Start the conversation now with a short, natural greeting that fits the scenario, then ask the learner one question."
    static let feedbackPrompt = """
        Above is a practice conversation. Review ONLY the lines that start with "Learner:" (speech recognition may have \
        misheard a few words; ignore obvious recognition errors). Give (1) the three most useful corrections to the learner's own \
        sentences, each quoting what they said and then the natural way to say it, and (2) two phrases a native speaker would \
        typically use in this situation. Under 150 words. Plain text only: no asterisks, no bullet symbols, no headings.
        """
}

@MainActor
final class ConversationViewModel: ObservableObject {
    enum State: Equatable { case idle, recording, thinking, finished }

    @Published private(set) var scenario: Scenario?
    @Published private(set) var turns: [ChatTurn] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var liveText = ""
    @Published private(set) var feedback: String?
    @Published var errorMessage: String?
    @Published var speakReplies = true
    /// Hands-free: the mic opens by itself as soon as the partner finishes speaking.
    @Published var handsFree: Bool = UserDefaults.standard.object(forKey: "handsFree") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(handsFree, forKey: "handsFree")
            if handsFree, state == .idle, isActive, feedback == nil, !voice.isSpeaking { listenAfterPartner() }
            if !handsFree { listenTask?.cancel() }
        }
    }
    /// True while the mic was opened automatically and nothing has been heard yet.
    @Published private(set) var waitingForSpeech = false

    let voice = SpeechVoice()
    private let recorder = SpeechRecorder()
    private var provider: (any ChatProvider)?
    private var silenceTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var noSpeechTask: Task<Void, Never>?
    /// Longest single spoken turn.
    static let maxTurn: TimeInterval = 5 * 60
    @Published private(set) var turnElapsed: TimeInterval = 0
    private var turnClock: Task<Void, Never>?
    /// True while a turn is being stopped and sent; late recognizer updates must not restart the pause timer.
    private var finishing = false
    static let pauseChoices: [(seconds: Double, label: String)] = [(3, "3 s pause"), (5, "5 s pause"), (8, "8 s pause"), (0, "Stop button only")]
    /// Seconds left before a paused turn is sent, while a pause is under way.
    @Published private(set) var sendCountdown: Double?
    /// Hands-free listening gives up quietly after this long with no speech.
    static let noSpeechTimeout: Duration = .seconds(12)

    private var cancellables = Set<AnyCancellable>()

    var isActive: Bool { scenario != nil }

    init() {
        // Re-render when the partner starts or stops speaking.
        voice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    func start(_ scenario: Scenario) async {
        do {
            let p = try ChatProviderFactory.make(from: AppSettings.shared)
            p.reset(instructions: scenario.instructions)
            provider = p
            self.scenario = scenario
            turns = []
            feedback = nil
            state = .thinking
            let opening = Self.plain(try await p.send(Scenario.opening))
            turns.append(ChatTurn(role: .assistant, text: opening))
            state = .idle
            speak(opening)
            listenAfterPartner()
        } catch {
            errorMessage = Self.friendlyModelError(error) ?? error.localizedDescription
            self.scenario = nil
            state = .idle
        }
    }

    /// The mic button: stop and send while listening, otherwise interrupt the partner and start listening.
    func toggleMic() async {
        listenTask?.cancel()
        if state == .recording {
            await finishTurn(quietIfEmpty: false)
        } else {
            await startListening()
        }
    }

    private func startListening() async {
        guard state == .idle, isActive, feedback == nil else { return }
        voice.stop()
        do {
            try await recorder.start(continuous: true) { [weak self] partial in
                guard let self else { return }
                guard self.state == .recording, !self.finishing else { return }
                self.liveText = partial
                if !partial.isEmpty { self.waitingForSpeech = false; self.noSpeechTask?.cancel() }
            }
            liveText = ""
            state = .recording
            waitingForSpeech = true
            turnElapsed = 0
            sendCountdown = nil
            startPauseWatch()
            turnClock?.cancel()
            turnClock = Task { [weak self] in
                while let self, !Task.isCancelled, self.state == .recording {
                    self.turnElapsed = self.recorder.elapsed
                    if self.turnElapsed >= Self.maxTurn { self.finishTurnDetached(); return }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            noSpeechTask?.cancel()
            noSpeechTask = Task { [weak self] in
                try? await Task.sleep(for: Self.noSpeechTimeout)
                guard let self, !Task.isCancelled, self.state == .recording, self.liveText.isEmpty else { return }
                self.finishTurnDetached()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ends the turn in its own task, so cancelling the timer that triggered it can't cancel the send.
    private func finishTurnDetached() {
        Task { [weak self] in await self?.finishTurn(quietIfEmpty: true) }
    }

    private func finishTurn(quietIfEmpty: Bool) async {
        guard state == .recording, !finishing else { return }
        finishing = true
        defer { finishing = false }
        turnClock?.cancel()
        silenceTask?.cancel()
        sendCountdown = nil
        silenceTask = nil
        noSpeechTask?.cancel()
        waitingForSpeech = false
        let heardLive = liveText
        let text = await recorder.stop()
        // Prefer the recognizer's final text, but never lose what was shown live.
        let spoken = (text.isEmpty ? heardLive : text).trimmingCharacters(in: .whitespacesAndNewlines)
        liveText = ""
        state = .idle
        guard !spoken.isEmpty else {
            if quietIfEmpty { return }
            if let err = recorder.lastError {
                errorMessage = "Speech recognition stopped before it heard any words (\(err.localizedDescription)). Tap the mic and try again."
            } else {
                errorMessage = "I didn't catch anything. Speak a little longer, then pause or tap Stop."
            }
            return
        }
        if Self.isEndCommand(spoken) {
            await endAndGetFeedback()
            return
        }
        await send(spoken)
    }

    /// Lets the learner finish hands-free by voice.
    static func isEndCommand(_ text: String) -> Bool {
        let t = text.lowercased()
        let phrases = ["end the conversation", "end conversation", "stop the conversation", "finish the conversation",
                       "give me feedback", "give me some feedback", "feedback please", "that's all for today"]
        return phrases.contains { t.contains($0) } && t.split(separator: " ").count <= 10
    }

    /// Hands-free: wait for the partner's voice to finish, then open the mic.
    private func listenAfterPartner() {
        guard handsFree else { return }
        listenTask?.cancel()
        listenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            while let self, !Task.isCancelled, self.voice.isSpeaking {
                try? await Task.sleep(for: .milliseconds(120))
            }
            // A short gap so the tail of the reply isn't picked up by the microphone.
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, self.handsFree else { return }
            await self.startListening()
        }
    }

    /// Called when the Talk tab goes off screen: stop audio but keep the conversation.
    func suspend() {
        listenTask?.cancel()
        noSpeechTask?.cancel()
        silenceTask?.cancel()
        voice.stop()
        if state == .recording { recorder.cancel(); state = .idle; liveText = "" }
        waitingForSpeech = false
    }

    func resumeIfHandsFree() {
        if handsFree, isActive, feedback == nil, state == .idle { listenAfterPartner() }
    }

    /// Watches the microphone level; sends the turn once the learner has been quiet for the chosen time.
    private func startPauseWatch() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.state == .recording, !self.finishing {
                let pause = AppSettings.shared.turnPause
                if pause > 0, !self.liveText.isEmpty {
                    let quiet = self.recorder.secondsSinceVoice
                    if quiet >= pause {
                        self.sendCountdown = nil
                        self.finishTurnDetached()
                        return
                    }
                    // Show a countdown only once a real pause has started.
                    self.sendCountdown = quiet >= 1.2 ? pause - quiet : nil
                } else {
                    self.sendCountdown = nil
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func send(_ text: String) async {
        guard let provider, state == .idle || state == .finished else { return }
        turns.append(ChatTurn(role: .user, text: text))
        state = .thinking
        do {
            let reply = Self.plain(try await provider.send(text))
            turns.append(ChatTurn(role: .assistant, text: reply))
            state = .idle
            speak(reply)
            listenAfterPartner()
        } catch {
            errorMessage = error.localizedDescription
            state = .idle
        }
    }

    func endAndGetFeedback() async {
        guard isActive, state == .idle, turns.contains(where: { $0.role == .user }) else { return }
        listenTask?.cancel()
        voice.stop()
        state = .thinking
        do {
            feedback = Self.plain(try await requestFeedback())
            state = .finished
        } catch {
            let reason = Self.friendlyModelError(error) ?? error.localizedDescription
            errorMessage = "Couldn't get feedback: \(reason)\n\nYour conversation is kept. Tap “End conversation & get feedback” to try again."
            state = .idle
        }
    }

    /// Feedback is a fresh, compact request (the transcript as text) rather than one more turn of the chat:
    /// long chats can overflow the on-device model, and a fresh request isn't affected by earlier failed turns.
    private func requestFeedback() async throws -> String {
        let settings = AppSettings.shared
        let limit = settings.chatProvider == .apple ? 2400 : 14000
        var transcript = turns.map { ($0.role == .user ? "Learner: " : "Partner: ") + $0.text }.joined(separator: "\n")
        if transcript.count > limit { transcript = "…" + String(transcript.suffix(limit)) }
        let prompt = "Scenario: \(scenario?.title ?? "conversation").\n\nTranscript:\n\(transcript)\n\n" + Scenario.feedbackPrompt
        var attempt = 0
        while true {
            do {
                let p = try ChatProviderFactory.make(from: settings)
                p.timeout = 180
                p.reset(instructions: "You are a warm, precise English teacher for an adult learner. Plain text only, no markdown.")
                return try await p.send(prompt)
            } catch {
                attempt += 1
                guard attempt < 2, Self.isTransient(error) else { throw error }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let u = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .cancelled].contains(u.code)
        }
        if case ChatError.http(let code, _) = error { return code == 429 || code >= 500 }
        return false
    }

    func reset() {
        voice.stop()
        silenceTask?.cancel()
        listenTask?.cancel()
        noSpeechTask?.cancel()
        waitingForSpeech = false
        if state == .recording { recorder.cancel() }
        scenario = nil
        turns = []
        feedback = nil
        liveText = ""
        state = .idle
    }

    /// When a gateway rejects the model name and lists what it offers, switch to a valid model and explain.
    private static func friendlyModelError(_ error: Error) -> String? {
        guard case ChatError.http(_, let message) = error else { return nil }
        let offered = ServerModelHints.models(inErrorMessage: message)
        guard !offered.isEmpty else { return nil }
        let settings = AppSettings.shared
        settings.serverModels = offered
        let chat = offered.filter { !$0.contains("embed") }
        if let best = ServerModelHints.bestChatModel(from: offered) {
            switch settings.chatProvider {
            case .openAI: settings.openAIModel = best
            case .claude: settings.claudeModel = best
            default: break
            }
            return "That model is not offered by this gateway, so the partner was switched to \(best). Tap the scenario again. Other options in Settings: \(chat.prefix(8).joined(separator: ", "))."
        }
        return "That model is not offered by this gateway. Pick one in Settings: \(chat.prefix(8).joined(separator: ", "))."
    }

    /// Small models sometimes ignore "no markdown"; strip the common markers so the bubbles read cleanly.
    private static func plain(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: #"(?m)^\s*[-*•]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#+\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speak(_ text: String) {
        guard speakReplies else { return }
        try? AudioSession.configure()
        voice.speak(text, rate: 1.0)
    }
}

struct ConversationView: View {
    @StateObject private var vm = ConversationViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @State private var showSettings = false
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            Group {
                if vm.isActive { chat } else { picker }
            }
            .navigationTitle(vm.scenario?.title ?? "Talk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if vm.isActive {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Leave") { vm.reset() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Toggle(isOn: $vm.speakReplies) { Image(systemName: vm.speakReplies ? "speaker.wave.2" : "speaker.slash") }
                            .toggleStyle(.button)
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onDisappear { vm.suspend() }
            .onAppear { vm.resumeIfHandsFree() }
            .alert("Something went wrong", isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
                Button("Open Settings") { showSettings = true }
            } message: {
                Text(vm.errorMessage ?? "")
            }
        }
    }

    // MARK: Scenario picker

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                providerBanner
                Text("Pick a situation. Speak your turns; the partner replies out loud. Ask for feedback when you're done.")
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(Scenario.all) { scenario in
                        Button {
                            Task { await vm.start(scenario) }
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: scenario.symbol).font(.title2).foregroundStyle(Color.accentColor)
                                Text(scenario.title).font(.headline).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var providerBanner: some View {
        HStack {
            Image(systemName: settings.chatConfigured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(settings.chatConfigured ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Partner: \(settings.chatProvider.label)").font(.subheadline.weight(.semibold))
                if !settings.chatConfigured {
                    Text(settings.chatProvider == .apple ? AppleOnDeviceChat.availabilityDescription : "Needs an API key. Tap to set up.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Change") { showSettings = true }.font(.subheadline)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(vm.turns) { turn in bubble(turn) }
                        if vm.state == .thinking {
                            HStack { ProgressView(); Text("Thinking…").font(.caption).foregroundStyle(.secondary); Spacer() }
                                .padding(.horizontal)
                        }
                        if vm.state == .recording {
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true)
                                        .foregroundStyle(Color.accentColor)
                                    Text(vm.liveText.isEmpty ? "Listening…" : vm.liveText)
                                        .font(.subheadline).italic().foregroundStyle(.secondary)
                                }
                                Text(turnHint)
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal)
                        } else if vm.voice.isSpeaking && vm.state == .idle {
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill").symbolEffect(.variableColor.iterative, isActive: true)
                                Text(vm.handsFree ? "Partner is speaking. The mic opens when they finish; tap the mic to interrupt." : "Partner is speaking.")
                                    .font(.caption)
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        }
                        if let feedback = vm.feedback { feedbackCard(feedback) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical)
                }
                .onChange(of: vm.turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: vm.feedback) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            Divider()
            controls
        }
        .background(Color(.systemGroupedBackground))
    }

    private func bubble(_ turn: ChatTurn) -> some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 40) }
            Text(turn.text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(turn.role == .user ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(turn.role == .user ? Color.white : Color.primary)
                .onTapGesture { if turn.role == .assistant { vm.voice.speak(turn.text, rate: 1.0) } }
            if turn.role == .assistant { Spacer(minLength: 40) }
        }
        .padding(.horizontal)
    }

    private func feedbackCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Teacher's feedback", systemImage: "graduationcap").font(.headline)
            Text(text)
            Button {
                vm.reset()
            } label: {
                Label("New conversation", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if vm.state != .finished {
                HStack(spacing: 12) {
                    TextField("Or type your reply…", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendTyped() }
                    Button { sendTyped() } label: { Image(systemName: "paperplane.fill") }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || vm.state != .idle)
                }
                HStack {
                    Toggle(isOn: $vm.handsFree) {
                        Label("Hands-free", systemImage: "phone.bubble").font(.subheadline)
                    }
                    .fixedSize()
                    Spacer()
                    Menu {
                        Picker("Send my turn after", selection: $settings.turnPause) {
                            ForEach(ConversationViewModel.pauseChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
                        }
                    } label: {
                        Label("Send: \(ConversationViewModel.pauseChoices.first { $0.seconds == settings.turnPause }?.label ?? "custom")",
                              systemImage: "timer")
                            .font(.subheadline)
                    }
                }
                Button {
                    Task { await vm.toggleMic() }
                } label: {
                    Label(vm.state == .recording ? "Stop & send" : (vm.voice.isSpeaking ? "Interrupt & speak" : "Speak your turn"),
                          systemImage: vm.state == .recording ? "stop.fill" : "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.state == .recording ? .red : .accentColor)
                .disabled(vm.state == .thinking)
                Button("End conversation & get feedback") {
                    Task { await vm.endAndGetFeedback() }
                }
                .font(.subheadline)
                .disabled(vm.state != .idle || vm.turns.filter { $0.role == .user }.isEmpty)
                if vm.handsFree {
                    Text("Hands-free tip: say “give me feedback” to finish.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private var turnHint: String {
        let clock = "\(vm.turnElapsed.clockString) / 5:00"
        if vm.liveText.isEmpty { return "Your turn. Start speaking. \(clock)" }
        if let left = vm.sendCountdown { return "Sending in \(Int(left.rounded(.up)))… keep talking to continue. \(clock)" }
        return settings.turnPause > 0
            ? "Pause \(Int(settings.turnPause)) s to send, or tap Stop. \(clock)"
            : "Tap Stop & send when you're done. \(clock)"
    }

    private func sendTyped() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typed = ""
        Task { await vm.send(text) }
    }
}
