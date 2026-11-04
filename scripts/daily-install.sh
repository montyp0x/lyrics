#!/bin/bash
# Install Lyrics on the iPhone once a day, whenever it is on this Mac's Wi-Fi. Installing works
# on a locked phone; the app is launched afterwards if the phone is unlocked.
# The LaunchAgent scripts/com.ramych.lyrics.daily-install.plist starts this every 15 minutes
# in the user's login session, where codesign can use the login keychain. (Cron can't:
# it runs outside that session, and `launchctl asuser` there needs root.)
# After a successful install, today's stamp makes later runs return immediately.
# LYRICS_INSTALL_CHECK=1 runs only the checks and prints the result.

REPO="/Users/ramych/prjs/lyrics"
DEVICE="00008130-0014081C0E9A001C"
BUNDLE="com.ramych.lyrics"
HOME="${HOME:-/Users/ramych}"
SUPPORT="$HOME/Library/Application Support/Lyrics"
LOGDIR="$HOME/Library/Logs/Lyrics"
LOG="$LOGDIR/daily-install.log"
STAMP="$SUPPORT/last-daily-install"
TICK="$SUPPORT/daily-install-last-tick"
REASON="$SUPPORT/daily-install-wait-reason"
LOCK="$SUPPORT/daily-install.lockdir"
DERIVED="$REPO/build/daily-install"
APP="$DERIVED/Build/Products/Debug-iphoneos/Lyrics.app"

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$SUPPORT" "$LOGDIR"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

note() {
  local prev=""
  if [ -f "$REASON" ]; then
    prev=$(cat "$REASON")
  fi
  if [ "$prev" != "$1" ]; then
    log "$1"
    printf '%s\n' "$1" > "$REASON"
  fi
  if [ -n "${LYRICS_INSTALL_CHECK:-}" ]; then
    printf '%s\n' "$1"
  fi
}

date +%s > "$TICK"

if [ -z "${LYRICS_INSTALL_CHECK:-}" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$(date +%Y-%m-%d)" ]; then
  exit 0
fi

if [ -d "$LOCK" ]; then
  now=$(date +%s)
  old=$(stat -f %m "$LOCK")
  if [ $((now - old)) -lt 1800 ]; then
    note "already running"
    exit 0
  fi
  rmdir "$LOCK" 2>/dev/null || true
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -d "$LOCK" ]; then
    note "already running"
  else
    log "could not create $LOCK"
  fi
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

if [ -f "$LOG" ]; then
  size=$(stat -f %z "$LOG")
  if [ "$size" -gt 200000 ]; then
    mv "$LOG" "$LOGDIR/daily-install.old.log"
  fi
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/lyrics-daily.XXXXXX")
trap 'rmdir "$LOCK" 2>/dev/null || true; rm -rf "$TMP"' EXIT

run_devicectl() {
  xcrun devicectl --timeout 25 --json-output "$1" device info "$2" --device "$DEVICE" >/dev/null 2>"$TMP/devicectl.err"
}

# Prints "ready" or "wait <reason>".
judge() {
  /usr/bin/python3 - "$1" "$2" << 'PY'
import json, sys
path, kind = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    print("wait not-on-network")
    sys.exit(0)
if data.get("info", {}).get("outcome") != "success":
    print("wait not-on-network")
    sys.exit(0)
result = data.get("result") or {}
if kind == "lock":
    if result.get("unlockedSinceBoot") is True:
        print("ready")
    else:
        print("wait not-unlocked")
else:
    print("wait bad-check")
PY
}

# lockState opens the Wi-Fi tunnel itself and fails when the phone is unreachable.
# `details` only reports the tunnel's current state, which is down until something opens it.
run_devicectl "$TMP/lock.json" lockState || true
gate=$(judge "$TMP/lock.json" lock)
if [ "$gate" != "ready" ]; then
  note "$gate"
  exit 0
fi

if [ -n "${LYRICS_INSTALL_CHECK:-}" ]; then
  note "ready to install"
  exit 0
fi

log "installing"
cd "$REPO" || exit 1
if ! xcodegen generate >"$TMP/xcodegen.txt" 2>&1; then
  log "xcodegen failed"
  tail -n 20 "$TMP/xcodegen.txt" | while IFS= read -r line; do
    log "xcodegen: $line"
  done
  exit 1
fi

xcodebuild -project "$REPO/Lyrics.xcodeproj" -scheme Lyrics -destination "id=$DEVICE" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates build >"$TMP/build.txt" 2>&1
if ! grep -q "BUILD SUCCEEDED" "$TMP/build.txt"; then
  log "build failed"
  grep -E "error:|BUILD FAILED" "$TMP/build.txt" | tail -n 30 | while IFS= read -r line; do
    log "build: $line"
  done
  exit 1
fi

if ! xcrun devicectl --timeout 180 device install app --device "$DEVICE" "$APP" >"$TMP/install.txt" 2>&1; then
  log "install failed"
  tail -n 30 "$TMP/install.txt" | while IFS= read -r line; do
    log "install: $line"
  done
  exit 1
fi

launched=0
i=1
while [ "$i" -le 6 ]; do
  if xcrun devicectl --timeout 30 device process launch --terminate-existing \
    --device "$DEVICE" "$BUNDLE" >"$TMP/launch.txt" 2>&1; then
    launched=1
    break
  fi
  # Right after an install, iOS refuses to launch with "Security" until it has
  # verified the new profile with Apple.
  if grep -q -e "Locked" -e "BSErrorCodeDescription = Security" "$TMP/launch.txt"; then
    sleep 10
    i=$((i + 1))
    continue
  fi
  break
done

date +%Y-%m-%d > "$STAMP"
rm -f "$REASON"
if [ "$launched" -eq 1 ]; then
  log "installed and launched"
elif grep -q "Locked" "$TMP/launch.txt"; then
  log "installed; phone locked, so the app was not launched"
else
  log "installed; launch failed"
  tail -n 15 "$TMP/launch.txt" | while IFS= read -r line; do
    log "launch: $line"
  done
fi
