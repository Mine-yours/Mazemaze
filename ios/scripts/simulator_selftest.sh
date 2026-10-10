#!/bin/bash
# iOS シミュレータで、実際の WKWebView・Swift ブリッジ・翻訳サービスを通した自己テストを実行する。
# 翻訳・意味は、固定の答えを返す偽エンジン（-MazemazeFakeEngines 1）を使う（システムのモデルは使わない）。
# テスト用のページは、手元で起動する簡易サーバー（ios/scripts/mock_site_server.py）が配る。外部には通信しない。
# 使い方: ./ios/scripts/simulator_selftest.sh        （Xcode 26 / iOS シミュレータが必要）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# 自分で使っているシミュレータ（アプリの設定が入っている端末）を壊さないよう、専用の別端末を使う。
DEVICE="${SIM_DEVICE:-iPhone 17}"
DD="${DERIVED_DATA:-$(mktemp -d)/dd}"
SITE_PORT=8792
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

echo "== build (Debug, simulator) =="
xcodebuild -project ios/Mazemaze.xcodeproj -scheme Mazemaze -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build >/dev/null
APP="$DD/Build/Products/Debug-iphonesimulator/Mazemaze.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

echo "== start mock site :$SITE_PORT =="
python3 ios/scripts/mock_site_server.py "$SITE_PORT" & PIDS+=($!)
for _ in $(seq 1 50); do curl -s -m 1 "http://127.0.0.1:$SITE_PORT/static.html" >/dev/null && break; sleep 0.2; done

echo "== simulator: $DEVICE =="
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
LOG="$(mktemp)"
set +e
xcrun simctl launch --console --terminate-running-process "$DEVICE" "$BUNDLE_ID" \
  -MazemazeSelfTest 1 -MazemazeAllowLocalhost 1 -MazemazeFakeEngines 1 \
  -MazemazeBackgroundIdle 0 -MazemazeStartURL "http://localhost:$SITE_PORT" 2>&1 | tee "$LOG"
set -e
if ! grep -q "SELFTEST DONE passed=.* failed=0" "$LOG"; then echo "RESULT: FAIL"; exit 1; fi
# Regression: the tab list with "休止中"/"翻訳中" badges must open and close repeatedly without crashing
# (a badge() call once resolved to SwiftUI's View.badge and made the card contain itself forever).
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -MazemazeFakeEngines 1 -MazemazeDemoTabs 3 -MazemazeShowLoop 6 >/dev/null
sleep 20
RUNNING="$(xcrun simctl spawn "$DEVICE" launchctl list 2>/dev/null || true)"
if grep -q "$BUNDLE_ID" <<<"$RUNNING"; then echo "OK: the tab list opened and closed 6 times without a crash"; else echo "FAIL: the app crashed while the tab list was shown"; exit 1; fi
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
echo "RESULT: PASS"
