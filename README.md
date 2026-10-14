# Mic Log

An always-on, voice-activated recorder for macOS with a local web dashboard.
Whenever the microphone hears something, the clip is recorded, transcribed on-device
with [whisper.cpp](https://github.com/ggml-org/whisper.cpp), and added to a
chronological timeline you can search and play back. Nothing leaves the machine.

## How it works

- **`vad`** (`vad.swift`): listens to the default input with AVAudioEngine and tracks the
  room's noise floor (10th percentile of the last 20 s). Levels are measured in the speech band
  (250 Hz–4 kHz), so rumble, thumps and fans don't count. Sound that stays 12 dB (configurable)
  above the floor for 0.15 s starts a clip, with 0.5 s of pre-roll; 1.5 s of silence ends it. Finished clips go to `recordings/pending/`, and a live level/status
  file is written to `recordings/state.json`.
- **`classify`** (`classify.swift`): labels a clip with Apple's built-in on-device sound classifier
  (SoundAnalysis, ~300 sounds such as speech, music, dog bark, door). Labels are grouped in `sound_groups.json`.
- **`server.py`**: standard-library Python. It converts each pending clip to 16 kHz WAV and classifies it.
  Clips where a sound on your keep list is heard (default: speech-type sounds, ≥ 50% confidence) are
  transcribed with `whisper-cli` (`base.en` model); the rest are kept but hidden and not transcribed. It serves the dashboard and a small JSON API on
  `127.0.0.1:8770`.
- **`dashboard.html`**: newest-first timeline grouped by day, with audio playback, search, a live input
  meter, pause/resume, delete, and a toggle for non-speech clips (e.g. `[BLANK_AUDIO]`, `(music)`).

## Requirements

macOS with Xcode command line tools (`swiftc`), `cmake`, `git`, and Python 3.

## Install

```sh
./install.sh
```

This builds whisper.cpp, downloads the model (~140 MB), builds the recorder, and installs two
launch agents (`com.mic.vad`, `com.mic.server`) that start at login and restart on crash.
Allow the microphone prompt for `mic-vad`, then restart the recorder:

```sh
launchctl kickstart -k gui/$(id -u)/com.mic.vad
```

Open http://localhost:8770. Set `PORT=...` when running `install.sh` to use a different port.

### Accessing it from other devices

The server binds to localhost only. To reach it from your other devices over
[Tailscale](https://tailscale.com), without exposing it to the internet:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:8770
```

## Tuning

Use **Calibrate** on the dashboard: it measures a few seconds of background, then a few seconds of
you talking, and suggests a sensitivity between them (or set it by hand with the slider). It's saved
to `recordings/config.json` and the recorder applies it live, with no rebuild.

Use **Sounds** to choose which sounds make a clip worth keeping. It lists every category the classifier
knows, with how many of your clips contain each one. Changes apply to existing clips too: newly kept
clips are transcribed in the background.

Other constants at the top of `vad.swift`: `hangSec` (silence before a clip ends), `onsetSec`,
`preRollSec`, `maxSec`, `minVoicedSec`. Rebuild with `./install.sh`.

### Keeping the mic permission across rebuilds

macOS remembers the microphone permission per code signature. By default the recorder is ad-hoc
signed, so every rebuild looks like a new app and macOS asks again. To avoid that, create a
local signing certificate once:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `Mic Recorder`, Identity Type: **Self-Signed Root**, Certificate Type: **Code Signing**. Create.
3. In the **Terminal app** (not over SSH or inside another tool, which can't show the key prompt), run
   `touch vad.swift && ./install.sh`. If macOS asks whether `codesign` may use the key, choose
   **Always Allow**. Approve the mic prompt one last time.

`install.sh` signs with that certificate whenever it exists (set `SIGN_ID=...` to use a different name).

## Extras

- `listen.sh [seconds]` with `rec.swift`: one-shot record-and-transcribe from the terminal
  (`swiftc rec.swift -o rec` first).

## Uninstall

```sh
./uninstall.sh
```

Recordings stay in `recordings/` until you delete them.

## Privacy

This records everything the mic hears above the noise floor, including audio played through the
computer's own speakers. Use the dashboard's Pause button when needed, and be mindful of recording
others without their consent.
