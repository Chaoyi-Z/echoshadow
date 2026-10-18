import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ChatTurn: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

enum ChatError: LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case badResponse
    case refused
    case contextFull

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return what
        case .http(let code, let body): return "The model service returned HTTP \(code). \(body.prefix(700))"
        case .badResponse: return "The model service returned something unexpected."
        case .refused: return "The model declined to answer that. Try rephrasing."
        case .contextFull: return "The on-device model's memory for this conversation is full. End the conversation to get feedback, then start a new one."
        }
    }
}

/// A conversation partner. Each provider keeps its own transcript so the UI only sends new turns.
@MainActor
protocol ChatProvider: AnyObject {
    /// Network timeout for one request, in seconds.
    var timeout: TimeInterval { get set }
    func reset(instructions: String)
    func send(_ userText: String) async throws -> String
}

@MainActor
enum ChatProviderFactory {
    static func make(from settings: AppSettings) throws -> any ChatProvider {
        switch settings.chatProvider {
        case .apple:
            guard AppleOnDeviceChat.isAvailable else { throw ChatError.notConfigured(AppleOnDeviceChat.availabilityDescription + " Choose another model in Settings.") }
            return AppleOnDeviceChat()
        case .claude:
            guard !settings.claudeKey.isEmpty else { throw ChatError.notConfigured("Add your Anthropic API key in Settings.") }
            return ClaudeChat(apiKey: settings.claudeKey, model: settings.claudeModel, baseURL: settings.claudeBaseURL)
        case .openAI:
            guard !settings.openAIKey.isEmpty else { throw ChatError.notConfigured("Add your OpenAI-compatible API key in Settings.") }
            return OpenAIChat(apiKey: settings.openAIKey, baseURL: settings.openAIBaseURL, model: settings.openAIModel)
        case .gemini:
            guard !settings.geminiKey.isEmpty else { throw ChatError.notConfigured("Add your Google AI Studio key in Settings.") }
            return GeminiChat(apiKey: settings.geminiKey, model: settings.geminiModel)
        }
    }
}

// MARK: - Apple on-device (Foundation Models, iOS 26+)

@MainActor
final class AppleOnDeviceChat: ChatProvider {
    var timeout: TimeInterval = 90
    private var session: Any?
    private var instructions = ""

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var availabilityDescription: String {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "On-device model ready."
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This device does not support Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings ▸ Apple Intelligence & Siri."
                case .modelNotReady: return "The on-device model is still downloading. Try again in a few minutes."
                @unknown default: return "The on-device model is unavailable."
                }
            }
        }
        #endif
        return "Needs iOS 26 or later."
    }

    func reset(instructions: String) {
        self.instructions = instructions
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            session = LanguageModelSession(instructions: instructions)
        }
        #endif
    }

    func send(_ userText: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if session == nil { reset(instructions: instructions) }
            guard let session = session as? LanguageModelSession else { throw ChatError.notConfigured(Self.availabilityDescription) }
            do {
                return try await session.respond(to: userText).content
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error { throw ChatError.contextFull }
                if case .guardrailViolation = error { throw ChatError.refused }
                throw error
            }
        }
        #endif
        throw ChatError.notConfigured(Self.availabilityDescription)
    }
}

// MARK: - Shared HTTP helper

private func postJSON(_ url: URL, headers: [String: String], body: [String: Any], timeout: TimeInterval = 90) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw ChatError.http(status, errorMessage(from: data))
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatError.badResponse }
    return json
}

/// Pulls the human-readable message out of an API error body when there is one.
private func errorMessage(from data: Data) -> String {
    let raw = String(data: data, encoding: .utf8) ?? ""
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return raw }
    if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
    if let err = json["error"] as? String { return err }
    if let msg = json["message"] as? String { return msg }
    return raw
}

/// Gateways such as MIT Parley reject unknown models with "Available models: a, b, c". Parse that list.
enum ServerModelHints {
    static let preferred = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8",
                            "claude-sonnet-4-6", "gpt-5", "gpt-5-mini", "gpt-4.1", "gpt-4o", "gemini-2.5-pro", "gemini-2.5-flash",
                            "claude-haiku-5-5", "claude-haiku-4-5"]

    static func models(inErrorMessage message: String) -> [String] {
        guard let r = message.range(of: "Available models:") else { return [] }
        let tail = message[r.upperBound...]
        return tail.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'")) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
    }

    /// Best chat model from a server list: preferred names first, otherwise the first non-embedding entry.
    static func bestChatModel(from models: [String]) -> String? {
        for p in preferred where models.contains(p) { return p }
        return models.first { !$0.contains("embed") && !$0.contains("rerank") && !$0.contains("whisper") }
    }
}

// MARK: - Claude (Messages API over raw HTTP; Swift has no official SDK)

@MainActor
final class ClaudeChat: ChatProvider {
    var timeout: TimeInterval = 90
    private let apiKey: String
    private let model: String
    private let baseURL: String
    private var system = ""
    private var history: [[String: Any]] = []

    /// Server-side refusal fallback is an Anthropic API feature; gateways may reject the unknown field.
    private var isOfficialAPI: Bool { baseURL.contains("api.anthropic.com") }

    init(apiKey: String, model: String, baseURL: String = "https://api.anthropic.com") {
        self.apiKey = apiKey
        self.model = model.isEmpty ? "claude-opus-5-5" : model
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    func reset(instructions: String) {
        system = instructions
        history = []
    }

    func send(_ userText: String) async throws -> String {
        history.append(["role": "user", "content": userText])
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "messages": history
        ]
        var headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01", "Authorization": "Bearer \(apiKey)"]
        if isOfficialAPI {
            // Re-run on Anthropic's recommended fallback model if a safety classifier declines.
            body["fallbacks"] = "default"
            body["output_config"] = ["effort": "low"]
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }
        let path = baseURL.hasSuffix("/v1") ? baseURL + "/messages" : baseURL + "/v1/messages"
        guard let url = URL(string: path) else { history.removeLast(); throw ChatError.notConfigured("The Claude base URL is not valid.") }
        let json: [String: Any]
        do {
            json = try await postJSON(url, headers: headers, body: body, timeout: timeout)
        } catch {
            history.removeLast()   // keep user/assistant turns alternating for the next request
            throw error
        }
        if (json["stop_reason"] as? String) == "refusal" {
            history.removeLast()
            throw ChatError.refused
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { history.removeLast(); throw ChatError.badResponse }
        history.append(["role": "assistant", "content": text])
        return text
    }
}

// MARK: - OpenAI-compatible chat completions

@MainActor
final class OpenAIChat: ChatProvider {
    var timeout: TimeInterval = 90
    private let apiKey: String
    private let baseURL: String
    private let model: String
    private var messages: [[String: String]] = []

    init(apiKey: String, baseURL: String, model: String) {
        self.apiKey = apiKey
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.model = model
    }

    func reset(instructions: String) {
        messages = [["role": "system", "content": instructions]]
    }

    func send(_ userText: String) async throws -> String {
        messages.append(["role": "user", "content": userText])
        let path = baseURL.hasSuffix("/chat/completions") ? baseURL : baseURL + "/chat/completions"
        guard let url = URL(string: path) else { messages.removeLast(); throw ChatError.notConfigured("The OpenAI base URL is not valid.") }
        let json: [String: Any]
        do {
            json = try await postJSON(url,
                                      headers: ["Authorization": "Bearer \(apiKey)"],
                                      body: ["model": model, "messages": messages],
                                      timeout: timeout)
        } catch {
            messages.removeLast()
            throw error
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty else {
            messages.removeLast()
            throw ChatError.badResponse
        }
        messages.append(["role": "assistant", "content": text])
        return text
    }
}

// MARK: - Google Gemini

@MainActor
final class GeminiChat: ChatProvider {
    var timeout: TimeInterval = 90
    private let apiKey: String
    private let model: String
    private var system = ""
    private var contents: [[String: Any]] = []

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? "gemini-2.5-flash" : model
    }

    func reset(instructions: String) {
        system = instructions
        contents = []
    }

    func send(_ userText: String) async throws -> String {
        contents.append(["role": "user", "parts": [["text": userText]]])
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        let json: [String: Any]
        do {
            json = try await postJSON(url,
                                      headers: ["x-goog-api-key": apiKey],
                                      body: ["system_instruction": ["parts": [["text": system]]],
                                             "contents": contents],
                                      timeout: timeout)
        } catch {
            contents.removeLast()
            throw error
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            contents.removeLast()
            throw ChatError.badResponse
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { contents.removeLast(); throw ChatError.badResponse }
        contents.append(["role": "model", "parts": [["text": text]]])
        return text
    }
}
