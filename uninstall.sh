#!/bin/zsh
# Stops and removes the launch agents. Recordings are left in place.
for name in vad server; do
  plist=~/Library/LaunchAgents/com.mic.$name.plist
  [[ -f $plist ]] && launchctl unload $plist && rm $plist && echo "removed com.mic.$name"
done
