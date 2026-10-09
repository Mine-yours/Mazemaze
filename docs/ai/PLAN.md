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
| B1 iOS 土台（Xcode プロジェクト、SwiftUI ブラウザ、設定、接続確認、ATS/ローカルネットワーク） | DONE（実機未確認） | `swift test`、シミュレータ自己テスト、Release 実機向けビルド | `ios/` |
| B2 ページの自動英語化（`translator.js`、WKContentWorld、置換・復元・原文表示） | DONE（実機未確認） | Chrome DOM テスト 59 件、シミュレータ自己テスト 14 項目 | |
| B3 動的サイト対応（MutationObserver、視認範囲優先、直列、重複/ループ防止） | DONE（実 X は未確認） | DOM テスト、実 Yahoo!ニュース記事で確認 | X はログイン必須 |
| C1 翻訳待ち時間の短縮（開始待ち・部分反映・先読み・warmup・計測） | DONE（実機未確認） | `ios/scripts/bench.sh` の前後比較、DOM テスト 71 | 4.9s→1.1s |
| C2 ホーム・お気に入り・最近・検索の明示 | DONE（実機未確認） | `SessionPrivacyTests`・`AddressInputTests`、結合テスト | |
| C3 タブ（休止・復元・タブ別世代） | DONE（実機未確認） | `ScopeTests`・結合テスト 36 項目 | |
| C4 ペアリング（QR/文字列・TLS ピン留め・`.local` + IP） | DONE（実機未確認） | `PairingTests`・結合テスト（TLS）・persistence_test | |
| 次: iPhone 実機確認（v2）・X の再検討（第2段階）・人手採点・モデル正式選定 | TODO | `docs/ai/IPHONE_DEVICE_CHECKLIST.md` | |
