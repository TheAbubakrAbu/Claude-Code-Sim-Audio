#!/usr/bin/env bash
# Builds and signs "Claude Sim Audio.app" (the simulator audio guard and the `simaudio` CLI).
#   ./build.sh                    build into ~/.claude/sim-audio
#   ./build.sh --out DIR          build into DIR instead (never inside this folder)
#   ./build.sh --identity ID      sign with this certificate (its name or SHA-1)
#
# Signing with the same Apple Development certificate every time keeps the macOS audio
# recording permission across rebuilds; an ad hoc signature loses it on every rebuild. The
# identity is --identity, else $SIM_AUDIO_SIGN_IDENTITY, else the one the last build in DIR
# used (DIR/signing-identity), else ad hoc. `security find-identity -v -p codesigning` lists
# yours.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HOME/.claude/sim-audio"
IDENTITY="${SIM_AUDIO_SIGN_IDENTITY:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

OUT="${OUT/#\~/$HOME}"
# Build output stays out of the source folder (it may live in iCloud or another synced folder).
inside="$(python3 -c 'import os,sys; o,h=(os.path.realpath(p) for p in sys.argv[1:]); print(int(o==h or o.startswith(h+os.sep)))' "$OUT" "$HERE")"
if [ "$inside" = 1 ]; then
  echo "refusing to build inside the source folder ($OUT); pick another --out" >&2
  exit 2
fi

APP="Claude Sim Audio.app"
mkdir -p "$OUT"
if [ -z "$IDENTITY" ] && [ -s "$OUT/signing-identity" ]; then
  IDENTITY="$(head -n 1 "$OUT/signing-identity")"
fi

# Build into a staging copy and swap it in at the end, so a failed build never breaks the
# installed guard and a running guard keeps working until it is restarted.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$APP"
mkdir -p "$STAGE/Contents/MacOS"
cp "$HERE/src/Info.plist" "$STAGE/Contents/Info.plist"
xcrun clang -fobjc-arc -O2 -mmacosx-version-min=26.0 -c "$HERE/src/router.m" -o "$WORK/router.o"
xcrun swiftc -O -swift-version 5 -import-objc-header "$HERE/src/router.h" \
  -o "$STAGE/Contents/MacOS/claude-sim-audio" "$HERE/src/main.swift" "$WORK/router.o" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$HERE/src/Info.plist"

# The test sound `simaudio doctor` plays inside a simulator (an iOS-simulator program, not a Mac one).
mkdir -p "$STAGE/Contents/Resources"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator -O2 "$HERE/src/simtone.c" \
  -framework AudioToolbox -o "$STAGE/Contents/Resources/simtone"

signed=0
if [ -n "$IDENTITY" ]; then
  if codesign --force --sign "$IDENTITY" --identifier local.claude.sim-audio "$STAGE" 2>/dev/null; then
    signed=1
    printf '%s\n' "$IDENTITY" > "$OUT/signing-identity"
  else
    echo "Signing with that identity failed; signing ad hoc (the audio permission resets on each rebuild)." >&2
  fi
else
  echo "No signing identity given; signing ad hoc (the audio permission resets on each rebuild)." >&2
  echo "Pass --identity or set SIM_AUDIO_SIGN_IDENTITY to keep it. See the README." >&2
fi
if [ "$signed" = 0 ]; then
  codesign --force --sign - --identifier local.claude.sim-audio "$STAGE"
fi
codesign -dv "$STAGE" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature=adhoc" || true

rm -rf "${OUT:?}/$APP"
mv "$STAGE" "$OUT/$APP"
echo "Built $OUT/$APP"
echo "Restart the guard to use it: simaudio restart"
