#!/bin/bash
# iOS シミュレータで、実際の WKWebView・Swift ブリッジ・URLSession・FastAPI（偽の Ollama）を通した
# 自己テストを実行する。Debug ビルドだけに入っているテスト用の起動引数を使う。
# 使い方: ./ios/scripts/simulator_selftest.sh        （Xcode 26 / iOS シミュレータが必要）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
DEVICE="${SIM_DEVICE:-iPhone 17 Pro}"
DD="${DERIVED_DATA:-$(mktemp -d)/dd}"
API_PORT=8791; SITE_PORT=8792; FAKE_PORT=11435
TOKEN="selftest-token-$$"
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
PIDS=()
APILOG="$(mktemp)"
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

echo "== build (Debug, simulator) =="
xcodebuild -project ios/Mazemaze.xcodeproj -scheme Mazemaze -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build >/dev/null
APP="$DD/Build/Products/Debug-iphonesimulator/Mazemaze.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

echo "== start fake Ollama :$FAKE_PORT, Mazemaze API :$API_PORT (LAN mode, token), mock site :$SITE_PORT =="
python3 ios/scripts/fake_ollama.py "$FAKE_PORT" & PIDS+=($!)
python3 ios/scripts/mock_site_server.py "$SITE_PORT" & PIDS+=($!)
MAZEMAZE_ALLOW_LAN=1 MAZEMAZE_TOKEN="$TOKEN" OLLAMA_URL="http://127.0.0.1:$FAKE_PORT" \
  .venv/bin/python -m uvicorn backend.app:app_factory --factory --host 0.0.0.0 --port "$API_PORT" \
  --no-proxy-headers --no-server-header >"$APILOG" 2>&1 & PIDS+=($!)
for _ in $(seq 1 50); do curl -s -m 1 "http://127.0.0.1:$SITE_PORT/static.html" >/dev/null && curl -s -m 1 -H "X-Mazemaze-Token: $TOKEN" "http://127.0.0.1:$API_PORT/api/status" >/dev/null && break; sleep 0.2; done

echo "== simulator: $DEVICE =="
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
LOG="$(mktemp)"
set +e
xcrun simctl launch --console --terminate-running-process "$DEVICE" "$BUNDLE_ID" \
  -MazemazeSelfTest 1 -MazemazeAllowLocalhost 1 -MazemazeAPI "http://$IP:$API_PORT" -MazemazeToken "$TOKEN" \
  -MazemazeStartURL "http://localhost:$SITE_PORT" 2>&1 | tee "$LOG"
set -e
# The server log must not contain any page text (the test pages are full of Japanese sentences).
if python3 -c "import re,sys; sys.exit(0 if re.search(r'[\u3040-\u30ff\u3400-\u9fff]', open(sys.argv[1], encoding='utf-8', errors='replace').read()) else 1)" "$APILOG"; then echo "FAIL: API log contains Japanese text"; exit 1; else echo "OK: API server log contains no Japanese text ($(wc -l < "$APILOG" | tr -d ' ') lines)"; fi
if grep -q "SELFTEST DONE passed=.* failed=0" "$LOG"; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
