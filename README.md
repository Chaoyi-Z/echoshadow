# Echo Shadow — ad-free English shadowing for iPhone

A personal, ad-free take on video shadowing apps like Tubeshad. Everything is stored on the phone
(SwiftData); the only network use is YouTube playback and the optional caption fetch.

- iOS 17+, Swift 5, SwiftUI, SwiftData, Speech, AVFoundation, WebKit, Charts. No third-party dependencies.
- Bundle id `com.chaoyi.echoshadow`, signing team is set to the same team as RidePulse.

## What it does

| Area | Details |
|---|---|
| Lesson sources | **YouTube** link (captions fetched automatically when YouTube allows it, otherwise paste the transcript from ⋯ ▸ *Show transcript*); **audio/video file** from Files, transcribed on-device in 50-second chunks; **plain text**, read by the system voice |
| Shadowing | One sentence at a time: Listen (plays just that span), speed 0.5× – 1.25×, Loop, Previous/Next, sentence list with per-sentence best score |
| Scoring | Record → on-device speech recognition → word alignment (edit distance with fuzzy matching). Words are coloured matched / different / missed, plus a percent. "Play mine" replays your recording |
| Dictation mode | Eye icon hides every other longer word until you record or tap it |
| Words | Tap any word to hear it, open the system dictionary, or save it. Saved words come due on a simple spaced-repetition schedule (1 → 3 → 7 → 14 … days) |
| Progress | Day streak, total sentences, average score, saved words, 14-day bar chart |
| **Talk** (AI conversation) | Pick a scenario (small talk, lab meeting questions, job interview, café, doctor, airport, free chat), speak your turns, the partner replies out loud, then "End conversation & get feedback" returns corrections and native phrases. Partner is chosen in Settings: **on-device Apple model** (free, offline, iOS 26 + Apple Intelligence), **Claude** (Anthropic API key), **OpenAI-compatible** (any key + base URL, e.g. a university endpoint), or **Google Gemini** |
| **Sound-by-sound scoring** | Optional. With an Azure Speech key (free tier: 5 h audio/month) each recording is also scored by Azure pronunciation assessment: overall pronunciation, accuracy, fluency, completeness, prosody, a per-word accuracy number under each word, and tapping a word shows every phoneme (IPA) with its score so you see exactly which sounds are off |
| Voice | Settings ▸ Voice: **Azure neural** voices (Ava, Emma, Andrew, …; same Speech key as scoring, 500k characters/month free, audio cached per sentence) or **Apple** voices, auto-picking the best installed one; download Premium Apple voices in iOS Settings ▸ Accessibility ▸ Spoken Content ▸ Voices. Preview button included |
| **Hands-free Talk** | The mic opens by itself when the partner finishes speaking and your turn is sent after a 2-second pause, like a phone call. Tap the mic to interrupt; say "give me feedback" to finish. It closes quietly after 12 s of silence |
| **Weak-sound tracker** | Every Azure-scored phoneme is stored. Progress shows your five weakest sounds with a weekly trend; each sound has a detail page (tip, history chart, words that went wrong) and a one-tap drill whose sentences are written by your conversation model, or taken from a built-in bank offline |
| **Review queue** | Sentences scoring under 70% anywhere come back the next day in "Review 10" on the Lessons tab; 85%+ pushes them out (×2.5) until they graduate after ~3 weeks |
| **Talk rehearsal** | Add Lesson ▸ Script. Shadow the script sentence by sentence, then Run-through (top right) records the whole talk, transcribes it on the phone, and reports pace, coverage of the script, pauses, fillers, skipped sentences, plus coaching from your conversation model. Runs are saved |
| **Compare playback** | After recording: "Original, then mine" plays both back to back; Intonation draws both pitch curves (normalised per speaker) with advice. YouTube audio is not accessible to apps, so YouTube lessons show only your curve |
| **Share sheet** | Share a YouTube link, audio/video file or text to Echo Shadow from any app; files can also be opened with "Open in Echo Shadow". Uses the App Group `group.com.chaoyi.echoshadow` and the `echoshadow://import` link |
| Settings | Gear icon on Lessons and Talk. API keys are stored in the iOS Keychain; nothing leaves the phone except the calls you enable |

## Build & run

Open `EchoShadow.xcodeproj` in Xcode and run on a simulator or your iPhone (automatic signing).
Or from the terminal:

```bash
xcodebuild -project EchoShadow.xcodeproj -scheme EchoShadow -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Microphone and speech-recognition permission prompts appear the first time you record or import a file.

## Debug helpers

Launching a Debug build with `-seedDemo` (for example `xcrun simctl launch booted com.chaoyi.echoshadow -seedDemo`)
adds sample review sentences and scored sounds, and substitutes a sample delivery in run-throughs when the
simulator's speech service is unavailable. Release builds ignore it.

## Project layout

```
EchoShadow/
  EchoShadowApp.swift        App entry, SwiftData container
  ContentView.swift          Tab bar: Lessons / Words / Progress
  Models.swift               Lesson, Sentence, SavedWord, PracticeDay; MediaStore (imported files)
  TranscriptParser.swift     YouTube-transcript / SRT / VTT parsing, sentence segmentation
  YouTubeCaptionFetcher.swift  Video-id parsing, oEmbed title, best-effort caption download
  FileTranscriber.swift      Chunked on-device transcription of audio/video files
  Players.swift              YouTube IFrame player (WKWebView), AVPlayer wrapper, system voice
  SpeechScorer.swift         Microphone recorder + recognizer, word-alignment scoring
  PracticeViewModel.swift    Shadowing state machine (listen / loop / record / score)
  PracticeView.swift         Practice screen, sentence list, word sheet, flow layout
  LibraryView.swift          Lesson list
  AddLessonView.swift        New-lesson sheet (YouTube / file / text)
  WordsView.swift            Saved words + review flow
  StatsView.swift            Streak, totals, chart
  AppSettings.swift          Keychain wrapper, AppSettings, SettingsView
  ChatProviders.swift        ChatProvider protocol + Apple on-device / Claude / OpenAI-compatible / Gemini
  ConversationView.swift     Scenarios, ConversationViewModel, Talk screen
  PronunciationAssessor.swift  Azure Speech pronunciation assessment (REST), WAV 16 kHz conversion
  SoundTracker.swift         Phoneme catalogue, weak-sound stats, drill generator, sound screens
  ReviewQueue.swift          Cross-lesson review session and banner
  Rehearsal.swift            Run-through recorder, script aligner, analysis, coach, report screen
  CompareKit.swift           Audio loading, YIN pitch tracking, reference audio, intonation chart
EchoShadowShare/             Share extension (ShareViewController)
Shared/SharedImport.swift    App Group hand-off used by the app and the extension
Config/                      Info.plist additions (URL scheme, document types) and entitlements
```

The `.xcodeproj` uses Xcode's folder-synchronized group, so any new `.swift` file dropped into
`EchoShadow/` is picked up automatically — no project-file edits needed.

## Setting up the optional cloud features

- **Azure pronunciation scoring:** create a free Azure account, add a *Speech* resource (free F0 tier), copy
  one of its keys and its region (for example `eastus`) into Settings. Recordings up to 30 s are scored.
- **MIT Parley (MIT's LLM gateway, keys start with `sk-parley-`):** the gateway at `https://parley.api.mit.edu/v1`
  speaks the OpenAI format (`/chat/completions`) and the Anthropic format (`/messages`). In Settings choose
  *OpenAI / compatible* or *Claude*, paste the Parley key, tap **Use MIT Parley gateway**, then **Load model list
  from server** and pick a model. Monthly credits are shown on platform.parley.mit.edu.
- **Other OpenAI-compatible partner:** paste the key, the base URL the provider gives you (everything before
  `/chat/completions`), and the model name it expects, or load the model list.
- **Claude partner:** needs an Anthropic API key with prepaid credits from console.anthropic.com. A Claude
  subscription does not include API access. Requests use `claude-opus-5-5` with the server-side refusal
  fallback enabled.
- **Gemini partner:** a Google AI Studio key.

## Known limits

- **Automatic YouTube captions are currently blocked by YouTube** (verified Oct 2026: the caption endpoint
  returns an empty body without YouTube's proof-of-origin token, even from inside a youtube.com page).
  The button still tries two strategies and fetches the title, but expect to paste the transcript. **Save stays
  disabled until sentences are detected.** The YouTube iPhone app does not let you copy the transcript panel, so
  copy it on a computer or in Safari with "Request Desktop Website": open the video ▸ description ▸ *Show
  transcript* ▸ select all ▸ copy ▸ paste into Step 2 of the lesson sheet. Alternative that works entirely on the
  phone: download the audio/video and use the Audio/Video tab (on-device transcription).
- Some videos disallow embedded playback; the player shows a message when YouTube refuses.
- The iOS Simulator cannot record from the microphone reliably (CoreAudio deadlocks and kills the app),
  so test recording/scoring on a real iPhone.
- Speech recognition quality depends on the device. On-device recognition is used when the device supports it.
