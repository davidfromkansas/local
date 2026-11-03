# Taki

An offline voice keyboard for iPhone, like Wispr Flow — but speech-to-text runs entirely on the phone, so it works with no internet.

- **Taki keyboard**: tap the mic in any app, talk, and clean text is typed for you.
- **On-device**: Parakeet speech model (via [FluidAudio](https://github.com/FluidInference/FluidAudio)) on the Neural Engine; optional Apple Intelligence polish. Nothing leaves the device.
- **Light cleanup**: drops "um/uh", fixes punctuation, handles "at 5, actually I mean 6" → "at 6", applies your personal dictionary.
- **History** of what you dictated, stored only on the phone.

## Build
```bash
brew install xcodegen
scripts/build.sh        # builds for the iOS Simulator
scripts/build.sh test   # runs the tests
```
Open `Taki.xcodeproj` in Xcode 26+ to run on a device (Team ID lives in `Config/Base.xcconfig`).

See [AGENTS.md](AGENTS.md) for architecture, the keyboard ↔ app protocol, and gotchas.
