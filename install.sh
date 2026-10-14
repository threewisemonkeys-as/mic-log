#!/bin/zsh
# Builds everything and installs launch agents so the recorder and dashboard
# start at login. Re-run safely at any time.
set -e
cd "${0:A:h}"
DIR=$PWD
PORT=${PORT:-8770}
PY=${PYTHON:-$(command -v python3)}

if [[ ! -x whisper.cpp/build/bin/whisper-cli ]]; then
  echo "building whisper.cpp..."
  [[ -d whisper.cpp ]] || git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git
  cmake -S whisper.cpp -B whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DWHISPER_SDL2=OFF > build.log
  cmake --build whisper.cpp/build --target whisper-cli -j >> build.log
fi

if [[ ! -f models/ggml-base.en.bin ]]; then
  echo "downloading model..."
  mkdir -p models
  curl -L -o models/ggml-base.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
fi

# The embedded Info.plist + stable signing identifier let macOS show a
# microphone permission prompt for the launchd-run recorder.
# Note: rebuilding changes the ad-hoc signature, so macOS will ask again.
if [[ ! -x vad || vad.swift -nt vad ]]; then
  echo "building recorder..."
  swiftc -O vad.swift -o vad -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
  codesign -f -s - -i com.mic.vad vad
fi

mkdir -p logs recordings
for name in vad server; do
  if [[ $name == vad ]]; then
    args="<string>$DIR/vad</string><string>$DIR/recordings</string>"
  else
    args="<string>$PY</string><string>$DIR/server.py</string><string>$PORT</string>"
  fi
  plist=~/Library/LaunchAgents/com.mic.$name.plist
  cat > $plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.mic.$name</string>
  <key>ProgramArguments</key><array>$args</array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$DIR/logs/$name.log</string>
  <key>StandardOutPath</key><string>$DIR/logs/$name.log</string>
</dict></plist>
PLIST
  launchctl unload $plist 2>/dev/null || true
  launchctl load $plist
done

echo "dashboard: http://localhost:$PORT"
echo "If macOS asks for microphone access for 'mic-vad', allow it, then run:"
echo "  launchctl kickstart -k gui/\$(id -u)/com.mic.vad"
