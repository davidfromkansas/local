# AGENTS.md — Taki

Taki is an offline, Wispr Flow-style voice keyboard for iPhone (iOS 26+, Swift 6, SwiftUI). You dictate in any app via the Taki keyboard; speech-to-text runs 100% on-device (FluidAudio + Parakeet on Core ML), then light cleanup. No network after the one-time model download.

## Layout
| Path | What |
|---|---|
| `project.yml` | XcodeGen spec (source of truth). `Taki.xcodeproj` is generated **and committed** — regenerate after editing: `xcodegen generate`. |
| `Config/Base.xcconfig` | Bundle IDs, App Group, `DEVELOPMENT_TEAM`, version. Change branding/signing here only. |
| `App/` | Main app `Taki` (`com.davidfromkansas.taki`): hot mic, ASR, history, dictionary, settings, onboarding. |
| `Keyboard/` | Keyboard extension `TakiKeyboard` (`…taki.keyboard`, `RequestsOpenAccess = YES`). UI + `textDocumentProxy` only. |
| `Shared/` | SwiftUI compiled into both targets (`MicOrb`, `LevelWaveform`, theme). |
| `Packages/TakiKit` | `TakiCore` (pure logic: IPC, `SessionMachine`, `TextCleaner`, WER; linked by both targets) and `TakiEngine` (FluidAudio ASR + Foundation Models cleanup; **app only**). |
| `Tests/TakiTests` | App-hosted tests incl. the ASR accuracy test and its `say` clips (`scripts/make-clips.sh`). |
| `.agents/skills/` | Vendored Emil Kowalski design skills (MIT). Read them before UI work; run `review-animations` + `break-ui` on UI changes. |

## Architecture (hot mic)
Keyboard extensions **cannot use the microphone** and have a tight memory limit (~50–70 MB), so all audio + models live in the main app. Never link `TakiEngine`/FluidAudio into the keyboard.

1. Keyboard mic tap with no live session → opens `taki://start` (SwiftUI `openURL` from the keyboard view; requires Full Access).
2. App (`HotMicController`) activates `AVAudioSession(.playAndRecord, .measurement, [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker])`, starts `AVAudioEngine` with an input tap in **armed** mode (buffers dropped). `UIBackgroundModes=audio` keeps it alive in the background. Shows "Swipe back to continue". Session stays on until the user ends it (default "Never"; an idle timeout can be set in Settings).
3. Next keyboard taps post Darwin notifications `start`/`stop`; app flips to **capturing** (16 kHz mono Float32 via `CaptureContext`, on the audio thread).
4. **Live text**: while capturing, `LiveTranscriber` re-transcribes every ~300 ms and the app writes `partial.json` + posts `partialReady`; the keyboard types it into the field and edits only the changed ending (`TextEdit`). Older speech is cut at a pause (`SpeechSegmenter`, 8–14 s) and kept, so each pass only re-runs the newest < 15 s (one encoder window).
5. On stop: final pass over the last bit of audio → rules cleanup → `result.json` + `resultReady` → back to armed right away. Then the Foundation Models polish runs; if it changes the text, a second `result.json` for the same request replaces it in the field. The keyboard only edits text that still sits right before the cursor.

States are a pure value type: `SessionMachine` (inactive → armed → capturing → processing → armed). Keyboard shows `KeyboardUIState` notReady / ready / recording / processing.

Keyboard layout (`Keyboard/KeyboardView.swift`): standard iOS-style QWERTY (shift/caps lock, 123/#+= layers, hold-to-repeat delete, globe only when `needsInputModeSwitchKey`, return label from `returnKeyType`, letter popups, light/dark). Every key press-down plays a light haptic + system click (`KeyFeedback`; haptics need Full Access). The Taki mic sits **centered on its own row above the keys** (`MicRow`: status left, waveform right) — David's spec, keep it there.

## IPC protocol (App Group `group.com.davidfromkansas.taki`)
Darwin notifications carry **no payload**, only names `com.davidfromkansas.taki.<signal>`: `start`, `stop`, `cancel` (keyboard → app), `stateChanged`, `partialReady`, `resultReady` (app → keyboard). Data is atomic files in the App Group container (`SharedStore`; files, not UserDefaults, for cross-process freshness):
- `session.json` — `SessionSnapshot` {phase, expiresAt, updatedAt, errorMessage}
- `request.json` — `DictationRequest` {id} written by the keyboard before `start`
- `partial.json` — `DictationResult` with live text while capturing
- `result.json` — `DictationResult` {requestID, text}: the final text, then maybe a polished revision; keyboard only edits for its own `requestID`
- `level.bin` — current mic level (Float32 0…1, ~30 Hz) for the keyboard waveform
- `debug-feed.wav` — optional DEBUG audio override (see below)

## ASR + cleanup
- Default model: Parakeet Unified 0.6B English batch (`UnifiedAsrManager`, `FluidInference/parakeet-unified-en-0.6b-coreml`) with **`encoderPrecision: .fp16`** — the int8 encoder fails to load on A16 (FluidAudio #828). Fallback in Settings: Parakeet TDT v2 (`AsrManager`). FluidAudio is pinned to `0.18.2`; read its `Documentation/` before changing APIs.
- Silero VAD trims silence. Compute units `.cpuAndNeuralEngine` — **no GPU** (not allowed in background).
- Models download once to Application Support/Taki/Models (onboarding), then are compiled and kept loaded.
- Cleanup = `TextCleaner` rules (fillers, stutters, "actually I mean" self-corrections, dictionary, punctuation) → optional Apple Foundation Models light edit (`LLMCleaner`), rejected if length ratio is outside 0.6–1.2 → dictionary re-applied.

## Build & test
```bash
brew install xcodegen          # once
scripts/build.sh               # xcodegen + simulator build (warnings are errors)
scripts/build.sh test          # unit tests (TakiCoreTests + TakiTests)
TEST_RUNNER_TAKI_ASR_TESTS=1 scripts/build.sh test   # + ASR WER/latency (downloads ~1 GB once)
cd Packages/TakiKit && swift test                    # fast pure-logic tests on macOS
scripts/testflight.sh          # archive + upload; needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, (TEAM_ID)
```

## Gotchas
- **Simulator has no Neural Engine** → ASR runs on CPU; latency there is not representative of an iPhone 17 Pro.
- **The simulator uses the Mac's microphone.** For machines without one (e.g. the cloud Mac), DEBUG builds have Settings › Developer › "Use test audio instead of mic" (off by default; turn it on there): capture plays `App/Resources/debug-feed.wav` (or `debug-feed.wav` in the App Group) instead of the mic. Excluded from Release.
- Keyboard needs **Allow Full Access** for the App Group + Darwin notifications; without it the keyboard shows a hint.
- Default actor isolation is `MainActor` in the app targets. Audio-thread code (`CaptureContext`) is explicitly `nonisolated` — keep it that way or the tap will trap at runtime.
- Swift Regex doesn't support lookbehind; use `NSRegularExpression` for those patterns (`TextCleaner`).
- Never commit `.p8` keys (`.gitignore` blocks `*.p8`); `testflight.sh` copies the key to `~/.appstoreconnect/private_keys/`.
