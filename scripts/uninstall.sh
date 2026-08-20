#!/bin/bash
# Remove JBar. Flags: --purge (also remove config/cache/history), --yes (no prompt).
set -euo pipefail
PURGE=0; ASSUME_YES=0
for a in "$@"; do case "$a" in --purge) PURGE=1;; --yes|-y) ASSUME_YES=1;; esac; done

for APP in "/Applications/JBar.app" "$HOME/Applications/JBar.app"; do
  [ -e "$APP" ] || continue
  # Unregister the login item via the bundle's own CLI before deleting it.
  "$APP/Contents/MacOS/JBar" --unregister-login-item >/dev/null 2>&1 || true
done

osascript -e 'tell application "JBar" to quit' >/dev/null 2>&1 || true
pkill -f "JBar.app/Contents/MacOS/JBar" >/dev/null 2>&1 || true
sleep 1

rm -rf "/Applications/JBar.app" "$HOME/Applications/JBar.app"
echo "Removed JBar.app."

if [ "$PURGE" -eq 1 ]; then
  if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Also delete config, cache and history? [y/N] " ans
    case "$ans" in y|Y) ;; *) echo "Kept user data."; exit 0;; esac
  fi
  rm -rf "$HOME/.config/jbar" "$HOME/Library/Caches/com.linji.jbar" "$HOME/Library/Application Support/JBar"
  echo "Removed config, cache and history."
fi
