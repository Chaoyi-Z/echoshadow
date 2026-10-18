import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit
import WebKit

/// Common surface for the YouTube and local players so the practice engine can drive either.
@MainActor
protocol MediaPlayer: AnyObject {
    var isReady: Bool { get }
    var isPlaying: Bool { get }
    var currentTime: Double { get }
    var onTime: (@MainActor (Double) -> Void)? { get set }
    func seek(to seconds: Double)
    func play()
    func pause()
    func setRate(_ rate: Float)
}

// MARK: - YouTube (IFrame API inside a WKWebView)

@MainActor
final class YouTubePlayerController: ObservableObject, MediaPlayer {
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var loadError: String?
    var onTime: (@MainActor (Double) -> Void)?

    let webView: WKWebView
    private let proxy = ScriptMessageProxy()
    private var pendingRate: Float = 1

    init(videoID: String, showsControls: Bool = false) {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let content = WKUserContentController()
        content.add(proxy, name: "yt")
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        proxy.handler = { [weak self] body in self?.handle(body) }
        // A neutral https origin: YouTube refuses embeds that claim to come from youtube.com itself.
        webView.loadHTMLString(Self.html(videoID: videoID, controls: showsControls), baseURL: URL(string: Self.pageOrigin))
    }

    private func handle(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            duration = dict["duration"] as? Double ?? 0
            setRate(pendingRate)
        case "state":
            let state = dict["state"] as? Int ?? -1
            isPlaying = state == 1
            if let t = dict["time"] as? Double { currentTime = t }
        case "time":
            if let t = dict["time"] as? Double {
                currentTime = t
                onTime?(t)
            }
        case "error":
            let code = dict["code"] as? Int ?? 0
            loadError = code == 101 || code == 150
                ? "This video does not allow embedded playback."
                : "YouTube player error \(code)."
        default:
            break
        }
    }

    func seek(to seconds: Double) { webView.evaluateJavaScript("seekTo(\(seconds))") }
    func play() { webView.evaluateJavaScript("play()") }
    func pause() { webView.evaluateJavaScript("pause()") }
    func setRate(_ rate: Float) {
        pendingRate = rate
        guard isReady else { return }
        webView.evaluateJavaScript("setRate(\(rate))")
    }

    static let pageOrigin = "https://echoshadow.app"

    private static func html(videoID: String, controls: Bool) -> String {
        """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="initial-scale=1.0, user-scalable=no">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}
        #player{position:absolute;top:0;left:0;width:100%;height:100%}</style>
        </head><body><div id="player"></div>
        <script>
        var tag=document.createElement('script');tag.src="https://www.youtube.com/iframe_api";document.head.appendChild(tag);
        var player,timer;
        function post(m){window.webkit.messageHandlers.yt.postMessage(m);}
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('player',{videoId:'\(videoID)',
            playerVars:{playsinline:1,controls:\(controls ? 1 : 0),rel:0,modestbranding:1,fs:0,disablekb:1,iv_load_policy:3,cc_load_policy:0,origin:'\(pageOrigin)',widget_referrer:'\(pageOrigin)'},
            events:{
              onReady:function(){post({type:'ready',duration:player.getDuration()});},
              onStateChange:function(e){post({type:'state',state:e.data,time:player.getCurrentTime()});if(e.data===1){startTimer();}else{stopTimer();}},
              onError:function(e){post({type:'error',code:e.data});}
            }});
        }
        function startTimer(){stopTimer();timer=setInterval(function(){post({type:'time',time:player.getCurrentTime()});},100);}
        function stopTimer(){if(timer){clearInterval(timer);timer=null;}}
        function seekTo(t){player.seekTo(t,true);}
        function play(){player.playVideo();}
        function pause(){player.pauseVideo();}
        function setRate(r){player.setPlaybackRate(r);}
        </script></body></html>
        """
    }
}

/// Non-isolated bridge so WebKit's delegate requirement is satisfied without actor warnings.
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    var handler: (@MainActor (Any) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { handler?(body) }
    }
}

struct YouTubePlayerView: UIViewRepresentable {
    let controller: YouTubePlayerController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Local audio/video (AVPlayer)

@MainActor
final class LocalPlayerController: ObservableObject, MediaPlayer {
    @Published private(set) var isReady = true
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    var onTime: (@MainActor (Double) -> Void)?

    let player: AVPlayer
    private var observer: Any?
    private var rate: Float = 1

    init(url: URL) {
        player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.player.rate != 0
                self.onTime?(time.seconds)
            }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func play() { player.playImmediately(atRate: rate); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func setRate(_ r: Float) {
        rate = r
        if player.rate != 0 { player.rate = r }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - Spoken voice (Azure neural TTS when configured, otherwise the best installed Apple voice)

@MainActor
final class SpeechVoice: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private let relay = SpeechDelegateRelay()
    private var player: AVAudioPlayer?
    private var fetchTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private static var cache: [String: Data] = [:]

    override init() {
        super.init()
        relay.onFinish = { [weak self] in self?.isSpeaking = false }
        synthesizer.delegate = relay
    }

    func speak(_ text: String, rate: Float) {
        stop()
        let settings = AppSettings.shared
        if settings.voiceEngine == .azure, settings.azureConfigured {
            speakAzure(text, rate: rate, settings: settings)
        } else {
            speakApple(text, rate: rate, voiceID: settings.appleVoiceID)
        }
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        fetchTask?.cancel()
        fetchTask = nil
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    // MARK: Apple

    private func speakApple(_ text: String, rate: Float, voiceID: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = (voiceID.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voiceID)) ?? Self.bestAppleVoice()
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * rate)
        isSpeaking = true
        synthesizer.speak(utterance)
        startWatchdog(text: text, rate: rate) { [weak self] in self?.synthesizer.isSpeaking ?? false }
    }

    /// Finish callbacks can go missing (audio route changes, the simulator). Poll the real playback state,
    /// and give up after about twice the expected length, so hands-free never waits forever.
    private func startWatchdog(text: String, rate: Float, isActive: @escaping @MainActor () -> Bool) {
        watchdog?.cancel()
        let words = Double(max(1, text.split(separator: " ").count))
        let expected = words / (2.6 * Double(max(rate, 0.5)))
        let deadline = Date().addingTimeInterval(expected * 2 + 4)
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                guard let self, self.isSpeaking else { return }
                if !isActive() || Date() > deadline {
                    if Date() > deadline { self.synthesizer.stopSpeaking(at: .immediate); self.player?.stop() }
                    self.isSpeaking = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Installed English voices, best quality first (Premium > Enhanced > default; en-US preferred).
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { rank($0) > rank($1) }
    }

    private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        let quality: Int
        switch v.quality {
        case .premium: quality = 2
        case .enhanced: quality = 1
        default: quality = 0
        }
        return quality * 10 + (v.language == "en-US" ? 1 : 0)
    }

    static func bestAppleVoice() -> AVSpeechSynthesisVoice? {
        englishVoices().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    // MARK: Azure

    /// MP3 bytes for a sentence in the chosen Azure voice, fetched once and cached.
    static func azureAudio(_ text: String, rate: Float) async throws -> Data {
        let settings = AppSettings.shared
        let cacheKey = "\(settings.azureVoice)|\(rate)|\(text)"
        if let cached = cache[cacheKey] { return cached }
        let tts = AzureTTS(key: settings.azureKey, regionOrHost: settings.azureRegion, voice: settings.azureVoice)
        let data = try await tts.synthesize(text, rate: rate)
        cache[cacheKey] = data
        if cache.count > 200 { cache.removeAll() }
        return data
    }

    private func speakAzure(_ text: String, rate: Float, settings: AppSettings) {
        isSpeaking = true
        fetchTask = Task { [weak self] in
            do {
                let data = try await Self.azureAudio(text, rate: rate)
                guard let self, !Task.isCancelled else { return }
                try? AudioSession.configure()
                let p = try AVAudioPlayer(data: data)
                p.delegate = relay
                player = p
                guard p.play() else { speakApple(text, rate: rate, voiceID: settings.appleVoiceID); return }
                startWatchdog(text: text, rate: rate) { [weak self] in self?.player?.isPlaying ?? false }
            } catch {
                // Network or key problem: fall back to the Apple voice rather than staying silent.
                guard let self, !Task.isCancelled else { return }
                speakApple(text, rate: rate, voiceID: settings.appleVoiceID)
            }
        }
    }
}

final class SpeechDelegateRelay: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var onFinish: (@MainActor () -> Void)?
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in onFinish?() }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in onFinish?() }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish?() }
    }
}

/// Azure neural text-to-speech over REST. Same Speech resource and key as pronunciation scoring.
struct AzureTTS {
    let key: String
    let regionOrHost: String
    let voice: String

    static let curatedVoices: [(id: String, label: String)] = [
        ("en-US-AvaMultilingualNeural", "Ava · US, warm"),
        ("en-US-EmmaMultilingualNeural", "Emma · US, friendly"),
        ("en-US-AndrewMultilingualNeural", "Andrew · US, calm"),
        ("en-US-BrianMultilingualNeural", "Brian · US, clear"),
        ("en-US-JennyNeural", "Jenny · US, classic"),
        ("en-US-GuyNeural", "Guy · US, newsreader"),
        ("en-GB-SoniaNeural", "Sonia · British"),
        ("en-GB-RyanNeural", "Ryan · British"),
        ("en-AU-NatashaNeural", "Natasha · Australian"),
    ]

    private var endpoint: URL? {
        let trimmed = regionOrHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(".") {
            let host = trimmed.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return URL(string: "https://\(host)/tts/cognitiveservices/v1")
        }
        return URL(string: "https://\(trimmed).tts.speech.microsoft.com/cognitiveservices/v1")
    }

    func synthesize(_ text: String, rate: Float) async throws -> Data {
        guard !key.isEmpty, let url = endpoint else { throw AssessmentError.notConfigured }
        let percent = Int(((rate - 1) * 100).rounded())
        let rateAttr = percent >= 0 ? "+\(percent)%" : "\(percent)%"
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
        let ssml = """
        <speak version='1.0' xml:lang='en-US' xmlns='http://www.w3.org/2001/10/synthesis'><voice name='\(voice)'><prosody rate='\(rateAttr)'>\(escaped)</prosody></voice></speak>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("EchoShadow", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(ssml.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else { throw AssessmentError.http(status, String(data: data, encoding: .utf8) ?? "") }
        return data
    }
}

enum AudioSession {
    static func configure() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
    }
}
