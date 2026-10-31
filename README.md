# Echo Shadow — ad-free English shadowing for iPhone

A personal, ad-free take on video shadowing apps like Tubeshad. Everything is stored on the phone
(SwiftData); network use is limited to YouTube playback/captions and the optional AI and Azure voice/scoring services you configure.

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
| **Literature** | Import PDF books and papers from Files or the share sheet; view and navigate pages, read a page aloud, generate a saved document summary, and ask questions in an AI window with source-page buttons. Uses your existing AI settings |
| **Articles** | Add Lesson ▸ Article (or Share ▸ Echo Shadow from Safari): paste a web link and the readable text is extracted on the phone (structured article body, else a readability-style pick of the main text; Wikipedia, news, blogs). Check/trim the text, then **Read all** plays the article sentence by sentence in your voice of choice, keeps going with the screen locked, and has lock-screen/headphone play, pause and skip. Stop on any sentence to shadow it. Articles are saved in their own section with site, listening time and resume point; bookmark (toolbar or swipe right) pins favourites to the top |
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

## Reading PDF books and papers

Open **Literature** → **+** to import a PDF, or share/open a PDF in Echo Shadow. The app keeps its own
copy and saves your reading page. Use the arrows or page slider to navigate, **Read page** to listen
with your configured voice, and **Page text** to see/copy the extracted text.

Tap **Ask AI** to open the Summary / Ask questions window. Choose a provider in **AI settings** (the
same settings used by Talk). Summaries cover every section with selectable text; long books require
multiple model calls and can be cancelled. Questions use relevant excerpts, the current page and recent
conversation context. Answers include physical PDF page references; source-page buttons return to the
reader. Summary and chat history are saved separately for each document. Swipe a library row to delete
the document, its local PDF copy, summary, and questions.

PDF viewing and Apple voice reading work without an AI key. On-device AI requires an available Apple
Intelligence model. Cloud AI sends extracted text only when you request a summary or answer; Azure
read-aloud uses the voice service when configured. PDFs and saved reading history remain on the device.

Limits: 150 MB / 2,000 pages per PDF. Password-protected PDFs need an unlocked copy. Scans without a
text layer can be viewed but need OCR in another app before AI or read-aloud can use them. Images,
figures, and pages without selectable text are not analyzed; the AI window shows the number of such
pages. Multi-column text follows PDFKit's extraction order. Question answers use selected excerpts,
so they may miss relevant passages; specify a physical PDF page or a more specific topic and verify the
source. AI summaries and answers can contain mistakes.

Standalone deterministic checks (macOS with Xcode, no API calls):

```bash
Tests/run-literature-checks.sh
```

These exercise extraction, blank/invalid/locked files, Unicode chunking, source retrieval, SwiftData
persistence, whole-book summary coverage, failed requests, cancellation, and saved questions.

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
  Literature.swift          PDF extraction, saved reading/chat data, source retrieval and AI summaries/Q&A
  LiteratureView.swift      Literature library, PDFKit reader, read-aloud and AI window
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
  ArticleFetcher.swift       Web article text extraction in an off-screen web view
  NowPlaying.swift           Lock-screen controls for Read all
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
