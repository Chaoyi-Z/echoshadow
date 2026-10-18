import AVFoundation
import Foundation
import Security
import SwiftUI

/// Which engine reads sentences and replies aloud.
enum VoiceEngine: String, CaseIterable, Identifiable, Codable {
    case apple, azure
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: return "Apple (on device)"
        case .azure: return "Azure neural (natural)"
        }
    }
}

/// Which model powers conversation practice.
enum ChatProviderKind: String, CaseIterable, Identifiable, Codable {
    case apple, claude, openAI, gemini
    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: return "On-device (Apple)"
        case .claude: return "Claude"
        case .openAI: return "OpenAI / compatible"
        case .gemini: return "Google Gemini"
        }
    }

    var detail: String {
        switch self {
        case .apple: return "Free, offline, private. Needs Apple Intelligence (iPhone 15 Pro or newer, iOS 26+). Simpler conversations."
        case .claude: return "Best quality. Needs an Anthropic API key, or a gateway key such as MIT Parley with its base URL."
        case .openAI: return "Works with an OpenAI key or any OpenAI-compatible gateway, such as MIT Parley."
        case .gemini: return "Needs a Google AI Studio key."
        }
    }
}

/// Small Keychain wrapper so API keys never sit in UserDefaults.
enum Keychain {
    private static let service = "com.chaoyi.echoshadow"

    static func get(_ key: String) -> String? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) {
        delete(key)
        guard !value.isEmpty else { return }
        var query = base(key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}

/// App-wide configuration. Secrets live in the Keychain, everything else in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var chatProvider: ChatProviderKind { didSet { defaults.set(chatProvider.rawValue, forKey: "chatProvider") } }

    @Published var claudeKey: String { didSet { Keychain.set(claudeKey, for: "claudeKey") } }
    @Published var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "claudeModel") } }
    @Published var claudeBaseURL: String { didSet { defaults.set(claudeBaseURL, forKey: "claudeBaseURL") } }

    @Published var openAIKey: String { didSet { Keychain.set(openAIKey, for: "openAIKey") } }
    @Published var openAIBaseURL: String { didSet { defaults.set(openAIBaseURL, forKey: "openAIBaseURL") } }
    @Published var openAIModel: String { didSet { defaults.set(openAIModel, forKey: "openAIModel") } }

    @Published var geminiKey: String { didSet { Keychain.set(geminiKey, for: "geminiKey") } }
    @Published var geminiModel: String { didSet { defaults.set(geminiModel, forKey: "geminiModel") } }

    /// Models the current gateway reported (from a model-list fetch or an error reply). Not persisted.
    @Published var serverModels: [String] = []

    @Published var azureKey: String { didSet { Keychain.set(azureKey, for: "azureKey") } }
    @Published var azureRegion: String { didSet { defaults.set(azureRegion, forKey: "azureRegion") } }

    /// Talk: seconds of silence that end a spoken turn; 0 means only the Stop button ends it.
    @Published var turnPause: Double { didSet { defaults.set(turnPause, forKey: "turnPause") } }

    @Published var voiceEngine: VoiceEngine { didSet { defaults.set(voiceEngine.rawValue, forKey: "voiceEngine") } }
    /// Empty means "best installed English voice".
    @Published var appleVoiceID: String { didSet { defaults.set(appleVoiceID, forKey: "appleVoiceID") } }
    @Published var azureVoice: String { didSet { defaults.set(azureVoice, forKey: "azureVoice") } }

    private let defaults = UserDefaults.standard

    private init() {
        chatProvider = ChatProviderKind(rawValue: defaults.string(forKey: "chatProvider") ?? "") ?? .apple
        claudeKey = Keychain.get("claudeKey") ?? ""
        claudeModel = defaults.string(forKey: "claudeModel") ?? "claude-opus-5-5"
        claudeBaseURL = defaults.string(forKey: "claudeBaseURL") ?? "https://api.anthropic.com"
        openAIKey = Keychain.get("openAIKey") ?? ""
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-4o"
        geminiKey = Keychain.get("geminiKey") ?? ""
        geminiModel = defaults.string(forKey: "geminiModel") ?? "gemini-2.5-flash"
        azureKey = Keychain.get("azureKey") ?? ""
        azureRegion = defaults.string(forKey: "azureRegion") ?? ""
        // v2: pauses are measured from the voice level, and the default became 5 s.
        if defaults.object(forKey: "turnPauseV2") == nil {
            defaults.set(5.0, forKey: "turnPause")
            defaults.set(true, forKey: "turnPauseV2")
        }
        turnPause = defaults.object(forKey: "turnPause") as? Double ?? 5
        voiceEngine = VoiceEngine(rawValue: defaults.string(forKey: "voiceEngine") ?? "") ?? .azure
        appleVoiceID = defaults.string(forKey: "appleVoiceID") ?? ""
        azureVoice = defaults.string(forKey: "azureVoice") ?? "en-US-AvaMultilingualNeural"
    }

    var azureConfigured: Bool { !azureKey.isEmpty && !azureRegion.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Whether the chosen chat provider has what it needs to run.
    var chatConfigured: Bool {
        switch chatProvider {
        case .apple: return AppleOnDeviceChat.isAvailable
        case .claude: return !claudeKey.isEmpty
        case .openAI: return !openAIKey.isEmpty && !openAIBaseURL.isEmpty
        case .gemini: return !geminiKey.isEmpty
        }
    }
}

/// MIT's LLM gateway. It speaks the OpenAI format at /v1/chat/completions and the Anthropic format at /v1/messages.
enum ParleyGateway {
    static let openAIBase = "https://parley.api.mit.edu/v1"
    static let anthropicBase = "https://parley.api.mit.edu"
}

/// Asks an OpenAI-compatible server which models the key can use (GET {base}/models).
enum ModelLister {
    static func list(baseURL: String, apiKey: String) async throws -> [String] {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let root = base.hasSuffix("/v1") ? base : base + "/v1"
        guard let url = URL(string: root + "/models") else { throw ChatError.notConfigured("The base URL is not valid.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ChatError.http(status, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { throw ChatError.badResponse }
        return items.compactMap { $0["id"] as? String }.sorted()
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelError: String?
    @StateObject private var previewVoice = SpeechVoice()
    @State private var appleVoices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Model", selection: $settings.chatProvider) {
                        ForEach(ChatProviderKind.allCases) { Text($0.label).tag($0) }
                    }
                    Text(settings.chatProvider.detail).font(.footnote).foregroundStyle(.secondary)
                    if settings.chatProvider == .apple {
                        Label(AppleOnDeviceChat.availabilityDescription,
                              systemImage: AppleOnDeviceChat.isAvailable ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(AppleOnDeviceChat.isAvailable ? .green : .orange)
                    }
                } header: {
                    Text("Conversation partner")
                }

                switch settings.chatProvider {
                case .apple:
                    EmptyView()
                case .claude:
                    Section {
                        SecureField("API key (sk-ant-… or sk-parley-…)", text: $settings.claudeKey)
                        TextField("Base URL", text: $settings.claudeBaseURL).keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                        TextField("Model", text: $settings.claudeModel).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Use MIT Parley gateway") {
                            settings.claudeBaseURL = ParleyGateway.anthropicBase
                            Task { await loadModels(baseURL: ParleyGateway.openAIBase, key: settings.claudeKey, filter: { $0.lowercased().contains("claude") }, autoPick: { settings.claudeModel = $0 }) }
                        }
                        modelPicker(baseURL: settings.claudeBaseURL, key: settings.claudeKey, filter: { $0.lowercased().contains("claude") }) { settings.claudeModel = $0 }
                    } header: {
                        Text("Claude")
                    } footer: {
                        Text("Direct Anthropic access uses api.anthropic.com. With an MIT Parley key, tap “Use MIT Parley gateway”, then load the model list and pick a Claude model.")
                    }
                case .openAI:
                    Section {
                        SecureField("API key", text: $settings.openAIKey)
                        TextField("Base URL", text: $settings.openAIBaseURL).keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                        TextField("Model", text: $settings.openAIModel).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Use MIT Parley gateway") {
                            settings.openAIBaseURL = ParleyGateway.openAIBase
                            Task { await loadModels(baseURL: ParleyGateway.openAIBase, key: settings.openAIKey, filter: { _ in true }, autoPick: { settings.openAIModel = $0 }) }
                        }
                        modelPicker(baseURL: settings.openAIBaseURL, key: settings.openAIKey, filter: { _ in true }) { settings.openAIModel = $0 }
                    } header: {
                        Text("OpenAI-compatible")
                    } footer: {
                        Text("Paste the key, set the base URL (the part before /chat/completions), then load the model list and pick one. MIT Parley keys start with sk-parley-.")
                    }
                case .gemini:
                    Section("Google Gemini") {
                        SecureField("Google AI Studio key", text: $settings.geminiKey)
                        TextField("Model", text: $settings.geminiModel).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }

                Section {
                    Picker("Engine", selection: $settings.voiceEngine) {
                        ForEach(VoiceEngine.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.voiceEngine == .azure {
                        Picker("Voice", selection: $settings.azureVoice) {
                            ForEach(AzureTTS.curatedVoices, id: \.id) { v in Text(v.label).tag(v.id) }
                        }
                        if !settings.azureConfigured {
                            Label("Needs the Azure Speech key below. Until then the Apple voice is used.", systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    } else {
                        Picker("Voice", selection: $settings.appleVoiceID) {
                            Text("Best installed").tag("")
                            ForEach(appleVoices, id: \.identifier) { v in
                                Text("\(v.name) · \(SpeechVoice.qualityLabel(v)) · \(v.language)").tag(v.identifier)
                            }
                        }
                    }
                    Button {
                        previewVoice.speak("Hi there! This is how I'll sound when we practise together. Shall we get started?", rate: 1.0)
                    } label: {
                        Label(previewVoice.isSpeaking ? "Playing…" : "Preview voice", systemImage: "speaker.wave.2")
                    }
                    .disabled(previewVoice.isSpeaking)
                } header: {
                    Text("Voice")
                } footer: {
                    Text(settings.voiceEngine == .azure
                         ? "Azure neural voices sound like a real speaker and use the same Speech resource as pronunciation scoring (free tier: 500,000 characters a month). Audio is fetched once per sentence and cached."
                         : "For a much better Apple voice, download a Premium one in iOS Settings ▸ Accessibility ▸ Spoken Content ▸ Voices ▸ English (for example Ava, Zoe or Evan), then pick it here.")
                }

                Section {
                    SecureField("Speech resource key", text: $settings.azureKey)
                    TextField("Region (e.g. eastus) or endpoint host", text: $settings.azureRegion)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: {
                    Text("Pronunciation scoring (Azure Speech)")
                } footer: {
                    Text("Optional. With a key, each recording is also scored sound by sound: accuracy, fluency, completeness, and per-phoneme feedback. The free tier covers 5 hours of audio a month. Without a key, word-level scoring still works offline.")
                }

                Section {
                    Text("Keys are stored in the iOS Keychain on this device only.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                if models.isEmpty { models = settings.serverModels }
                appleVoices = SpeechVoice.englishVoices()
            }
            .onDisappear { previewVoice.stop() }
        }
    }

    /// Fetches the server's models; optionally switches to the best one when the current choice is not offered.
    private func loadModels(baseURL: String, key: String, filter: @escaping (String) -> Bool, autoPick: ((String) -> Void)? = nil) async {
        guard !key.isEmpty else { modelError = "Paste the API key first."; return }
        loadingModels = true
        modelError = nil
        defer { loadingModels = false }
        do {
            let all = try await ModelLister.list(baseURL: baseURL, apiKey: key)
            let filtered = all.filter(filter)
            models = filtered.isEmpty ? all : filtered
            settings.serverModels = all
            if models.isEmpty { modelError = "The server returned no models."; return }
            if let autoPick, let best = ServerModelHints.bestChatModel(from: models) { autoPick(best) }
        } catch {
            modelError = error.localizedDescription
        }
    }

    /// Button that fetches the server's model list, then a picker to choose one.
    @ViewBuilder
    private func modelPicker(baseURL: String, key: String, filter: @escaping (String) -> Bool, onPick: @escaping (String) -> Void) -> some View {
        Button {
            Task { await loadModels(baseURL: baseURL, key: key, filter: filter) }
        } label: {
            HStack {
                Label(models.isEmpty ? "Load model list from server" : "Reload model list", systemImage: "list.bullet.rectangle")
                if loadingModels { Spacer(); ProgressView() }
            }
        }
        .disabled(key.isEmpty || loadingModels)
        if let modelError {
            Text(modelError).font(.footnote).foregroundStyle(.red)
        }
        if !models.isEmpty {
            Menu {
                ForEach(models, id: \.self) { m in Button(m) { onPick(m) } }
            } label: {
                Label("Choose from \(models.count) models", systemImage: "chevron.up.chevron.down")
            }
        }
    }
}
