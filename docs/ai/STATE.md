# Handoff state

## MVP アプリの状態（2026-10-08・最新）
**Mac 上で起動し、スマホ幅のブラウザ画面から日本語文を入力して、ローカル Qwen3.5:9b による日英混在文を表示・コピーできる MVP を実装した。** 実機スマホでの確認は未実施。コミットはしていない（承認待ち）。

### 実装済み（新規ファイル。すべて未追跡）
- `backend/display.py`（表示整形。設計は `docs/ai/DISPLAY_FORMATTING.md`）、`backend/selector.py`（スパン選択）、`backend/config.py`、`backend/service.py`、`backend/app.py`（FastAPI）
- `frontend/`（`index.html`・`style.css`・`app.js`。ビルド不要）、`scripts/run_local.sh`・`scripts/run_lan.sh`、`README.md`、`requirements.txt`
- 既存の `backend/spans.py`・`backend/llm/*`・`eval/`・`eval_runs/`・Judge 設定（`.claude/agents/translation-judge.md`）は**変更していない**（ファイル更新時刻で確認）。`requirements-dev.txt` は `-r requirements.txt`・pytest・httpx に更新。
- 判断は `DECISIONS.md` 末尾「MVP アプリの設計判断」。

### 確認した証拠
- `.venv/bin/python -m pytest -q`: **501 passed**（実 Ollama には接続しない）。`python3 scripts/harness_verify.py --level quick`: 自動チェック通過（手動チェックは従来どおり未実施）。`node --check frontend/app.js`: 構文 OK。
- 実機（この Mac）: `run_local.sh` で起動、実 Qwen3.5:9b による `/api/translate` の変換を複数回確認（約 1.3〜2 秒、初回はモデル読み込みで長くなる）。スパン外の日本語が原文と一致し、英訳に付いた末尾 `.` は直後の `。` 用に表示だけ除去された。`run_lan.sh` で LAN の実 IP（192.168.x.x）経由、トークンなし → 401、不正 Host → 400、トークン付き → 200 を curl で確認（Mac 自身から）。
- 独立レビュー: 設計（dev-architect、dev-test-strategist）→ 実装後（dev-reviewer、dev-ux-auditor）→ 修正後に再レビュー（dev-reviewer）。実装後レビューの高1件（TranslateGemma で締め切りが効かない）・中2件（部分失敗の破棄、Content-Length なしの POST）と UX の高3件（再試行が旧入力を再送、詳細パネルが画面外、バックグラウンド時の案内）を修正済み。再レビューでは P0/P1 なし。P2 のうち時間切れ警告の区別・全失敗判定・最小実行窓・フォーカス・400 の再試行非表示・`.en` のタップ領域/scroll-padding は修正し、テスト追加。

### 未確認・既知の問題（MVP）
- **iPhone Safari / Android Chrome の実機は未確認**。Mac の Chrome（headless、375px エミュレーション、CDP 経由の実操作）では 26 項目を確認済み: 空入力エラー、入力、英語化率、処理中表示、変換、タップ・Enter で原文、sticky 詳細パネルの可視、コピー（クリップボード内容一致）、元に戻す、オフライン時のエラー・再試行・古い結果の非表示、横スクロールなし（初期・結果・エラー・ダーク）、コンソールエラーなし。未確認: Safari/WebKit 固有の挙動、実際のタッチ操作、VoiceOver、`http://LAN-IP` でのコピー代替（Clipboard API 無効時は execCommand が成功し、選択済み textarea は未表示のため未検証）。LAN モードは Mac 自身からの確認のみで、別端末からは未確認。
- 英語化率は目安。`sentence` 単位は粒度が粗く目標を大きく下回ることがある（例: 目標 30% に対し 15%）。固有名詞の誤訳は検出できない。
- iOS でバックグラウンドに回ると fetch が切れ、Mac 側の処理が続くため再試行が 429 になりうる（案内文は出す。ジョブ化は未実装）。
- Ollama サーバー側のクラウド機能は **無効を確認済み**（2026-10-08 20:00 頃、読み取りのみ: `~/.ollama/server.json` の `disable_ollama_cloud: true`、稼働中プロセス（17:32:12 起動）の環境 `OLLAMA_NO_CLOUD=1`、同起動のログ `Ollama cloud disabled: true`。この作業では設定を変更していない）。アプリからは検出不能なので、Ollama の再起動後は同じ確認をすること。なお評価 run `20261008-171216` は、クラウド有効だった起動（〜17:32 より前）のサーバーに対して行われた（クラウドモデルは使っていない）。
- 表示整形（`display.py`）が Judge 点に与える影響は未評価。TranslateGemma 経由は API テスト（偽 transport）のみで、実モデルでは未確認。
- 通信は HTTP 平文（LAN モード）。同一 LAN の盗聴は防げない。スクリプト・Settings・CSP の自動テストはあるが、実 uvicorn のピア IP と、クライアント切断後のロック保持は自動テストしていない。
- 未処理の 500 例外応答にはセキュリティヘッダが付かない可能性がある（低）。壊れた JSON の 422 文言が「英語化率…」になる（低）。

### 次の最小アクション
1. `./scripts/run_local.sh` → <http://localhost:8000> を Mac のブラウザで開き、実画面を目視確認（入力・変換・タップ・コピー・元に戻す）。
2. `./scripts/run_lan.sh` でスマホ実機（iPhone Safari / Android Chrome）の確認（README の手順）。
3. 確認結果に応じた UI 調整、コミットの承認（私は未コミット）、人手採点・モデル正式選定。

---

# （以下は評価環境・評価時点の状態。MVP 実装前の記録）

## Current objective
（最新・2026-10-08）ローカルLLM 2モデル（`qwen3.5:9b` vs `translategemma:12b`）の30件比較と、Claude Opus 5.5 による30件・60入力の自動評価（LLM-as-a-Judge）が**完了**し、評価レポートを `docs/ai/TRANSLATION_EVAL_REPORT.md` に保存した。結論は「**Qwen3.5:9b を暫定第一候補とするが、正式採用は未決定**」。（その後、表示整形・FastAPI・スマホ対応画面を実装した。上の「MVP アプリの状態」を参照。）

（以前）比較環境の実装・安定化（`outside` の必須化、成果物の書き出し失敗の終了コード）、Judge 機能（`eval/judge/`）の実装。

## Current branch / changed files
branch: main（コミットなし。すべて未追跡）。
追加: `.gitignore`、`requirements-dev.txt`、`pyproject.toml`、`backend/`、`eval/`（`judge/` を含む）、`tests/`（`test_judge_*.py` を含む）、`.claude/agents/translation-judge.md`、`docs/ai/TRANSLATION_EVAL_REPORT.md`（評価レポート）。更新: `.harness/checks.json`、`docs/ai/*.md`、`eval/README.md`、`eval/judge/README.md`。
評価成果物は `eval_runs/20261008-171216/`（Git 管理外）: 元の run、5件の試験評価（`judge/`）、30件の本評価（`judge_full30/`）。

## What is complete
- **比較環境**（T0〜T8）と、レビュー指摘への対応（`DECISIONS.md` の各 ADR を参照）: 中断・例外でも成果物を保存、検証ルールの共通化、ローカル専用の制約（fail-closed）、`outside` の必須化、成果物の書き出し失敗は終了コード 3、など。
- **ローカルLLM 2モデルの30件比較を実施済み**（run `20261008-171216`、Ollama 0.33.3、`status: complete`、60/60行）。
- **Judge 機能**（`eval/judge/`、独立モジュール。`backend/` から import しない）の実装と、Opus での実運用:
  - 5件・10入力の試験評価、続いて**30件・60入力の本評価が正常完了**（正常60、不正0、欠落0）。
  - 実行メタデータ上、評価に応答した全件のモデルは `claude-opus-5-5`（自己申告も60/60）。Sonnet などでの代替はしていない。
  - 本評価の10入力は、試験評価の応答を再利用（`input_id` と JSON 本文が完全一致。新規送信は50入力）。再送は3入力のみ: unicode-03 の2入力（初回は入力の Unicode 正規化で不一致のため不採用）と、url-03 の order2（初回応答がスパン欠落で不正）。旧不正応答は `judge_full30/raw_audit/` に保全。詳細は評価レポート §3。
- **Judge のファイル読み取り拒否と結果報告を実測検証済み**: `translation-judge` の `PreToolUse` フック（`matcher: "Read|Grep|Glob"`、`exit 2`）が、`Read`・`Grep`・`Glob` のそれぞれ1回の呼び出しをダミーファイルで拒否し（`source: hook`、`permissionDecision: reject`）、拒否後も `SubagentHandback` が正常に通ることを確認した（`eval/judge/README.md`「フックの実測確認」）。OS レベルの隔離ではなく、ハーネスによるツール拒否にとどまる。`tests/test_judge_isolation.py` が matcher と `SubagentHandback` 非マッチを検査する。**matcher を `".*"` に戻さないこと**（`SubagentHandback` まで拒否されうる）。
- **評価レポートを `docs/ai/TRANSLATION_EVAL_REPORT.md` に保存済み**。

## Verified evidence
- `.venv/bin/python -m pytest -q`: 341 passed（実 Ollama・Claude には接続しない）。
- `python3 scripts/harness_verify.py --level quick`: 自動チェックは通過。手動チェック2件は未実施（下の Known failures）。
- 30件比較の機械検証（`eval_runs/20261008-171216/`、約4分57秒）:
  - 両モデルともエラー0、形式遵守 30/30、原文保持の違反 0。
  - スパン採用率: Qwen 61/63、TranslateGemma 61/63。**機械検証の不採用率は両モデルとも 3.2%**（各 2/63）。不採用: Qwen は `context_leak` 2件（url-01 s3、url-03 s2）、Gemma は `japanese_chars` 1件（unicode-01 s2）と `placeholder` 1件（url-03 s2）。
  - 応答時間 median: Qwen 4481 ms、Gemma 4471 ms。p90: Qwen 5445 ms、Gemma 6132 ms（各30件・1回、参考値。呼び出し単位が異なり、速度の比較は未確定）。
  - インジェクション（翻訳モデル）: スパン内の指示は両モデルとも 0/2（忠実に訳しただけ）。スパン外の指示は Qwen 0/2、Gemma は測定不能（文脈を受け取らない）。
- Judge による30件の評価結果（詳細は `docs/ai/TRANSLATION_EVAL_REPORT.md`）:
  - **両モデルとも採用された60スパンの対応あり比較: Qwen 3.99、TranslateGemma 3.43**（差 +0.56、ブートストラップ95%区間 +0.37〜+0.75）。Judge の優劣判定（両順序一致）は Qwen 37勝、TranslateGemma 6勝、同点8、不一致9。
  - **A/B 反転の判定一致率は 85.0%**（51/60）。不一致9は、いずれも「tie ↔ 勝敗」の食い違いで、勝者が逆転したのは1件。
  - 採用済み平均（母集団がモデルごとに異なる）: Qwen 3.97、TranslateGemma 3.41。重大な誤訳のあったスパンは Qwen 10、TranslateGemma 9。
  - 人が確認する対象は `eval_runs/20261008-171216/judge_full30/review_queue.csv`（22行）。
- Judge に渡したデータは、許可リストの項目のみ（モデル名・対応表・パス・Git 情報・秘密情報なし）。`judge_inputs.jsonl`・`judge_key.json`・`judge_meta.json` は、準備後に変更していない。

## 翻訳品質への影響と限界
- 採用率は「機械的な検証を通過した」割合で、品質ではない。品質の指標は Judge の採点だが、**人手による品質採点は未実施**（`human_scores.csv` の `naturalness`・`context_fit` は126行すべて空欄）。
- 機械検証で検出できるのは機械的な問題のみ。訳の意味的な正しさ、言い換えによる重複、全角数字・スキームなしドメインの混入は検出できない。
- 𠮷野家／𠮷田は、Qwen が「Sano house」「Mr. Sada」と誤訳し、TranslateGemma の𠮷野家も「traditional Japanese farmhouse」と誤訳した（両モデルとも固有名詞の誤訳）。
- 検証ルールの変更により、過去の実行（`20261008-164410` 以前）とはデータセット・検証が異なり、比較できない。

## Judge 機能（`eval/judge/`）の状態
- 実装済み: `prepare`（テストデータの同一性検証・許可リスト・漏えい走査・プレビュー。`--judge-dir` で出力先を分離できる）、`collect`（Judge 出力の厳格な検証）、`report`（`judge_report.md`・`review_queue.csv`）、`.claude/agents/translation-judge.md`（`model: opus`、`omitClaudeMd: true`、`tools: Read, Grep, Glob`、`Read|Grep|Glob` を拒否する `PreToolUse` フック）。詳細は `eval/judge/README.md`、判断は `DECISIONS.md`。
- 運用上の知見:
  - Unicode の分解形（NFD。例: `か`＋`U+3099`）を含む入力は、プロンプトへ手で書き写すと合成形に変わる。プログラムで JSON のエスケープ形式（`ensure_ascii=True`）を生成して送る（ツール呼び出しの層で文字に復元され、原文のコードポイントのまま Judge に届く）。送信後に、実際に送られた JSON を復元して準備済み入力と完全一致するかを必ず検証する。
  - Judge が、両候補とも不採用のスパンを出力から省いた例が1件あった（`span_mismatch` で不正に分類）。再送時は、全 `span_id` を出力する旨の出力形式の補足を加えた。**Judge 定義にこれを明記するかは未判断**（採点基準・定義の変更は、run 間の比較可能性に影響するため、変更していない）。
- 未実施: Judge の `/tasks` での目視によるモデル確認（実行メタデータと自己申告で代替した。README 記載の3段階のうち、1つが目視）。
- 低程度の既知の限界（記録のみ）: モデル別の採用済み平均は生存バイアスがある（対応あり比較は評価レポートで読み取り専用に算出したもので、`eval/judge/report.py` には未実装）。`prepare` の `validate_input` は想定外の型で `AttributeError` になりうる（入力は自前で組むので到達しにくい）。

## Known failures / blockers（未解決）
- **Qwen は暫定第一候補であり、正式採用は未決定**（評価レポート §10）。人手確認と、下の各点の検証を経て判断する。
- **モデル間で全文文脈の提供条件が異なり、公平なモデル単体比較にはなっていない**: Qwen は全文を文脈として受け取り、TranslateGemma は受け取らない（`num_ctx`・`num_predict`・呼び出し単位も異なる。`DECISIONS.md`「モデル別 Adapter を分ける」）。
- **句読点・大文字・省略記号などの表示崩れが品質点数に影響している**: 採用された訳のうち、文末句読点で終わる割合は TranslateGemma 95%、Qwen 34%、大文字始まりは 95% と 57%、末尾が `...` は TranslateGemma のみ8件。Judge は「文脈適合性」で強く減点しており（差 +0.93）、+0.56 の差の一部は出力形式に起因する可能性がある。因果関係は未検証。
- **固有名詞・慣用句・口語などに重大な誤訳が残っている**: Qwen 10スパン、TranslateGemma 9スパン。Qwen はスパン外の語の取り込み（addition）が多く、TranslateGemma は文脈を受け取らないことに由来する誤りが見られる。これらは句読点の整形では直らない。
- **人手による品質採点は未実施**。CSV を Numbers / Excel で開く確認（manual_checks）も未実施（`review_queue.csv` の文字化け確認を含む）。
- **Ollama サーバー側のクラウド機能は現在「有効」**（2026-10-08、読み取りのみで確認）: 稼働中サーバーの環境変数が `OLLAMA_NO_CLOUD=0`、`~/.ollama/server.json` なし、`server.log` が `Ollama cloud disabled: false`。無効化は未実施（設定を変更していない）。手順は `eval/README.md` の「Ollama サーバー側のクラウド機能」。キー名・環境変数名は公式 FAQ の記載で、適用して再起動し `disabled: true` になるまで未確認。
- クラウド別名がローカルのメタデータにどう現れるかは未検証（fail-closed の判定は実機の2モデルでのみ確認）。
- 低程度の指摘（記録のみ。機能追加はしない）:
  - 和文句読点・全角記号が `japanese_chars` の対象外。`<...>` を含む正当な英文がプレースホルダと誤検出されうる。形式遵守の定義が Gemma（前置き＝非遵守）と Qwen（スキーマ準拠）で異なる。`assert_local_entry` は `chat()` に組み込まれておらず run_compare のみ（FastAPI 連携時に要対応）。
  - `eval/report.py` は `artifacts_ok` を見ない（書き出し失敗の run を警告なしでレポートできる）。保留状態の `run_meta.json` に `artifacts_failed` キーがない。
  - 優先順位 1 > 3 と、130 かつ成果物失敗のときの扱いが README に書かれていない。`run_meta.json` だけが失敗した場合も「結果は不完全です」と表示される（`results.jsonl` は完全）。
  - 採点用 CSV と盲検キーが1つの失敗ラベルにまとまっている。AST ガードは `outside_text` の第1引数が `text` かを見ず、`backend/` と `eval/` 以外は走査しない。未カバーのテスト経路（1 と 3 の優先、`status=failed` かつ成果物失敗、`finally` 内の KeyboardInterrupt など）。
- 再現性: 各モデル1回のみで、同条件の再実行による出力の揺れは未確認。
- 他の文書の古い記述（本更新では変更していない）: `PLAN.md` の「次: 30件フル実行・人手採点・モデル選定」は、30件フル実行が完了済み。`DECISIONS.md` の「Judge 機能のレビュー指摘（中5件）」の「中-1: 効果は未検証」は、フックの効果を実測確認済み（上記）。

## Next smallest action
1. **英訳スパンの表示整形の設計**（計画を先に提示する。実装は指示後）: 日本語の原文は変更せず、英訳スパンの先頭・末尾のみを必要に応じて整える。ピリオドの一括削除はしない（略語・小数・引用符・感嘆符・疑問符・三点リーダーに影響しうるため、実例とテストで安全性を確認する）。整形前後の混在文を比較し、モデル間の差がどれだけ変わるかを見る。再評価が必要なら新しい run として扱い、既存の run は変更しない。
2. 必要に応じて、**入力文脈条件をそろえた比較**を設計する（TranslateGemma に文脈を与えられるか、Qwen の文脈を外した場合に結果がどう変わるか）。
3. その後、**FastAPI とスマホ対応 Web 画面の実装**に進む（変換失敗時は原文を表示する安全なフォールバックを維持し、ローカル実行を基本とする）。
- 並行して可能（コストが低い）: `eval_runs/20261008-171216/judge_full30/review_queue.csv` の22行を人が確認する。`human_scores.csv` への人手採点も進める。Judge の指摘の妥当性を検証でき、評価レポート §9 の限界への最も直接的な対策になる。
- 任意・先に: クラウド機能の無効化を判断する（`eval/README.md` 参照）。
