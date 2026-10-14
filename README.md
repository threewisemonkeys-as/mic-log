# Mic Log

An always-on, voice-activated recorder for macOS with a local web dashboard.
Whenever the microphone hears something, the clip is recorded, transcribed on-device
with [whisper.cpp](https://github.com/ggml-org/whisper.cpp), and added to a
chronological timeline you can search and play back. Nothing leaves the machine.

## How it works

- **`vad`** (`vad.swift`): listens to the default input with AVAudioEngine and tracks the
  room's noise floor. Sound more than 12 dB above it starts a clip, with 0.5 s of pre-roll;
  1.5 s of silence ends it. Finished clips go to `recordings/pending/`, and a live level/status
  file is written to `recordings/state.json`.
- **`server.py`**: standard-library Python. It converts each pending clip to 16 kHz WAV, transcribes
  it with `whisper-cli` (`base.en` model), and serves the dashboard and a small JSON API on
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

Constants at the top of `vad.swift`: `marginDb` (sensitivity), `hangSec` (silence before a clip ends),
`preRollSec`, `maxSec`, `minVoicedSec`. Rebuild with `./install.sh`; macOS will ask for mic permission
again, because the binary's ad-hoc signature changes.

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
