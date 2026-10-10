# whisper-native

Native macOS menu-bar dictation app: records the mic, transcribes with a local or
cloud engine and inserts the text into the focused app.

## Build / run
- `mise run generate`: xcodegen (`project.yml` is the source of truth, the
  xcodeproj is generated and gitignored). `ai:build`/`ai:test` don't regenerate:
  run it after adding or deleting Swift files, else new symbols are "not in scope".
- `mise run ai:build` / `ai:test` / `ai:run` (build + open this checkout's .app):
  use these, not the bare `build`/`test` tasks.
- No Apple Development cert: signing fails; check compilation with
  `xcodebuild -project WhisperNative.xcodeproj -scheme WhisperNative -configuration Debug build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`.
- Missing cmake / "tapi error: malformed file" on `whisper:build`: install cmake
  and prefix the task with `SDKROOT=$(xcrun --sdk macosx --show-sdk-path)` (cmake
  otherwise picks the Command Line Tools SDK, which Xcode's linker can't read).
  Editing `mise.toml` forces a whisper.cpp rebuild.
- Built app: `~/Library/Developer/Xcode/DerivedData/WhisperNative-*/Build/Products/Debug/`.
  Worktrees get their own DerivedData dir: match its `info.plist` `WorkspacePath`.
- Logs: `~/Library/Logs/whisper-native/` (dev: `whisper-native-dev/`).

## Architecture
- Menu-bar agent (`LSUIElement`), SwiftUI `@main` + `AppDelegate`, bundle id
  `io.binarygap.whisper-native`.
- Two targets, sources in `Sources/<target>/<module>/`: app `WhisperNative` (App,
  Hotkeys, Settings, Onboarding) and framework `WhisperNativeCore` (Shared, Server,
  Backend, Audio, TextInsertion, UI). Testable rules live in Core.
- Pipeline: hotkey -> `AudioRecorder` (16 kHz mono 16-bit WAV) -> engine backend
  -> `TextInserter`, orchestrated in `Sources/WhisperNative/App/`.
- Settings in `Config` (UserDefaults); paths, ports and limits in `Constants`.
- Every child process goes through `ProcessRunner` (drains output, per-call
  timeout).
- SPM dependencies are pinned with `exactVersion` in project.yml.

### Dev build
- Debug builds "WhisperNative Dev" (`io.binarygap.whisper-native.dev`), which runs
  next to the installed Release: own TCC grants, UserDefaults and menu-bar item.
- `Constants.isDevBuild` (`#if DEBUG`, tests included) splits the rest: daemon
  label `.dev` on port 8081, data and logs under `whisper-native-dev/`, Keychain
  service `.dev`. The models folder is shared. Paths here are the Release values.
- Both copies start with the same default hotkeys: give the dev app its own toggle
  hotkey while both run.

## Engines
`Config.transcriptionEngine`: whisper, Parakeet, Gemini (batch), Gemini Live.
`EngineChoice` maps the three user-facing choices to it (Gemini picks batch or
Live from `Config.geminiStreaming`) and blocks Gemini without an API key.
- Switching to Parakeet or Gemini boots the whisper daemon out; switching back
  unloads Parakeet and re-bootstraps whisper. Only whisper runs the health check,
  prompt and voice calibration.
- `AppDelegate.prepareWhisperModel` runs before whisper is used (switch, launch,
  onboarding close, Start Server): falls back to a downloaded model, downloads the
  VAD model silently, asks before downloading a whisper model. Cancel on a switch
  reverts to the previous engine.
- `TranscriptionEngine.hasLiveTranscript` (Parakeet, Gemini Live) gates the live
  transcript pill and stop words.
- The selected language is read at request time (cycling mid-recording applies),
  except Gemini Live, which fixes it at recording start.
- Parakeet and both Gemini engines post-process with `FillerRemover` ("um" kept
  for Portuguese, where it's an article) and `LineWrapper`; whisper wraps
  server-side (`max_len`).

### whisper server
- Always-on launchd daemon, not a child process: the warm model between
  dictations is the point. `WhisperServerManager` writes the plist (KeepAlive +
  RunAtLoad, rewritten to the bundled binary on every launch) and bootstraps it.
- It respawns and starts at login until booted out + disabled: engine switch,
  Start/Stop and quit do that. Quit (menu, logout, SIGTERM) boots it out in
  `applicationShouldTerminate`, waiting at most 3 s. SIGTERM goes DispatchSource
  -> `RunLoop.main.perform` -> `NSApp.terminate`, since the quit reply needs the
  main queue the handler runs on.
- `127.0.0.1:8080`: `GET /health`, `POST /inference` (multipart WAV), `POST /load`
  (model hot-swap). Changing model or VAD in Settings calls
  `WhisperServerManager.reload`, skipped while the file isn't readable.
- Prompt (`WhisperPrompt`): language example sentence, `Config.prompt`, then
  words-file vocabulary while `Config.whisperUsesVocabulary`. whisper.cpp keeps
  only the last 224 tokens, so terms go in file order while the estimate stays
  within 200; the rest are dropped with a warning.
- Tear down the dev daemon (KeepAlive respawns it otherwise):
  `launchctl bootout gui/$(id -u)/io.binarygap.whisper-server.dev; launchctl disable ...; pkill -9 -f "DerivedData/.*whisper-server"`.
  A bare `pkill -f whisper-server` also kills the installed Release's server.

### Parakeet
- `ParakeetBackend` (`.shared` actor): Parakeet TDT v3 in-process via FluidAudio,
  Silero VAD first. Models in `~/Library/Application Support/FluidAudio/Models`,
  ~20 s first load.
- No custom vocabulary. Auto-detects the language; the selected one only picks
  the script token filter (`tokenFilterLanguage`).
- Live preview: the Orchestrator re-reads the growing WAV every 0.7 s
  (`WavWriter.readGrowingSamples`) into `transcribePreview`; the pasted text comes
  from the full pass at stop.

### Gemini (batch)
- `GeminiBackend` sends the finished WAV inline to `gemini-3.5-transcribe` via
  `POST v1beta/interactions` with `store: false`. Inline cap ~7 min of audio.
- Key in the Keychain (`GeminiAPIKeyStore`), `GEMINI_API_KEY` env as fallback;
  never in Config or logs. A key removed while Gemini is active keeps Gemini
  selected (no silent engine switch): dictations fail with
  `AppError.geminiAPIKeyMissing`.
- Every call is billed: no exploratory or repeated API requests unless the change
  touches the request path; answer API questions from docs first.
- Tests use stubs. Billed live tests run only with `GEMINI_BILLED_TESTS=1` + key
  (`BilledGeminiTests.apiKey()`), passed as `TEST_RUNNER_`-prefixed env vars to
  `xcodebuild -scheme WhisperNativeCoreTests -configuration Debug test -only-testing:WhisperNativeCoreTests/GeminiBackendTests`
  (`GeminiLiveSessionLiveTests` for the streaming path).

### Gemini Live
- Streams audio while recording to `gemini-3.5-transcribe-live` over the Live API
  WebSocket, key in the `x-goog-api-key` header so the URL stays loggable.
- `GeminiLiveProtocol` (messages, BCP-47 language hint), `GeminiLiveSession` (one
  socket per dictation, manual VAD), `GeminiLiveBackend` (5 s final timeout;
  connect error, drop, timeout or no key fall back to ONE batch call on the WAV;
  cancel never falls back).
- Server quirks: no `turnComplete`, nothing after `generationComplete`, so the
  client closes with 1000 right then. The API dashboard counts each such stream
  as a 409 ABORTED: expected.
- `usageMetadata` never arrives: cost is estimated from audio seconds
  (`GeminiPricing`). History reruns use the batch model.

## Words file
`words.yml` in the data folder (`Constants.wordsFileURL`), parsed by `WordsFile`
(Yams) at every request / recording start. Agents may edit it directly.
- Sections `vocabulary` and `stop words`, each mapping `all` or a language
  (English name or whisper code) to terms. Fixed language: `all` + its list;
  auto: every list.
- Invalid parts log a warning and are ignored; malformed YAML sends no
  vocabulary and uses `WordsFile.defaultStopWords`. Vocabulary caps at 1,000.
- The Settings Edit… button creates or completes the file through text inserts
  that keep existing content and comments, skipping inserts that wouldn't parse.
- A missing `words.yml` is migrated once from the older `vocabulary.yml` /
  `vocabulary.txt`.

## Recording
- `AudioRecorder` captures through a CoreAudio IOProc (works with Continuity
  Camera mics). `pcmSink` feeds Gemini Live; the WAV gets every buffer.
- Voice processing (`Config.voiceProcessing`, read at recording start): an
  AVAudioEngine input node with voice processing on. Only channel 0 is converted
  (the rest are reference channels); the mic is set after enabling. Setup failure
  falls back to the raw mic. Enabling takes ~0.5 s, so the engine stays built and
  stopped between recordings (`prepareVoiceProcessing`, keyed by input + output
  device, rebuilt 1 s after a system default device change); stopped, it holds
  no device and ducks nothing. While it exists, the
  CoreAudio device list in this process gains its private aggregates and echo
  inputs on output devices: the mic picker lists through `AVCaptureDevice`.
- Auto-start when you speak (`Config.startOnVoice`): the idle mic listens with a
  1.5 s pre-roll ring; `VoiceStartDetector` (streaming Silero VAD) feeds
  `SpeechOnsetGate`. Listening stays unprocessed (ducking would last the whole
  idle time, the gate is tuned on raw levels); `VoiceProcessingPolicy` decides.
- Every path that flips `startOnVoice` ends in
  `Orchestrator.startOnVoiceSettingsChanged`; turning it off cancels a
  voice-started recording outright. `refreshVoiceStart` re-arms after every
  dictation. The mic closes on screen lock / sleep and never prompts.
- Stop words (`Config.stopOnOver`): `StopWordMatcher` matches only at the end of
  the live transcript, on word boundaries; `StopWordWatcher` confirms, then the
  Orchestrator stops and strips the word from the final text.
- `MusicPause` (local package, `swift test` inside it) pauses Apple Music over
  ScriptingBridge on a private queue (the first event blocks on the Automation
  prompt). Never message Music when it isn't running: that launches it.

## Text insertion
- `InsertionPlan.make` picks the route at recording start; "Copy to clipboard"
  never auto-submits.
- Paste = pasteboard + Cmd-V with restore, CGEvent typing fallback. Auto-submit:
  iTerm2 through `ItermBridge`, other apps a Return 0.15 s after Cmd-V.
- The iTerm2 session lookup (~230 ms Python helper) runs alongside the mic start
  and is awaited only at insertion: never put it back on the start path.
- `Resources/iterm/iterm_helper.py` types the text; with a shell or ssh
  foreground job it joins lines with spaces, else each newline runs a command.

## Hotkeys and language
- KeyboardShortcuts SPM, user-customizable, persisted by the package.
- `Language` is keyed by whisper codes; unknown codes decode to auto.
  `ActiveLanguages` holds the user's languages, cycled by the language hotkey.

## History
`TranscriptionHistoryStore` keeps the newest 5000 dictations in
`history/history.json` (usage log for debugging and model comparisons); only the
newest 50 keep their WAV.

## Models
- Default dir `~/Library/Application Support/whisper-native/models/`.
- Every download URL pins a Hugging Face commit, and the file must match the
  catalog's exact size and SHA-256 (`ModelDownload`) before it replaces anything.
  Bumping a model = update revision, size and hash together.
- Finishing a download never selects the model; only the prompt-confirmed
  `ModelSectionState.downloadDefaults` does. In-use and delete rules:
  `ModelStorage`.

### whisper.cpp build + bundling
- Never checked in: `whisper:fetch` clones the pinned `WHISPER_CPP_TAG`
  (mise.toml) into `external/whisper.cpp/`; `whisper:build` builds it and runs
  `scripts/stage-whisper-server.sh`. `generate` depends on it, since xcodegen
  lists the staged dylibs.
- whisper-server links `libwhisper` + `libggml*` dylibs via `@rpath`: the staging
  script fixes rpaths, project.yml embeds them through Copy Files phases with
  `CodeSignOnCopy`.
- Never modify bundle contents from a run script: Xcode skips re-sealing on
  incremental builds and `codesign --verify` fails.
- Binary lookup: `WHISPER_SERVER_BINARY` env -> bundled -> Debug-only checkout
  path from `#filePath`. Release holds no checkout path (`-ffile-prefix-map`
  covers the dylibs).

## UI conventions
- Explanatory text goes behind "?" popovers (`InfoButton` / `InfoLabel` in
  DesignSystem.swift), never in footers or captions; status and warning text
  stays visible.
- Onboarding and Settings share the same control views, writing straight to
  `store.config`. Bump `Onboarding.currentVersion` to reshow onboarding.
- A new feature gets one line in `MoreInSettingsStepView`, not its own onboarding
  step.
- The Settings window never changes page on its own.
- Update checks never pop a window while the app isn't focused.
- LSUIElement windows: set alpha directly, never animate it in (the animation
  silently skips, leaving the window at alpha 0).

## Updates
- Sparkle through `AppUpdater`. Feed = `appcast.xml` of the latest GitHub
  release, so every release uploads one; the DMG and the appcast must both be
  EdDSA-signed (`SUPublicEDKey`).
- Dev builds have no feed unless the `updateFeedURL` default is set.

## Permissions (TCC)
- Needs mic + Accessibility (paste, typing, AX). An ad-hoc build has no
  Accessibility grant: AX queries and paste silently fail, so test them on a
  granted build.
- Grants bind to bundle id + signing cert (Automation for Music too). Two builds
  under one bundle id with different certs share one checked row in System
  Settings, yet the running one is untrusted and paste is silently dropped. Fix:
  `tccutil reset Accessibility io.binarygap.whisper-native`, re-grant.
- The `csreq` column of `/Library/Application Support/com.apple.TCC/TCC.db`
  (`sudo sqlite3`) names the cert a grant is bound to. SIP blocks writing it.
