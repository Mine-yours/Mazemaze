#!/bin/bash
# 翻訳待ち時間の計測（実 Ollama・実ページ、専用シミュレータ）。ページ本文は出力せず、時間と件数だけを表示する。
# 使い方: ios/scripts/bench.sh <ページの URL> [秒数=90]        COLD=1 を付けるとモデルをいったん降ろして冷えた状態から測る
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
URL="${1:?URL を指定してください}"; SECS="${2:-90}"
DEVICE="${SIM_DEVICE:-iPhone 17}"; DD="${DERIVED_DATA:-$(mktemp -d)/dd}"; PORT=8801; TOKEN="bench-$$"
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
PIDS=(); cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; xcrun simctl shutdown "$DEVICE" 2>/dev/null || true; }; trap cleanup EXIT
xcodebuild -project ios/Mazemaze.xcodeproj -scheme Mazemaze -sdk iphonesimulator -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build >/dev/null
APP="$DD/Build/Products/Debug-iphonesimulator/Mazemaze.app"; BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
if [ "${COLD:-}" = "1" ]; then ollama stop "${MAZEMAZE_MODEL:-qwen3.5:9b}" >/dev/null 2>&1 || true; sleep 2; echo "(モデルを降ろして冷えた状態から測定)"; else echo "(モデルは温まっている想定)"; fi
MAZEMAZE_ALLOW_LAN=1 MAZEMAZE_TOKEN="$TOKEN" .venv/bin/python -m uvicorn backend.app:app_factory --factory --host 0.0.0.0 --port "$PORT" --no-proxy-headers --no-server-header >/dev/null 2>&1 & PIDS+=($!)
for _ in $(seq 1 50); do curl -s -m 1 -H "X-Mazemaze-Token: $TOKEN" "http://127.0.0.1:$PORT/api/status" >/dev/null && break; sleep 0.2; done
xcrun simctl boot "$DEVICE" 2>/dev/null || true; xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$APP"; xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch --console --terminate-running-process "$DEVICE" "$BUNDLE_ID" -MazemazeBench 1 -MazemazeBenchSeconds "$SECS" \
  -MazemazeAPI "http://$IP:$PORT" -MazemazeToken "$TOKEN" -MazemazeInitialURL "$URL" 2>&1 | grep -E "^BENCH"
