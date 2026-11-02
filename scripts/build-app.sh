#!/bin/bash
# Builds build/iMessager.app.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --run      build and launch
#   scripts/build-app.sh --install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/iMessager.app"

swift build -c release --product iMessager
BIN="$(swift build -c release --show-bin-path)/iMessager"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iMessager"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Logo assets come from Support/Brand (regenerate with scripts/make-brand.py).
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for name in MenuBarIcon Bubble Wordmark; do
  cp "Support/Brand/$name.png" "Support/Brand/$name@2x.png" "$APP/Contents/Resources/"
done
# Provider marks (Claude, OpenAI from Simple Icons; OpenRouter from LobeHub Icons), shown on the auto-reply button.
cp Support/Brand/Providers/*.png "$APP/Contents/Resources/"

# A stable signing identity lets macOS remember Full Disk Access, Contacts and Automation across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" --identifier com.lithometric.imessager "$APP"; then
  echo "Built $APP (signed with: $IDENTITY)"
else
  codesign --force --sign - --identifier com.lithometric.imessager "$APP"
  echo "Built $APP (ad-hoc signed: macOS may ask for permissions again after each rebuild)"
fi

quit_running() {
  pkill -x iMessager 2>/dev/null || return 0
  for _ in {1..50}; do pgrep -x iMessager >/dev/null || break; sleep 0.1; done
}

# LaunchServices can briefly still think the old copy is running, so retry.
launch() {
  for _ in {1..10}; do open "$1" 2>/dev/null && return 0; sleep 0.3; done
  open "$1"
}

case "${1:-}" in
  --install)
    quit_running
    rm -rf /Applications/iMessager.app
    cp -R "$APP" /Applications/
    launch /Applications/iMessager.app
    echo "Installed to /Applications/iMessager.app"
    ;;
  --run)
    quit_running
    launch "$APP"
    ;;
esac
