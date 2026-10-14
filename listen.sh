#!/bin/zsh
# Usage: ./listen.sh [seconds]  — records from the default mic, then transcribes with whisper.cpp
cd "${0:A:h}"
SECS=${1:-8}
./rec /tmp/listen.caf "$SECS" | grep -v "Input format"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/listen.caf /tmp/listen.wav
./whisper.cpp/build/bin/whisper-cli -m models/ggml-base.en.bin -f /tmp/listen.wav -nt 2>/dev/null
