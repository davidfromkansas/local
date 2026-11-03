#!/usr/bin/env bash
# Regenerates the ASR accuracy clips with macOS `say` (16 kHz mono 16-bit WAV).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Tests/TakiTests/Clips
mkdir -p "$OUT"
python3 - "$OUT" <<'PY'
import json, subprocess, sys, os
out = sys.argv[1]
clips = [
  ("01-meeting", "Samantha", "Can we move the team meeting to Thursday at 3 PM?"),
  ("02-grocery", "Daniel", "Please pick up eggs, milk, and two loaves of bread on your way home."),
  ("03-numbers", "Samantha", "The invoice total is 482 dollars and it is due on March 15th."),
  ("04-names", "Karen", "Tell Priya and Marcus that the launch party starts at 7."),
  ("05-correction", "Samantha", "Let's meet at 5, actually I mean 6."),
  ("06-question", "Daniel", "Did you remember to send the slides to the client this morning?"),
  ("07-address", "Samantha", "My new address is 1726 Anza Street in San Francisco."),
  ("08-long", "Karen", "I think the new design looks great, but the buttons feel a little small on the phone, so let's make them bigger before we ship."),
  ("09-filler", "Samantha", "Um, so I was thinking we could, uh, try the new ramen place tonight."),
  ("10-tech", "Daniel", "The app runs speech recognition on the device, so it works without an internet connection."),
]
manifest = []
for name, voice, text in clips:
    aiff = os.path.join(out, name + ".aiff")
    wav = os.path.join(out, name + ".wav")
    subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True)
    os.remove(aiff)
    manifest.append({"file": name + ".wav", "voice": voice, "reference": text})
json.dump(manifest, open(os.path.join(out, "clips.json"), "w"), indent=2)
PY
cp "$OUT/05-correction.wav" App/Resources/debug-feed.wav
echo "Wrote $(ls "$OUT"/*.wav | wc -l | tr -d ' ') clips to $OUT"
