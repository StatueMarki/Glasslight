#!/bin/zsh
# Builds Glasslight.app with an optimized whole-module compile.
#   ./build.sh           build into ./build
#   ./build.sh install   build, copy to ~/Applications and (re)launch
#   ./build.sh test      run the ranking tests
set -euo pipefail
cd "${0:A:h}"

ARCH=$(uname -m)
TARGET="$ARCH-apple-macos26.0"
FLAGS=(-O -wmo -swift-version 5 -target "$TARGET")

if [[ "${1:-}" == "test" ]]; then
  mkdir -p build
  swiftc "${FLAGS[@]}" Sources/Matcher.swift Sources/Usage.swift Sources/AppIndex.swift Sources/DoubleTap.swift Tests/RankingTests/main.swift -o build/ranking-tests
  ./build/ranking-tests
  exit
fi

APP=build/Glasslight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc "${FLAGS[@]}" Sources/*.swift -o "$APP/Contents/MacOS/Glasslight"
# A stable identity keeps the Input Monitoring grant across rebuilds (ad-hoc signatures change
# with every build). Uses the local self-signed "Glasslight Local Signing" identity if present.
if [[ -z "${SIGN_ID:-}" ]]; then
  if security find-identity -p codesigning | grep -q '"Glasslight Local Signing"'; then
    SIGN_ID="Glasslight Local Signing"
  else
    SIGN_ID="-"
  fi
fi
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP (signed: $SIGN_ID)"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/Glasslight.app"
  pkill -x Glasslight 2>/dev/null && sleep 0.3 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
