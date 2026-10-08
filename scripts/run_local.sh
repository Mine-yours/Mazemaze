#!/bin/bash
# mazemaze をこの Mac だけで使うモードで起動する（127.0.0.1 にのみ公開）。
# 使い方: ./scripts/run_local.sh     （止めるときは Ctrl-C）
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x .venv/bin/python ]; then
  echo "仮想環境 .venv がありません。README の「セットアップ」を先に実行してください。" >&2
  exit 1
fi
if ! .venv/bin/python -c "import fastapi, uvicorn" 2>/dev/null; then
  echo "依存パッケージが未導入です。 .venv/bin/pip install -r requirements.txt を実行してください。" >&2
  exit 1
fi
if ! curl -s -m 3 http://127.0.0.1:11434/api/version >/dev/null; then
  echo "注意: Ollama に接続できません。Ollama アプリを起動してください（画面は開けますが、変換はできません）。" >&2
fi

HOST=127.0.0.1
PORT="${PORT:-8000}"
echo "mazemaze を起動します: http://localhost:${PORT}   （モデル: ${MAZEMAZE_MODEL:-qwen3.5:9b}）"
# --workers は 1 のまま（同時実行の制御がプロセス内で行われるため）。
exec .venv/bin/python -m uvicorn backend.app:app_factory --factory \
  --host "$HOST" --port "$PORT" --no-proxy-headers --no-server-header
