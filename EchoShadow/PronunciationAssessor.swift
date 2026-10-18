import AVFoundation
import Foundation

struct PhonemeAssessment: Identifiable {
    let id = UUID()
    let phoneme: String
    let accuracy: Double
}

struct WordAssessment: Identifiable {
    let id = UUID()
    let word: String
    let accuracy: Double
    let errorType: String          // None, Omission, Insertion, Mispronunciation
    let phonemes: [PhonemeAssessment]

    var isOmitted: Bool { errorType == "Omission" }
    var isInserted: Bool { errorType == "Insertion" }
}

struct PronunciationResult {
    let pronScore: Double
    let accuracy: Double
    let fluency: Double
    let completeness: Double
    let prosody: Double?
    let recognized: String
    let words: [WordAssessment]

    /// Words in reference order, with inserted (extra) words removed.
    var referenceWords: [WordAssessment] { words.filter { !$0.isInserted } }
}

enum AssessmentError: LocalizedError {
    case notConfigured
    case tooLong
    case conversion
    case http(Int, String)
    case noSpeech(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add an Azure Speech key and region in Settings to score pronunciation."
        case .tooLong: return "Pronunciation scoring works on recordings up to 30 seconds."
        case .conversion: return "Could not convert the recording for scoring."
        case .http(let code, let body): return "Azure Speech returned HTTP \(code). \(body.prefix(160))"
        case .noSpeech(let status): return "Azure heard no speech (\(status)). Try recording again closer to the microphone."
        }
    }
}

/// Sound-by-sound scoring through Azure Speech's pronunciation assessment (REST, short audio).
struct PronunciationAssessor {
    let key: String
    let regionOrHost: String

    private var endpoint: URL? {
        let trimmed = regionOrHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let base: String
        if trimmed.contains(".") {
            // Full endpoint host such as myresource.cognitiveservices.azure.com
            let host = trimmed.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            base = "https://\(host)/stt/speech/recognition/conversation/cognitiveservices/v1"
        } else {
            base = "https://\(trimmed).stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1"
        }
        return URL(string: base + "?language=en-US&format=detailed")
    }

    func assess(audioFile: URL, referenceText: String) async throws -> PronunciationResult {
        guard !key.isEmpty, let url = endpoint else { throw AssessmentError.notConfigured }
        let wav = try Self.convertToWav16k(audioFile)
        let seconds = Double(wav.count - 44) / 32000.0
        guard seconds <= 30 else { throw AssessmentError.tooLong }

        let params: [String: Any] = [
            "ReferenceText": referenceText,
            "GradingSystem": "HundredMark",
            "Granularity": "Phoneme",
            "Dimension": "Comprehensive",
            "EnableMiscue": "True",
            "EnableProsodyAssessment": "True",
            "PhonemeAlphabet": "IPA"
        ]
        let paramsBase64 = try JSONSerialization.data(withJSONObject: params).base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue(paramsBase64, forHTTPHeaderField: "Pronunciation-Assessment")
        request.setValue("audio/wav; codecs=audio/pcm; samplerate=16000", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = wav

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AssessmentError.http(status, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AssessmentError.http(status, "unreadable body") }
        let recStatus = "\(json["RecognitionStatus"] ?? "")"
        guard recStatus == "Success" || recStatus == "0", let best = (json["NBest"] as? [[String: Any]])?.first else {
            throw AssessmentError.noSpeech(recStatus)
        }
        return Self.parse(best)
    }

    // Scores appear either flat on the object (newer responses) or nested under "PronunciationAssessment".
    private static func score(_ obj: [String: Any], _ name: String) -> Double? {
        if let v = obj[name] as? Double { return v }
        if let v = obj[name] as? Int { return Double(v) }
        if let nested = obj["PronunciationAssessment"] as? [String: Any] {
            if let v = nested[name] as? Double { return v }
            if let v = nested[name] as? Int { return Double(v) }
        }
        return nil
    }

    private static func string(_ obj: [String: Any], _ name: String) -> String? {
        (obj[name] as? String) ?? ((obj["PronunciationAssessment"] as? [String: Any])?[name] as? String)
    }

    private static func parse(_ best: [String: Any]) -> PronunciationResult {
        let words: [WordAssessment] = ((best["Words"] as? [[String: Any]]) ?? []).map { w in
            let phonemes: [PhonemeAssessment] = ((w["Phonemes"] as? [[String: Any]]) ?? []).map { p in
                PhonemeAssessment(phoneme: p["Phoneme"] as? String ?? "?", accuracy: score(p, "AccuracyScore") ?? 0)
            }
            return WordAssessment(word: w["Word"] as? String ?? "",
                                  accuracy: score(w, "AccuracyScore") ?? 0,
                                  errorType: string(w, "ErrorType") ?? "None",
                                  phonemes: phonemes)
        }
        return PronunciationResult(
            pronScore: score(best, "PronScore") ?? 0,
            accuracy: score(best, "AccuracyScore") ?? 0,
            fluency: score(best, "FluencyScore") ?? 0,
            completeness: score(best, "CompletenessScore") ?? 0,
            prosody: score(best, "ProsodyScore"),
            recognized: best["Display"] as? String ?? "",
            words: words
        )
    }

    /// Converts any Core Audio file to 16 kHz mono 16-bit PCM WAV bytes.
    static func convertToWav16k(_ source: URL) throws -> Data {
        let input = try AVAudioFile(forReading: source)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: outFormat) else {
            throw AssessmentError.conversion
        }
        let inFrames = AVAudioFrameCount(input.length)
        guard inFrames > 0, let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: inFrames) else {
            throw AssessmentError.conversion
        }
        try input.read(into: inBuffer)

        let ratio = outFormat.sampleRate / input.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inFrames) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { throw AssessmentError.conversion }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, convError == nil, let channel = outBuffer.int16ChannelData else { throw AssessmentError.conversion }

        let frames = Int(outBuffer.frameLength)
        let pcm = Data(bytes: channel[0], count: frames * 2)
        return wavHeader(pcmByteCount: pcm.count, sampleRate: 16000) + pcm
    }

    private static func wavHeader(pcmByteCount: Int, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcmByteCount))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcmByteCount))
        return d
    }
}
