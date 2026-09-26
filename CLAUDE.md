# whisper-native

Native macOS Swift port of the Hammerspoon whisper dictation tool: always-on menu-bar agent that records mic, transcribes via a local whisper.cpp server daemon, and inserts text into the focused app.

## Architecture
- Menu-bar agent app (`LSUIElement=true`, no dock icon). SwiftUI `@main` + `AppDelegate`. App target `WhisperNative`, bundle id `io.binarygap.whisper-native` (Binary Gap LLC).
- Built with xcodegen (`project.yml` is source of truth; `WhisperNative.xcodeproj` is generated + gitignored). Tasks via mise.
- Pipeline: global hotkey -> `AudioRecorder` (AVAudioEngine -> 16kHz mono 16-bit PCM wav) -> `WhisperClient` (HTTP multipart POST to local server) -> `TextInserter` (pasteboard+Cmd-V w/ restore, CGEvent typing fallback). Orchestrated in `Sources/WhisperNative/App/`.
- Whisper server is an always-on DAEMON, not a child process: `WhisperServerManager` installs a launchd plist and `launchctl bootstrap`s it. Server persists across app restarts (warm model = the whole point). App boots it out on Quit (`stopServer` wired in AppDelegate). plist has KeepAlive, so it respawns until explicitly booted out + disabled.

## Modules
Source dirs group by target under `Sources/<target>/<module>/`. App target (`WhisperNative`): App, Hotkeys, Settings. Framework target (`WhisperNativeCore`): Shared, Server, Backend, Audio, TextInsertion, UI. This mirrors the two-target split and renders as two parent groups in Xcode.
- Shared: Models, Config (UserDefaults-backed, all settings), Constants (paths/ports), AppError, FileLogger.
- Server: WhisperServerManager (launchd bootstrap/bootout, health, model hot-swap via POST /load), LaunchdManager, ServerPlist.
- Backend: WhisperClient + TranscriptionBackend protocol, MultipartFormData. ParakeetBackend (`.shared` actor): Parakeet TDT v3 in-process via the FluidAudio SPM package (Apache-2.0, pinned `exactVersion` in project.yml), Silero VAD first, output through FillerRemover (drops uh/hmm; "um" only for non-Portuguese text since it's the pt article). "Wrap lines" / "Sentence per line" apply to Parakeet too: whisper wraps server-side (`max_len`), Parakeet through `LineWrapper`. Models download to `~/Library/Application Support/FluidAudio/Models` on first load (~20s first load, then ~0.05-0.5s per dictation).
- Engine switch (`Config.transcriptionEngine`, Settings > General): selecting Parakeet boots the whisper daemon out and preloads Parakeet; switching back unloads Parakeet and re-bootstraps whisper. Parakeet skips the whisper health check, prompt and voice calibration; it auto-detects, and the selected language only picks its script token filter (`ParakeetBackend.tokenFilterLanguage`: FluidAudio-supported language passes through; auto/unsupported gets the Latin filter when the system language is Latin-script, else none).
- Audio: AudioRecorder, WavWriter, RecordingIndicator.
- Hotkeys: HotkeyManager via KeyboardShortcuts SPM (sindresorhus/KeyboardShortcuts) — push-to-talk + toggle, user-customizable, persisted by the package. `cycleLanguage` (Option+Tab) advances `selectedLanguage` through `Config.cycleLanguages` (user-picked subset of whisper.cpp languages, default auto + system language; `Language` is a struct keyed by whisper codes, unknown codes decode to auto); language is read at request time, so cycling mid-recording applies to the in-flight dictation.
- TextInsertion: TextInserter.
- UI: LanguageHUD — transient bottom-center pill (above the RecordingIndicator glow band) confirming the language after a cycle. Window alpha is set directly, never animated in: alphaValue animations on this LSUIElement app's windows silently skip, leaving the window on screen at alpha 0.
- UI: LiveTranscriptPill — transcript while recording with Parakeet, placed once at recording start by `TextInputLocator` (AX: caret rect -> small focused element -> focused window bottom -> screen bottom-center), on whichever side of the line has more room, left edge fixed; it grows with the text and drops the oldest words only once it runs out of screen. iTerm2 exposes the caret rect. Orchestrator re-reads the growing WAV (`WavWriter.readGrowingSamples`) every 0.7s and runs `ParakeetBackend.transcribePreview` (no VAD); the pasted text still comes from the full pass at stop. LanguageHUD sits one window level above it.
- Settings: SettingsStore, SettingsWindowController (SwiftUI), StatusMenuBuilder (NSStatusItem menu; the button title carries the current language code, kept in sync from `store.$config` so hotkey and picker both update it).

## Build / run
- `mise run generate` — xcodegen generate (also resolves SPM deps).
- `mise run ai:build` / `mise run ai:test` — agent-facing variants (see `~/.claude/rules/mise-conventions.md`). Use these, not the bare `build`/`test` tasks.
- `mise run ai:run` — build (summarized) + open the .app. After making code changes, run this and tell the user the build is updated and running. A `Stop` hook in `.claude/settings.json` runs this automatically at the end of every turn. On a Mac without an Apple Development cert it fails at signing; build ad-hoc with `xcodebuild -project WhisperNative.xcodeproj -scheme WhisperNative -configuration Debug build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to check compilation.
- `No signing certificate "Mac Development" found`: the Apple Development identity is missing from the login keychain (e.g. after a machine restore). Maintainers pull it read-only with fastlane match (`type:development platform:macos readonly:true skip_provisioning_profiles:true`, run with the release secrets in the environment).
- Missing cmake / "tapi error: malformed file" on `whisper:build`: cmake isn't installed system-wide and, when present, picks the Command Line Tools SDK that Xcode's linker can't read. Fix with `SDKROOT=$(xcrun --sdk macosx --show-sdk-path) nix shell nixpkgs#cmake -c mise run ai:test` (e.g. via nix), or install cmake and point `SDKROOT` at Xcode's SDK.
- Built app: `~/Library/Developer/Xcode/DerivedData/WhisperNative-*/Build/Products/Debug/WhisperNative.app`.
- App logs: `~/Library/Logs/whisper-native/`.

## whisper.cpp build + bundling
- Source cloned + built by mise, never checked in. `mise run whisper:fetch` shallow-clones `ggerganov/whisper.cpp` at the pinned `WHISPER_CPP_TAG` (mise.toml env, currently v1.9.1) into gitignored `external/whisper.cpp/`; `whisper:build` runs cmake (Release, `GGML_METAL=ON`, `WHISPER_COREML=OFF`) producing `external/whisper.cpp/build/bin/whisper-server` + its dylibs. `ai:build`/`build` depend on `whisper:build`.
- v1.9.1 whisper-server is NOT static: it links `libwhisper` + five `libggml*` dylibs via `@rpath` (Metal shaders are embedded in `libggml-metal` via `GGML_METAL_EMBED_LIBRARY`, so no external `.metallib`).
- The `Bundle whisper-server` postBuildScript (project.yml) copies the binary into `Contents/Resources/`, the six versioned dylibs into `Contents/Frameworks/` (recreating major-version symlinks the install names reference), rewrites the binary's rpath to `@executable_path/../Frameworks` (deleting cmake's dev-tree rpath), adds `@loader_path` rpath to each dylib for inter-dep resolution, and codesigns dylibs-then-binary. Requires `ENABLE_USER_SCRIPT_SANDBOXING=NO` (script reads outside DerivedData).
- `WhisperServerManager.resolveBinaryPath()`: `WHISPER_SERVER_BINARY` env override -> bundled `Contents/Resources/whisper-server` -> dev fallback `<repo>/external/whisper.cpp/build/bin/whisper-server`, `<repo>` derived from `#filePath` at compile time (walks up from the source file to the repo root), so it resolves to whichever checkout this was compiled from.

## Runtime dependencies (models overridable in Settings)
- Models default dir: `~/Library/Application Support/whisper-native/models/` (App Support, `Constants.defaultModelsDirectory`). Settings scans this folder for `.bin` files (`ModelManager.availableModels`, silero excluded from the whisper-model picker). User can point at a different folder.
- First run downloads on demand from HuggingFace (`ModelSectionState.downloadDefaults`): whisper `ggml-large-v3-turbo.bin` (`ggerganov/whisper.cpp`) + VAD `ggml-silero-v6.2.0.bin` (`ggml-org/whisper-vad`). Streaming download w/ progress in GeneralTab.
- Changing the selected model/VAD in Settings reloads the server: AppDelegate observes `store.$config` (modelPath/vadModelPath), calls `WhisperServerManager.reload` (rewrites plist + re-bootstraps launchd). Skips reload if the model file isn't readable.
- server: `127.0.0.1:8080`, `GET /health` -> `{"status":"ok"}`, transcribe via `POST /inference` (multipart wav + language/vad/etc params, returns `{"text":...}`).
- Needs mic + accessibility TCC permissions (accessibility for CGEvent paste/typing). `HotkeyManager.startAccessibilityPoll` picks the grant up live, no relaunch.
- TCC keys accessibility on bundle id + code-signing requirement, so the Debug build (`Apple Development: Created via API`) and a Developer ID build in `/Applications` are DIFFERENT clients under one `io.binarygap.whisper-native` row. System Settings then shows a single checked "WhisperNative" while the running copy is untrusted: mic works, `CGEventPost` of Cmd+V is silently dropped, nothing pastes. Keep only one installed copy; after switching which one you run, `tccutil reset Accessibility io.binarygap.whisper-native` and re-grant. Inspect with `sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select service, auth_value, hex(csreq) from access where client like '%whisper%';"` — the csreq names the cert the grant is bound to. SIP blocks writing that db even as root; flip the toggle in the UI.

## Notarization
- Release tooling (fastlane, Developer ID signing, notarization) lives in the gitignored `fastlane/` folder and `mise.local.toml`, maintainers only.
- `release:install` (a `depends_post` of `mise run release`) replaces `/Applications/WhisperNative.app`, which puts a Developer ID copy next to the Debug build you develop against, exactly the two-copy TCC collision described above.
- Anything needing AX or paste (text-input anchoring, Cmd+V) must be tested on a build that holds the accessibility grant: an ad-hoc Debug build has no accessibility grant, so AX queries and paste silently fail there.

## Status / unproven
- Builds clean, launches, server daemon comes up + health-checks green (verified on machine).
- Record -> transcribe -> insert round-trip verified through the iTerm2 bridge path. The Cmd+V paste path into a non-terminal app is not smoke-tested.
- `mise run release` verified end to end: notarized, stapled, gatekeeper-accepted, installed.

## Conventions
- Code/comments English only. Default dictation language auto-detect; any whisper.cpp language selectable.
- To tear down the daemon for testing: `launchctl bootout gui/$(id -u)/io.binarygap.whisper-server; launchctl disable ...; pkill -9 -f whisper-server` (KeepAlive respawns it otherwise). Label is `io.binarygap.whisper-server`, plist at `~/Library/LaunchAgents/io.binarygap.whisper-server.plist`; the app rewrites it to its own bundled binary on every launch.
- Public repo: pushes are leak-checked by a PreToolUse hook (`.claude/settings.local.json`); run `mise run leak-check --all` before changing visibility or rewriting history.
