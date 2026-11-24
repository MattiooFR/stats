#!/bin/zsh
# Builds the Release app, signs it and replaces /Applications/Stats.app, then starts it again.
#
#   dev-tools/install.sh                 build, sign, install, relaunch
#   SKIP_BUILD=1 dev-tools/install.sh    reuse the Release build already in build/dd
#
# Signature: the "Stats Local" certificate of the login keychain when there is one. It is a self-signed
# code signing certificate; the signature stays the same from one build to the next, so macOS keeps the
# permissions already granted (location for the Wi-Fi name, calendar). Without it the app gets an ad hoc
# signature and those permissions are asked again after every install. SIGN_IDENTITY overrides the name.
#
# The app that was installed before is kept in build/previous/ (ignored by git, safe to empty).
setopt err_exit pipe_fail

ROOT=${0:A:h:h}
APP="$ROOT/build/dd/Build/Products/Release/Stats.app"
TARGET=/Applications/Stats.app
IDENTITY=${SIGN_IDENTITY:-Stats Local}

if [ -z "${SKIP_BUILD:-}" ]; then
  LOG="$ROOT/build/install-build.log"
  mkdir -p "$ROOT/build"
  xcodebuild -project "$ROOT/Stats.xcodeproj" -scheme Stats -configuration Release -derivedDataPath "$ROOT/build/dd" \
    -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES build > "$LOG" 2>&1 || true
  if ! /usr/bin/grep -q "BUILD SUCCEEDED" "$LOG"; then
    /usr/bin/grep -E "error:" "$LOG" | head -20
    echo "build failed, nothing installed (full log: $LOG)"
    exit 1
  fi
  echo "build succeeded"
fi
if [ ! -d "$APP" ]; then
  echo "no Release build at $APP"
  exit 1
fi

if security find-identity -p codesigning | /usr/bin/grep -q "\"$IDENTITY\""; then
  echo "signing with the \"$IDENTITY\" certificate"
  codesign --force --deep --sign "$IDENTITY" "$APP" 2> /dev/null
else
  echo "no \"$IDENTITY\" certificate in the keychain: ad hoc signature, the permissions will be asked again"
  codesign --force --deep --sign - "$APP" 2> /dev/null
fi
codesign --verify --deep --strict "$APP"

osascript -e 'tell application id "eu.exelban.Stats" to quit' > /dev/null 2>&1 || true
for i in {1..20}; do
  pgrep -f "$TARGET/Contents/MacOS/Stats" > /dev/null || break
  /bin/sleep 0.5
done
if pgrep -f "$TARGET/Contents/MacOS/Stats" > /dev/null; then
  echo "Stats is still running, nothing installed"
  exit 1
fi

if [ -d "$TARGET" ]; then
  mkdir -p "$ROOT/build/previous"
  mv "$TARGET" "$ROOT/build/previous/Stats-$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$APP" "$TARGET"
codesign --verify --deep --strict "$TARGET"
open "$TARGET"

echo "installed, signed by: $(codesign -dv --verbose=2 "$TARGET" 2>&1 | /usr/bin/grep -E '^Authority=|^Signature=' | head -1)"
echo "requirement: $(codesign -d -r- "$TARGET" 2>&1 | /usr/bin/grep '^designated' | cut -c1-140)"
