# Implementation plan

詳細な契約は `/Users/mineno/.claude/plans/` の承認済み計画を参照（要点は `eval/README.md` と `DECISIONS.md`）。

| Slice | Status | Acceptance proof | Notes |
|---|---|---|---|
| T0 環境・安全ガード（.venv, pytest, ネットワーク遮断） | DONE | `pytest` と `harness_verify.py --level quick` が通る | |
| T1 `backend/spans.py` | DONE | `tests/test_spans.py` | |
| T2 Ollama クライアント | DONE | `tests/test_ollama_client.py` | loopback・cloud拒否、エラー分類 |
| T3 Qwen Adapter | DONE | `tests/test_qwen_adapter.py` | JSON Schema、部分採用 |
| T4 TranslateGemma Adapter | DONE | `tests/test_translategemma_adapter.py` | 公式プロンプト、スパンごと |
| T5 評価データ30件 | DONE | `tests/test_dataset.py` | |
| T6 `eval/run_compare.py` | DONE | `tests/test_run_compare.py` | |
| T7 `eval/report.py` | DONE | `tests/test_report.py` | |
| T8 ドキュメント | DONE | 目視レビュー | |
| T9 実機スモークテスト（各モデル3件） | STATE.md を参照 | 手動確認 | |
| 次: 30件フル実行・人手採点・モデル選定 | TODO | 記入済みCSVからの report.md | |
| 次: FastAPI 本体・UI | → 下の A1〜A4 | | |
| A1 表示整形 `backend/display.py` | DONE | `tests/test_display.py`、`docs/ai/DISPLAY_FORMATTING.md` | 効果（Judge 点）は未評価 |
| A2 スパン選択・変換 API（`selector.py`・`service.py`・`app.py`・`config.py`） | DONE | `tests/test_selector.py`・`test_api.py`・`test_api_security.py` | 実 Qwen で API 経由の変換を確認 |
| A3 スマホ向け画面 `frontend/` | DONE（実機未確認） | `tests/test_frontend_static.py`（静的検査のみ） | iPhone/Android 実機は未確認 |
| A4 起動スクリプト・README | DONE | `scripts/run_local.sh`・`run_lan.sh`、`README.md` | LAN は同一 Mac から実 IP で確認、スマホ実機は未確認 |
| 次: 実機確認・人手採点・モデル正式選定 | TODO | | |
