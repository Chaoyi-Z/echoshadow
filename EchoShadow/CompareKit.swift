import AVFoundation
import Charts
import SwiftUI

// MARK: - Loading audio

enum AudioLoadError: LocalizedError {
    case noAudioTrack
    case readFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "This file has no audio track."
        case .readFailed: return "Could not read the audio."
        }
    }
}

enum AudioLoader {
    /// Mono Float32 samples from any audio or video file, optionally a time range, resampled to `sampleRate`.
    static func monoSamples(url: URL, start: Double? = nil, end: Double? = nil, sampleRate: Double = 16000) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AudioLoadError.noAudioTrack }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioLoadError.readFailed }
        reader.add(output)
        if let start, let end, end > start {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                           end: CMTime(seconds: end, preferredTimescale: 600))
        }
        guard reader.startReading() else { throw reader.error ?? AudioLoadError.readFailed }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? AudioLoadError.readFailed }
        return samples
    }
}

/// Collects the Apple voice's audio into memory instead of playing it.
final class SampleBox: @unchecked Sendable {
    var samples: [Float] = []
    var sampleRate: Double = 0
    var finished = false
}

@MainActor
enum ReferenceAudio {
    private static let synthesizer = AVSpeechSynthesizer()

    /// The sentence as the app's voice says it, for intonation comparison in text lessons.
    static func render(text: String, rate: Float) async -> (samples: [Float], sampleRate: Double)? {
        let settings = AppSettings.shared
        if settings.voiceEngine == .azure, settings.azureConfigured,
           let data = try? await SpeechVoice.azureAudio(text, rate: rate) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("reference-\(UUID().uuidString).mp3")
            defer { try? FileManager.default.removeItem(at: url) }
            if (try? data.write(to: url)) != nil, let samples = try? await AudioLoader.monoSamples(url: url) {
                return (samples, 16000)
            }
        }
        return await renderApple(text: text, rate: rate, voiceID: settings.appleVoiceID)
    }

    private static func renderApple(text: String, rate: Float, voiceID: String) async -> (samples: [Float], sampleRate: Double)? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = (voiceID.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voiceID)) ?? SpeechVoice.bestAppleVoice()
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * rate)
        let box = SampleBox()
        return await withCheckedContinuation { cont in
            synthesizer.write(utterance) { buffer in
                guard !box.finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    box.finished = true
                    cont.resume(returning: box.samples.isEmpty ? nil : (box.samples, box.sampleRate))
                    return
                }
                box.sampleRate = pcm.format.sampleRate
                let n = Int(pcm.frameLength)
                if let ch = pcm.floatChannelData {
                    box.samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                } else if let ch = pcm.int16ChannelData {
                    box.samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n).map { Float($0) / 32768 })
                }
            }
        }
    }
}

// MARK: - Pitch tracking

struct PitchPoint: Identifiable {
    let id = UUID()
    let speaker: String
    let run: Int
    /// 0 = first voiced moment, 1 = last voiced moment.
    let t: Double
    /// Semitones above or below the speaker's own median pitch.
    let semitone: Double
}

struct PitchContour {
    let points: [PitchPoint]
    /// Spread between the 10th and 90th percentile, in semitones: how much the melody moves.
    let range: Double
    /// Pitch movement over the last fifth of the utterance: positive rises, negative falls.
    let endingSlope: Double

    var isEmpty: Bool { points.count < 5 }
}

enum PitchTracker {
    /// YIN-style fundamental frequency tracking at 8 kHz, normalised per speaker so voices of any pitch compare.
    static func contour(samples input: [Float], sampleRate: Double, speaker: String) -> PitchContour {
        let sr = 8000.0
        let x = resample(input, from: sampleRate, to: sr)
        let frame = 320, hop = 80
        let tauMin = Int(sr / 450), tauMax = Int(sr / 70)
        let window = frame - tauMax
        guard x.count > frame + hop else { return PitchContour(points: [], range: 0, endingSlope: 0) }

        var energies: [Float] = []
        var starts: [Int] = []
        var s = 0
        while s + frame <= x.count {
            var e: Float = 0
            for i in s..<(s + frame) { e += x[i] * x[i] }
            energies.append((e / Float(frame)).squareRoot())
            starts.append(s)
            s += hop
        }
        let loud = energies.max() ?? 0
        let gate = max(loud * 0.12, 0.003)

        var f0: [Double?] = Array(repeating: nil, count: starts.count)
        var d = [Float](repeating: 0, count: tauMax + 1)
        x.withUnsafeBufferPointer { buf in
            for (k, start) in starts.enumerated() where energies[k] >= gate {
                for tau in 1...tauMax {
                    var sum: Float = 0
                    for j in 0..<window {
                        let diff = buf[start + j] - buf[start + j + tau]
                        sum += diff * diff
                    }
                    d[tau] = sum
                }
                var running: Float = 0
                var best: Int?
                var cmnd = [Float](repeating: 1, count: tauMax + 1)
                for tau in 1...tauMax {
                    running += d[tau]
                    cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
                }
                var tau = tauMin
                while tau < tauMax {
                    if cmnd[tau] < 0.15 {
                        while tau + 1 < tauMax, cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                        best = tau
                        break
                    }
                    tau += 1
                }
                guard let t0 = best, t0 > 1, t0 < tauMax else { continue }
                let a = cmnd[t0 - 1], b = cmnd[t0], c = cmnd[t0 + 1]
                let denom = a - 2 * b + c
                let shift = denom != 0 ? Double((a - c) / (2 * denom)) : 0
                f0[k] = sr / (Double(t0) + max(-1, min(1, shift)))
            }
        }

        // Median-smooth, fold octave jumps, then express in semitones from the speaker's median.
        let voiced = f0.compactMap { $0 }.sorted()
        guard voiced.count >= 5 else { return PitchContour(points: [], range: 0, endingSlope: 0) }
        let median = voiced[voiced.count / 2]
        var cleaned: [Double?] = f0.map { v in
            guard var v else { return nil }
            if v > median * 1.8 { v /= 2 }
            if v < median * 0.55 { v *= 2 }
            return v
        }
        cleaned = cleaned.indices.map { i in
            guard cleaned[i] != nil else { return nil }
            let neighbours = (max(0, i - 2)...min(cleaned.count - 1, i + 2)).compactMap { cleaned[$0] }.sorted()
            return neighbours[neighbours.count / 2]
        }
        let first = cleaned.firstIndex { $0 != nil } ?? 0
        let last = cleaned.lastIndex { $0 != nil } ?? 0
        let span = Double(max(1, last - first))
        var points: [PitchPoint] = []
        var run = 0
        var gap = 0
        for i in first...last {
            guard let v = cleaned[i] else { gap += 1; continue }
            if gap > 4 { run += 1 }
            gap = 0
            let semis = 12 * log2(v / median)
            points.append(PitchPoint(speaker: speaker, run: run, t: Double(i - first) / span, semitone: max(-12, min(12, semis))))
        }
        let semis = points.map(\.semitone).sorted()
        let range = semis.isEmpty ? 0 : semis[Int(Double(semis.count - 1) * 0.9)] - semis[Int(Double(semis.count - 1) * 0.1)]
        let tail = points.filter { $0.t >= 0.8 }
        let endingSlope = (tail.last?.semitone ?? 0) - (tail.first?.semitone ?? 0)
        return PitchContour(points: points, range: range, endingSlope: tail.count >= 3 ? endingSlope : 0)
    }

    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, abs(from - to) > 1, !x.isEmpty else { return x }
        let ratio = from / to
        let n = Int(Double(x.count) / ratio)
        var out = [Float](repeating: 0, count: n)
        let step = Int(ratio.rounded(.down))
        for i in 0..<n {
            // Average the source samples this output sample covers (a cheap low-pass) before picking.
            let p = Double(i) * ratio
            let base = Int(p)
            var acc: Float = 0
            var count: Float = 0
            for j in base..<min(x.count, base + max(1, step)) { acc += x[j]; count += 1 }
            out[i] = count > 0 ? acc / count : 0
        }
        return out
    }
}

struct IntonationResult {
    let mine: PitchContour
    let original: PitchContour?
    let note: String?

    /// One-sentence coaching hint comparing the two melodies.
    var advice: String {
        if let note { return note }
        guard !mine.isEmpty else { return "Not enough voiced sound in your recording to draw a pitch curve. Try speaking a little louder." }
        guard let original, !original.isEmpty else {
            return mine.range < 3
                ? "Your pitch stays quite flat. Let your voice rise on stressed words and fall at the end of statements."
                : "Your melody moves about \(Int(mine.range.rounded())) semitones."
        }
        var tips: [String] = []
        if mine.range < original.range * 0.6 {
            tips.append("Your pitch is flatter than the original (\(Int(mine.range.rounded())) vs \(Int(original.range.rounded())) semitones). Exaggerate the rises and falls on stressed words.")
        } else if mine.range > original.range * 1.6 {
            tips.append("Your pitch moves more than the original. Keep the unstressed words lower and calmer.")
        } else {
            tips.append("Your melody range is close to the original.")
        }
        if original.endingSlope < -1.5, mine.endingSlope > 1.5 {
            tips.append("The original falls at the end, but yours rises, which sounds like a question.")
        } else if original.endingSlope > 1.5, mine.endingSlope < -1.5 {
            tips.append("The original rises at the end; yours falls.")
        }
        return tips.joined(separator: " ")
    }
}

// MARK: - Chart

struct IntonationPanel: View {
    let result: IntonationResult?
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading {
                HStack { ProgressView(); Text("Analysing pitch…").font(.caption).foregroundStyle(.secondary) }
            } else if let result {
                let points = (result.original?.points ?? []) + result.mine.points
                if points.isEmpty {
                    Text(result.advice).font(.caption).foregroundStyle(.secondary)
                } else {
                    Chart(points) { p in
                        LineMark(x: .value("Time", p.t), y: .value("Pitch", p.semitone), series: .value("Run", "\(p.speaker)-\(p.run)"))
                            .foregroundStyle(by: .value("Speaker", p.speaker))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: p.speaker == "You" ? 3 : 2))
                    }
                    .chartForegroundStyleScale(["Original": Color.gray, "You": Color.accentColor])
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(values: [-6, 0, 6]) { v in
                            AxisGridLine()
                            AxisValueLabel { Text(v.as(Int.self).map { $0 == 0 ? "mid" : ($0 > 0 ? "high" : "low") } ?? "") }
                        }
                    }
                    .chartYScale(domain: -10...10)
                    .frame(height: 140)
                    Text(result.advice).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
