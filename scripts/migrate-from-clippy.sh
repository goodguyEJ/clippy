#!/bin/zsh
# One-off: moves history and settings from the pre-1.0 "Clippy" builds to ClipStack.
# Safe to run more than once; it never overwrites existing ClipStack data and never deletes the old settings.
set -euo pipefail

OLD_DIR="$HOME/Library/Application Support/Clippy"
NEW_DIR="$HOME/Library/Application Support/ClipStack"
OLD_DOMAIN="local.personal.clippy"
NEW_DOMAIN="io.github.goodguyej.clipstack"

for id in "$OLD_DOMAIN" "$NEW_DOMAIN"; do
  osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
done
sleep 1
if pgrep -xq Clippy || pgrep -xq ClipStack; then
  echo "Clippy or ClipStack is still running. Quit it from its menu bar icon, then run this again."
  exit 1
fi

if [ -d "$NEW_DIR" ]; then
  echo "History: $NEW_DIR already exists, left as is."
  if [ -d "$OLD_DIR" ]; then echo "         Your old history is still in $OLD_DIR."; fi
elif [ -d "$OLD_DIR" ]; then
  mv "$OLD_DIR" "$NEW_DIR"
  echo "History: moved to $NEW_DIR"
else
  echo "History: nothing to move."
fi

if defaults read "$NEW_DOMAIN" >/dev/null 2>&1; then
  echo "Settings: $NEW_DOMAIN already has settings, left as is."
elif defaults read "$OLD_DOMAIN" >/dev/null 2>&1; then
  defaults export "$OLD_DOMAIN" - | defaults import "$NEW_DOMAIN" -
  echo "Settings: copied to $NEW_DOMAIN"
  echo "When ClipStack works, you can remove the old settings with: defaults delete $OLD_DOMAIN"
else
  echo "Settings: nothing to copy."
fi
