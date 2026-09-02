#!/usr/bin/env bash
#
# Build and test WhisperKey (macOS), and print what ran.
#
# Usage:
#   scripts/verify.sh        package build + package tests + app build
#   scripts/verify.sh -b     builds only, no tests
#   scripts/verify.sh -t     package tests only
#   scripts/verify.sh -c     clean the app's derived data first
#
# This is the only place these commands live. README, CLAUDE.md and CI all call
# this script rather than repeating them — see ~/PersonalProjects/AGENTS.md,
# "One recipe, one home".
#
# Exit code is 0 only when every step succeeded.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

DERIVED="build/verify"
DO_CLEAN=0
DO_BUILD=1
DO_TEST=1

while getopts "cbth" opt; do
  case "$opt" in
    c) DO_CLEAN=1 ;;
    b) DO_TEST=0 ;;
    t) DO_BUILD=0 ;;
    h) sed -n '2,15p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

mkdir -p "$DERIVED"
PKG_LOG="$DERIVED/package.log"
APP_LOG="$DERIVED/app.log"

echo "----------------------------------------------------------------"

# --- swift package -----------------------------------------------------------
if [ "$DO_BUILD" = 1 ]; then
  START=$SECONDS
  swift build >"$PKG_LOG" 2>&1
  if [ $? != 0 ]; then
    echo "PACKAGE BUILD FAILED"
    grep -E "error:" "$PKG_LOG" | sort -u | head -40
    exit 1
  fi
  echo "swift build ok, $((SECONDS - START))s"
fi

if [ "$DO_TEST" = 1 ]; then
  START=$SECONDS
  swift test >"$PKG_LOG" 2>&1
  STATUS=$?
  EXECUTED="$(grep -E "Executed [0-9]+ test" "$PKG_LOG" | tail -1)"
  echo "swift test  $((SECONDS - START))s — ${EXECUTED:-no test summary found}"
  if [ "$STATUS" != 0 ]; then
    echo "FAILURES:"
    grep -E "error:|failed" "$PKG_LOG" | sort -u | head -40
    echo "(full log: $PKG_LOG)"
    exit 1
  fi
fi

# --- xcode app ---------------------------------------------------------------
if [ "$DO_BUILD" = 1 ]; then
  [ "$DO_CLEAN" = 1 ] && rm -rf "$DERIVED/Build" "$DERIVED/ModuleCache.noindex"
  START=$SECONDS
  # The scheme carries an "Install to /Applications" build phase that exits
  # early when CI=true, which GitHub Actions sets for itself. Locally the phase
  # runs and fails, because CODE_SIGNING_ALLOWED=NO leaves the app unsigned.
  # Setting this reproduces exactly what CI builds — it does not skip a check
  # that CI performs, because CI skips it too.
  export WHISPERKEY_SKIP_APPLICATIONS_INSTALL=1
  xcodebuild \
    -project WhisperKey.xcodeproj \
    -scheme WhisperKey \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$APP_LOG" 2>&1
  if [ $? != 0 ]; then
    echo "APP BUILD FAILED after $((SECONDS - START))s"
    grep -E "error:" "$APP_LOG" | sort -u | head -40
    exit 1
  fi
  WARNINGS=$(grep -E "warning:" "$APP_LOG" | sed 's/^ *//' | sort -u | wc -l | tr -d ' ')
  echo "app build   ok, $((SECONDS - START))s, ${WARNINGS} warnings"
  if [ "$DO_CLEAN" != 1 ]; then
    echo "            INCREMENTAL — only recompiled files re-emit warnings."
  fi
fi
echo "----------------------------------------------------------------"
