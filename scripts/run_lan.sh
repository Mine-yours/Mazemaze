#!/bin/bash
# mazemaze を同じ Wi-Fi/LAN 上のスマホから使えるように起動する（0.0.0.0 で待ち受ける）。
# 信頼できる自宅などの LAN でだけ使ってください。外部公開・ポート転送はしないでください。
# 使い方: ./scripts/run_lan.sh          （アクセストークン付き + 暗号化（自己署名 TLS）で起動し、iPhone 用の QR を表示）
#         MAZEMAZE_TLS=0 ./scripts/run_lan.sh        （暗号化なしの HTTP。古い設定との互換用。非推奨）
#         MAZEMAZE_NO_TOKEN=1 ./scripts/run_lan.sh   （トークンなし。非推奨。QR ペアリングは使えません）
# トークンは .mazemaze_token、証明書は .mazemaze_tls/ に保存され（どちらも Git 管理外）、毎回同じです。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c "import fastapi, uvicorn" 2>/dev/null; then
  echo "仮想環境または依存パッケージがありません。README の「セットアップ」を先に実行してください。" >&2
  exit 1
fi
if ! curl -s -m 3 http://127.0.0.1:11434/api/version >/dev/null; then
  echo "注意: Ollama に接続できません。Ollama アプリを起動してください（確認: ollama list）。" >&2
fi

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [ -z "$IP" ]; then
  echo "この Mac の LAN の IP アドレスを取得できませんでした。Wi-Fi に接続しているか確認してください。" >&2
  exit 1
fi

export MAZEMAZE_ALLOW_LAN=1
if [ "${MAZEMAZE_NO_TOKEN:-}" = "1" ] && [ "${MAZEMAZE_TLS:-}" != "0" ]; then
  echo "注意: トークンなしでは QR ペアリング（暗号化）が使えないため、暗号化なし（HTTP）で起動します。" >&2
  MAZEMAZE_TLS=0
fi
if [ "${MAZEMAZE_NO_TOKEN:-}" = "1" ]; then
  unset MAZEMAZE_TOKEN || true
  SUFFIX=""
  echo "警告: アクセストークンなしで LAN に公開します。同じネットワークの全員が使えます。" >&2
else
  # The token is kept in .mazemaze_token (git-ignored, mode 600) so the iPhone app does not need a
  # new token every time. Delete the file to issue a new one. MAZEMAZE_TOKEN overrides it.
  TOKEN_FILE=".mazemaze_token"
  if [ -z "${MAZEMAZE_TOKEN:-}" ]; then
    if [ ! -s "$TOKEN_FILE" ]; then
      ( umask 077; openssl rand -hex 8 > "$TOKEN_FILE" ) || { echo "トークンを作成できませんでした（openssl が必要です）。" >&2; exit 1; }
    fi
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true
    MAZEMAZE_TOKEN="$(cat "$TOKEN_FILE")"
  fi
  # The app accepts 16-128 letters, digits, "-" and "_" (so it can go into a QR code / URL unchanged).
  if ! printf '%s' "$MAZEMAZE_TOKEN" | grep -Eq '^[A-Za-z0-9_-]{16,128}$'; then
    echo "MAZEMAZE_TOKEN は 16〜128 文字の英数字・ハイフン・アンダースコアにしてください（iPhone アプリが受け付ける形式です）。" >&2
    exit 1
  fi
  export MAZEMAZE_TOKEN
  SUFFIX="#t=${MAZEMAZE_TOKEN}"
fi

PORT="${PORT:-8000}"
HOSTNAME_LOCAL="$(scutil --get LocalHostName 2>/dev/null | tr 'A-Z' 'a-z' || true)"
case "$HOSTNAME_LOCAL" in *[!a-z0-9-]*|"") HOSTNAME_LOCAL="" ;; esac     # only names an iPhone can resolve safely

SCHEME="http"; TLS_ARGS=(); FINGERPRINT=""
if [ "${MAZEMAZE_TLS:-1}" != "0" ]; then
  FINGERPRINT="$(./scripts/make_tls_cert.sh)" || { echo "暗号化の準備に失敗しました。MAZEMAZE_TLS=0 で暗号化なしでも起動できます。" >&2; exit 1; }
  SCHEME="https"
  TLS_ARGS=(--ssl-keyfile .mazemaze_tls/key.pem --ssl-certfile .mazemaze_tls/cert.pem)
fi

PAIR=""
if [ -n "$SUFFIX" ]; then
  NAME="$(scutil --get ComputerName 2>/dev/null || true)"
  NAME_Q="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1][:40]))' "$NAME" 2>/dev/null || true)"
  PAIR="mazemaze://pair?v=1"
  [ -n "$HOSTNAME_LOCAL" ] && PAIR="${PAIR}&h=${HOSTNAME_LOCAL}.local"
  PAIR="${PAIR}&i=${IP}&p=${PORT}&t=${MAZEMAZE_TOKEN}"
  if [ "$SCHEME" = "https" ]; then PAIR="${PAIR}&s=https&f=${FINGERPRINT}"; fi
  [ -n "$NAME_Q" ] && PAIR="${PAIR}&n=${NAME_Q}"
fi

echo "----------------------------------------------------------------"
if [ -z "$SUFFIX" ]; then echo " ※ トークンなしのため、QR ペアリングは使えません（手入力の http のみ）。"; fi
if [ -n "$PAIR" ]; then
  echo " iPhone の標準「カメラ」でこの QR を読み取り、出てきた通知をタップしてください（初回だけ）:"
  echo ""
  swift scripts/qr_terminal.swift "$PAIR" 2>/dev/null || echo "（QR を表示できませんでした。下の文字列をコピーして、アプリの設定から貼り付けてください）"
  echo ""
  echo " 読み取れないとき: 次の 1 行をコピーし、アプリの「設定 > ペアリング」の貼り付けボタン"
  echo "   ${PAIR}"
  echo ""
fi
echo " 手入力する場合:  サーバーの URL: ${SCHEME}://${IP}:${PORT}"
if [ -n "$HOSTNAME_LOCAL" ]; then echo "     （IP が変わる場合は ${SCHEME}://${HOSTNAME_LOCAL}.local:${PORT} でも可）"; fi
if [ -n "$SUFFIX" ]; then echo "                      トークン: ${MAZEMAZE_TOKEN}"; fi
if [ "$SCHEME" = "https" ]; then
  echo " 通信は暗号化されます（証明書の指紋 ${FINGERPRINT:0:16}… を iPhone が確認します）。"
  echo " ※ iPhone の Safari や Mac のブラウザで開くと、証明書の警告が出ます（自己署名のため）。アプリを使ってください。"
else
  echo " ※ 暗号化なし（HTTP）です。自宅など信頼できる Wi-Fi だけで使ってください。"
fi
echo " 止めるには Ctrl-C。"
echo "----------------------------------------------------------------"
exec .venv/bin/python -m uvicorn backend.app:app_factory --factory \
  --host 0.0.0.0 --port "$PORT" --no-proxy-headers --no-server-header ${TLS_ARGS[@]+"${TLS_ARGS[@]}"}
