#!/bin/bash
# 設定（URL・トークン・証明書の指紋）・お気に入り・タブが、アプリの再起動／更新インストール／入れ直しで残るかを、
# 専用のシミュレータ（既定 iPhone 17）で実際に確かめる。Keychain を使うため、署名つき（ad hoc）でビルドする。
# 使い方: ./ios/scripts/persistence_test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
DEVICE="${SIM_DEVICE:-iPhone 17}"; DD="${DERIVED_DATA:-$(mktemp -d)/dd}"
trap 'xcrun simctl shutdown "$DEVICE" 2>/dev/null || true' EXIT
xcodebuild -project ios/Mazemaze.xcodeproj -scheme Mazemaze -sdk iphonesimulator -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$DD" build >/dev/null
APP="$DD/Build/Products/Debug-iphonesimulator/Mazemaze.app"; BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl boot "$DEVICE" 2>/dev/null || true; xcrun simctl bootstatus "$DEVICE" -b >/dev/null
run() { xcrun simctl launch --console --terminate-running-process "$DEVICE" "$BID" -MazemazePersistTest "$1" 2>&1 | grep -E "^PERSIST" || echo "PERSIST (no output)"; }
xcrun simctl uninstall "$DEVICE" "$BID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
echo "1) 新しいインストールに書き込む:";            run write
echo "2) アプリを終了して起動し直し（再起動）:";      run read
echo "3) 同じアプリを上書きインストール（Xcode の ▶ と同じ。書き込みの 10 秒後）:"; sleep 10; xcrun simctl install "$DEVICE" "$APP"; run read
echo "4) アンインストールして入れ直し:";            xcrun simctl uninstall "$DEVICE" "$BID"; xcrun simctl install "$DEVICE" "$APP"; run read
