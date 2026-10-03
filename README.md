# whisper-native

Menu-bar dictation for macOS. Tap a hotkey, speak, and the
transcribed text lands at the cursor. Runs as a background agent (no Dock
icon). Two local transcription engines: whisper.cpp (`large-v3-turbo`,
running as a warm `launchd` daemon so there's no cold-start delay) and
Parakeet TDT v3 (runs in-process via FluidAudio, faster, with a live
transcript pill while you talk). Fully offline once the models are
downloaded.

**Requirements:** Apple Silicon, macOS 26 (Tahoe) or later.

## Features

- First-run setup guide (engine, model download, permissions, hotkeys, language), skippable and reopenable from the menu bar
- Toggle hotkey: tap a lone modifier (Fn by default) or any shortcut
- Language cycling (Option+Tab) through the languages you pick, any of whisper.cpp's ~100 plus auto-detect
- Live transcript pill while recording (Parakeet engine)
- Filler-word removal (uh, hmm, um)
- Optional line wrapping / sentence-per-line output
- Transcription history
- iTerm2 integration: text goes to the session you started recording in, with optional auto-submit

## Install

Download the latest `.dmg` from
[Releases](https://github.com/Binary-Gap/whisper-native/releases), open it, and
drag WhisperNative into Applications.

Or via Homebrew:

```sh
brew install --cask binary-gap/tap/whisper-native
```

## Build from source requirements

- macOS 26 or later
- Xcode 26 or later
- [mise](https://mise.jdx.dev)
- [xcodegen](https://github.com/yonaskolb/XcodeGen)
- cmake (needed to build the bundled whisper.cpp server)

The app needs Microphone access (to record) and Accessibility access (to
paste the transcribed text via a synthesized Cmd+V). macOS will prompt for
both on first use.

## Build & run

```sh
# First time, or after adding/moving source files
mise run generate

# Build (also clones and builds whisper.cpp into external/ on first run)
mise run build

# Launch
mise run run

# Run tests
mise run test
```

If `cmake` fails with a "tapi error: malformed file" during the whisper.cpp
build, it picked up the wrong SDK; prefix the build with
`SDKROOT=$(xcrun --sdk macosx --show-sdk-path)`.

For a signed build, create a gitignored `mise.local.toml`:

```toml
[env]
APPLE_TEAM_ID = "YOUR_TEAM_ID"
DEBUG_SIGN_IDENTITY = "Apple Development"
```

## First run

Models download automatically the first time each engine is used. The
whisper engine (the default) downloads `large-v3-turbo` (~1.6 GB) into
`~/Library/Application Support/whisper-native/models/` on first launch. If
you switch to Parakeet, it downloads ~500 MB into
`~/Library/Application Support/FluidAudio/Models`. Grant the Microphone and
Accessibility prompts when macOS shows them.

If you rebuild the app with a different code signature (for example
switching between a Debug build and your own signed build), macOS treats it
as a different app for permissions purposes even though the bundle ID is the
same. Paste will silently stop working; reset and re-grant Accessibility:

```sh
tccutil reset Accessibility io.binarygap.whisper-native
```

## iTerm2 (optional)

Out of the box, dictation into iTerm2 uses the same Cmd+V paste as any other
app. The iTerm2 integration sends the text straight to the session you
started recording in (even if you switch windows while it transcribes) and
can press Enter for you (Settings > Transcription > "Auto-submit in
terminal"). It talks to iTerm2's Python API, so it needs:

1. iTerm2 > Settings > General > Magic > **Enable Python API**.
2. The `iterm2` Python package in the interpreter the app uses: `python3`
   from [mise](https://mise.jdx.dev) if installed, else `/usr/bin/python3`:

   ```sh
   python3 -m pip install --user iterm2
   ```

If either is missing, the app falls back to paste.

## Uninstall

Quitting the app boots the whisper-server daemon out of `launchd`. Removing
the app from Applications is enough for most cases.

If you installed via Homebrew and also want to remove models, logs and
settings:

```sh
brew uninstall --zap --cask whisper-native
```

Or by hand:

- `~/Library/Application Support/whisper-native`
- `~/Library/Application Support/FluidAudio`
- `~/Library/Logs/whisper-native`
- `~/Library/LaunchAgents/io.binarygap.whisper-server.plist`
- `~/Library/Preferences/io.binarygap.whisper-native.plist`

## Architecture

Two targets: `WhisperNative` (the menu-bar app: hotkeys, settings, app
lifecycle) and `WhisperNativeCore` (a framework holding everything else).
Pipeline: hotkey press starts the audio recorder, which hands the recording
to a transcription backend (whisper.cpp or Parakeet), whose output goes
through a text inserter that pastes it at the cursor. See `CLAUDE.md` for
the full module map.

## License

MIT, see LICENSE. Third-party licenses in THIRD_PARTY_NOTICES.md.
