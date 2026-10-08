#!/bin/bash
# mazemaze を同じ Wi-Fi/LAN 上のスマホから使えるように起動する（0.0.0.0 で待ち受ける）。
# 信頼できる自宅などの LAN でだけ使ってください。外部公開・ポート転送はしないでください。
# 使い方: ./scripts/run_lan.sh          （毎回ランダムなアクセストークン付き URL を表示）
#         MAZEMAZE_NO_TOKEN=1 ./scripts/run_lan.sh   （トークンなし。非推奨）
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c "import fastapi, uvicorn" 2>/dev/null; then
  echo "仮想環境または依存パッケージがありません。README の「セットアップ」を先に実行してください。" >&2
  exit 1
fi
if ! curl -s -m 3 http://127.0.0.1:11434/api/version >/dev/null; then
  echo "注意: Ollama に接続できません。Ollama アプリを起動してください。" >&2
fi

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [ -z "$IP" ]; then
  echo "この Mac の LAN の IP アドレスを取得できませんでした。Wi-Fi に接続しているか確認してください。" >&2
  exit 1
fi

export MAZEMAZE_ALLOW_LAN=1
if [ "${MAZEMAZE_NO_TOKEN:-}" = "1" ]; then
  unset MAZEMAZE_TOKEN || true
  SUFFIX=""
  echo "警告: アクセストークンなしで LAN に公開します。同じネットワークの全員が使えます。" >&2
else
  MAZEMAZE_TOKEN="${MAZEMAZE_TOKEN:-$(openssl rand -hex 6)}"
  export MAZEMAZE_TOKEN
  SUFFIX="#t=${MAZEMAZE_TOKEN}"
fi

PORT="${PORT:-8000}"
echo "----------------------------------------------------------------"
echo " スマホのブラウザで次の URL を開いてください（同じ Wi-Fi に接続）:"
echo "   http://${IP}:${PORT}/${SUFFIX}"
echo " 止めるには Ctrl-C。ブラウザの履歴にトークンが残る点にご注意ください。"
echo "----------------------------------------------------------------"
exec .venv/bin/python -m uvicorn backend.app:app_factory --factory \
  --host 0.0.0.0 --port "$PORT" --no-proxy-headers --no-server-header
