# Third-Party Notices

WhisperNative is licensed under the MIT License (see `LICENSE`). It bundles,
links against, or downloads at runtime the following third-party components.

## Bundled

### whisper.cpp
- URL: https://github.com/ggerganov/whisper.cpp
- License: MIT
- Usage: `whisper-server` binary and its `libwhisper`/`libggml*` dylibs are
  built from source at build time and bundled into the app's
  `Contents/Resources` and `Contents/Frameworks`.

## Linked (Swift Package Manager)

### FluidAudio
- URL: https://github.com/FluidInference/FluidAudio
- License: Apache-2.0
- Version: 0.17.4 (pinned in `project.yml`)
- Usage: linked in-process to run the Parakeet TDT v3 speech-to-text backend
  and Silero VAD on the Neural Engine.

### KeyboardShortcuts
- URL: https://github.com/sindresorhus/KeyboardShortcuts
- License: MIT
- Usage: linked for global hotkey recording and persistence.

### Yams
- URL: https://github.com/jpsim/Yams
- License: MIT (includes libyaml, MIT)
- Version: 6.2.2 (pinned in `project.yml`)
- Usage: linked to parse the words file (`words.yml`: Gemini custom vocabulary and stop words) and migrate the older `vocabulary.yml`.

## Downloaded at runtime (not redistributed)

These models are not included in the app or repository. They are downloaded
on demand into local caches (whisper.cpp models and Silero VAD into
`~/Library/Application Support/whisper-native/models/`, Parakeet into
`~/Library/Application Support/FluidAudio/Models`).

### Whisper large-v3-turbo
- URL: https://huggingface.co/ggerganov/whisper.cpp (`ggml-large-v3-turbo.bin`)
- License: MIT (OpenAI)

### Silero VAD
- URL: https://huggingface.co/ggml-org/whisper-vad (`ggml-silero-v6.2.0.bin`)
- License: MIT

### Parakeet TDT v3
- URL: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- Base model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- License: CC-BY-4.0 (NVIDIA)
