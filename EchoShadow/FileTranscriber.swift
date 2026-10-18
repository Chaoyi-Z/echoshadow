import AVFoundation
import Speech

enum TranscriberError: LocalizedError {
    case notAuthorized
    case unavailable
    case exportFailed
    case noAudio

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition permission was not granted. Enable it in Settings ▸ Echo Shadow."
        case .unavailable: return "Speech recognition is not available right now."
        case .exportFailed: return "Could not read audio from this file."
        case .noAudio: return "No speech was found in this file."
        }
    }
}

/// Transcribes an audio or video file with Apple's speech recognizer, on-device when supported,
/// in ~50 s chunks so long files work. Produces word-level cues with timestamps.
struct FileTranscriber {
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> [Cue] {
        guard await Self.requestAuthorization() else { throw TranscriberError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw TranscriberError.unavailable
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0.5 else { throw TranscriberError.exportFailed }

        let chunk = 50.0
        var cues: [Cue] = []
        var start = 0.0
        var onDevice = recognizer.supportsOnDeviceRecognition
        while start < duration {
            let length = min(chunk, duration - start)
            if length < 0.5 { break }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            try await export(asset: asset, from: start, length: length, to: tmp)
            let segments: [SFTranscriptionSegment]
            do {
                segments = try await recognize(url: tmp, recognizer: recognizer, onDevice: onDevice)
            } catch where onDevice {
                // The on-device model can be missing or still downloading; Apple's server recognizer still works.
                onDevice = false
                segments = try await recognize(url: tmp, recognizer: recognizer, onDevice: false)
            }
            try? FileManager.default.removeItem(at: tmp)
            for s in segments {
                let text = s.substring.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                cues.append(Cue(start: start + s.timestamp, end: start + s.timestamp + s.duration, text: text))
            }
            start += length
            await progress(min(1, start / duration))
        }
        guard !cues.isEmpty else { throw TranscriberError.noAudio }
        return cues
    }

    private func export(asset: AVAsset, from: Double, length: Double, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriberError.exportFailed
        }
        session.outputURL = url
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: from, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )
        await session.export()
        guard session.status == .completed else { throw session.error ?? TranscriberError.exportFailed }
    }

    private func recognize(url: URL, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> [SFTranscriptionSegment] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = onDevice
        final class Flag { var finished = false }
        let flag = Flag()
        return try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                guard !flag.finished else { return }
                if let result, result.isFinal {
                    flag.finished = true
                    cont.resume(returning: result.bestTranscription.segments)
                } else if let error {
                    flag.finished = true
                    let ns = error as NSError
                    // "No speech detected" in this chunk: treat as silence rather than failure.
                    if ns.domain == "kAFAssistantErrorDomain" && [1110, 1101, 203].contains(ns.code) {
                        cont.resume(returning: [])
                    } else {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }
}
