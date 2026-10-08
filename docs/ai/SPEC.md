# Specification

## User/problem
mazemaze は、日本語の文章の一部を英語に置き換えて読ませる個人用ローカルアプリ（詳細は `CLAUDE.md`）。
本スライスでは、置換に使うローカルLLM（Ollama 上の `qwen3.5:9b` と `translategemma:12b`）を、同じ評価データで比較する環境を作る。

## In scope / out of scope
In scope（本スライス）:
- `backend/spans.py`: スパン解決・翻訳の検証・組み立て（本体でも再利用する）
- `backend/llm/`: Ollama クライアント（loopback 専用）とモデル別 Adapter
- `eval/`: 評価データ30件、比較CLI、レポート生成、人手採点CSV
- モックだけで動く pytest

Out of scope: FastAPI、フロントエンド、永続化、クラウド推論、モデルの自動ダウンロード、30件フル実行と人手採点（次のステップ）。

## Acceptance criteria
- [x] 実 Ollama を使わない pytest が通り、ネットワーク接続はガードで遮断されている
- [x] どんなLLM出力でも、未変換部分が原文と完全一致する（`is_preserved`）。失敗したスパンは日本語のまま
- [x] loopback 以外の接続先と cloud モデル名は、通信前に拒否される
- [x] 評価データが30件で、敬語・口語・慣用句・複文・固有名詞・URL/メール/数値・Unicode・本文中の指示を含む
- [x] 応答時間・形式遵守・エラー・モデル名・モデルID(digest)・設定値が `eval_runs/<ts>/` に記録される
- [x] 人手採点用CSV（UTF-8 BOM、モデル名は A/B に伏せる）と `report.md` が生成できる
- [ ] 実機スモークテスト（`--limit 3`）の結果確認（`STATE.md` を参照）
- [ ] 30件フル実行と人手採点（未実施）

## Security / privacy / data / mobile / accessibility implications
- 通信先は `127.0.0.1` / `localhost` / `::1` のみ。システムプロキシとリダイレクトは無効。`:cloud` / `-cloud` のモデル名を拒否し、モデルがローカルの GGUF 実体であることを `/api/tags`・`/api/show` で確認できなければ使わない。サーバー側のクラウド転送は検出できない（`OLLAMA_NO_CLOUD=1` を推奨）。
- 例外メッセージにリクエスト／レスポンス本文を含めない。`run_meta.json` に環境変数の値と本文を含めない。
- `eval_runs/` は Git 管理外（評価データの出力には本文が含まれるため）。
- モバイル／アクセシビリティは本スライスの対象外。
