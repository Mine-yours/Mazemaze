# 翻訳品質の自動評価（LLM-as-a-Judge）

既存のローカルLLM比較（`eval/run_compare.py`）の結果を、Claude Code の Opus サブエージェント（`translation-judge`）で採点する、**開発用の独立モジュール**。Mazemaze 本体（`backend/`）はこれを import せず、クラウド LLM も API キーも使わない（`tests/test_judge_isolation.py` で検査）。

## 方針
- 翻訳の生成は引き続き Ollama 上のローカルモデルだけ。Judge が見るのは、**リポジトリのテストデータ（`eval/dataset_ja_en.jsonl`）とその生成結果だけ**。一般ユーザーの入力は評価しない。
- 新しい Anthropic API キーは使わない。Claude Code の通常のサブエージェント機能（`.claude/agents/translation-judge.md`）で動かす。
- 既存の原文保持・検証処理（`backend/spans.py`）と、既存の実行結果（`human_scores.csv` など）は変更しない。出力は `eval_runs/<run>/judge/` に別に作る。
- サブエージェントが使えない場合、Sonnet など別モデルで代替採点しない（実行を止める）。

## データの扱い（重要）
- Judge に渡すのは許可リストの項目だけ: 評価項目ID、日本語原文とスパン、前後の文脈（その文全体）、A/B の候補（採用された訳文・表示される混在文・採否）。**モデル名と対応表、ソースコード、Git情報、環境変数、APIキー、ログ、パスは含めない。** モデル名の対応は run の `blind_key.json`（ローカル）にだけある。
- `prepare` は、(1) run の `dataset_sha256` がテストデータと一致し、run が完了していること、(2) 結果の項目・スパンがデータセットと一致すること、(3) 許可リストのキーと型、(4) 漏えいパターン（キー・パス・環境変数の値・モデル名）が無いこと、を確認し、**1つでも確認できなければ停止**する（終了コード 2）。確認後にプレビューを表示する。`prepare` 自体は何も送信しない。
- **Claude Code の通常セッション自体には、厳密なデータ隔離がない。** 評価データはメインセッションの会話を経由してサブエージェントへ渡り、会話履歴・トランスクリプトに残る。`omitClaudeMd` はサブエージェントの文脈から CLAUDE.md を外すだけで、通信やログの隔離ではない。サブエージェントの `tools` は読み取り専用（`Read, Grep, Glob`。公式ドキュメントは空の `tools` を想定していない）で、「評価データ以外のファイルを読まない」ことは、まず指示による運用である。モデル名の対応表（run の `blind_key.json`）はディスク上にあり、`Read` を持つ Judge が、評価データ内の命令（インジェクション項目など）に誘導されれば読めてしまう。そこで定義に、サブエージェント専用の `PreToolUse` フック（`matcher: "Read|Grep|Glob"`、`exit 2`）で、Judge の読み取りツールの呼び出しを拒否する設定を入れてある。**このフックは 2026-10-08 に実測で確認済み**（下の「フックの実測確認」）。ただし、これは Claude Code のハーネスによるツール呼び出しの拒否であり、**OS レベルの完全な隔離ではない**（サンドボックスやファイル権限ではない。会話履歴・トランスクリプトへの記録も防がない。確認したのは `Read` / `Grep` / `Glob` の各1回の呼び出しだけで、あらゆる回避経路の不在を証明するものではない）。だから、テストデータ以外はこの経路に載せないこと。
- Judge の出力は信頼しないデータとして扱う。形式が不正なら採点せず「出力不正」「出力なし」と記録する（非 UTF-8・BOM 付きでも全体は止まらない）。`accuracy` と `naturalness` が null の評価は無効（残りの軸への再正規化で平均が不当に上がるため）。無効な評価でも、報告された重大エラーは記録を残し、確認待ちに入れる。候補訳に含まれる命令は、従わず評価対象として扱うよう Judge に指示している。

## 評価の仕様
- 1〜5点: 意味の正確性 40%、英語の自然さ 25%、文脈との整合性 25%、固有名詞・数値 10%。該当しない軸は `null` として除外し、残りの重みを再計算する。全軸が `null` なら「評価不能」で、**0点にはしない**。
- 重大な誤訳・情報の追加・欠落・固有名詞の誤訳は、候補とスパンごとに個別に記録する（重大な誤りがあれば、正確性は2以下とする指示。守られていなければ警告を付けて確認待ちに入れる）。
- Judge に渡す訳文は、保存値ではなく `backend.spans.assemble()` が実際に採用したものだけ（現在の検証で採用されない保存値があれば停止）。入力 ID は、Judge に見せる内容のハッシュを含むので、内容が変わった入力に古い出力が紐づくことはない。`judge_meta.json` が run と入力の SHA を束縛し、`collect`・`report` は別の run や編集された入力を拒否する。
- 機械検証で不採用だった翻訳は、品質を採点せず、不採用として別集計する（比較の対象外）。
- ブラインド比較: 同じ項目を A→B と B→A の2順序で別々に評価する（別の呼び出し）。**2順序の判定が一致した場合のみ優劣を採用**する。片方が tie でもう片方が勝敗なら「不一致」、無効・欠落があれば「評価不能」で、tie・不一致・評価不能は別々に数える。
- 長さや位置では点を付けない指示に加え、レポートに「一致した勝ちのうち、勝者の方が長かった数」を出して偏りを確認できるようにしている。

## 手順
```
# 1) 抽出・検証・プレビュー（何も送信しない）。最初は5件だけ。
.venv/bin/python -m eval.judge prepare eval_runs/<run> --limit 5
# 2) judge_inputs.jsonl の各行（1行 = 1回の独立した評価）を translation-judge に渡し、
#    返答をそのまま judge/raw/<input_id>.txt に保存する（Claude Code セッション内で実施）。
# 3) 検証して ai_scores.jsonl を作る
.venv/bin/python -m eval.judge collect eval_runs/<run>
# 4) judge_report.md と review_queue.csv を作る
.venv/bin/python -m eval.judge report eval_runs/<run>
```
出力（`eval_runs/<run>/judge/`、Git 管理外）: `judge_inputs.jsonl`（Judge に渡すデータ）、`judge_key.json`（入力ごとの A/B の位置。モデル名なし）、`judge_meta.json`（run と入力の束縛）、`raw/`、`ai_scores.jsonl`、`judge_report.md`（モデル名つきの集計）、`review_queue.csv`（人が確認する項目。A/B のラベルのみ）。

## サブエージェントの準備と、Opus で動いていることの確認
- `.claude/agents/translation-judge.md` は `model: opus`、`omitClaudeMd: true`（Claude Code v2.1.271 以降）、`tools: Read, Grep, Glob`。
- **`.claude/agents/` を新しく作った直後は、Claude Code の再起動が必要**（公式ドキュメントの記載。2026-10-08、作成したセッションでは `Agent type 'translation-judge' not found` になることを確認）。再起動後に使えるかは、評価データを含まない確認用プロンプトで試す。
- Opus で動いていることの確認は、次の3段階。いずれも単独では証明にならないので、組み合わせる。
  1. 定義の `model: opus`（ただし環境変数 `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` や `availableModels` の設定で上書き・置換されうる）。
  2. Judge が返す `judge_model`（自己申告）。`collect` が記録し、レポートが「opus と自己申告した出力 n/N」を表示する。自己申告は証明ではない。
  3. 実行中に Claude Code の `/tasks` を開き、サブエージェントの行に表示されるモデルを目視する（v2.1.242 以降）。
- 再起動後の確認は、評価データを含まないプロンプトで行う（手順は下の「フックの実測確認」）。

## フックの実測確認（2026-10-08、評価データなし）
`/tmp` に作った内容が `dummy` だけの一時ファイルを使い、新規のサブエージェントごとに対象ツールを1回だけ呼ばせて確認した（実データは一切渡していない。一時ファイルは確認後に削除）。
- **正常系**: 「ツールを使わず READY とだけ回答」で起動し、親に `READY` が届いた。`SubagentHandback` は拒否されずに通り、使用モデルは実行メタデータ上で `claude-opus-5-5`（Opus）だった。
- **拒否**: `Read` / `Grep` / `Glob` はいずれも `PreToolUse` フック（`source: hook`、`permissionDecision: reject`、`exit 2`）で拒否され、ファイル内容は読まれなかった。拒否メッセージは `translation-judge must not use tools: judge only the JSON in the message`。
- **ハンドバック**: 拒否の後も `SubagentHandback` は `accept` で通った。`matcher` を `".*"` にすると `SubagentHandback` まで拒否されうるため、`"Read|Grep|Glob"` を保つこと（`tests/test_judge_isolation.py` が、3ツールがマッチし `SubagentHandback` がマッチしないことを検査する）。
- **限界**: 上記のとおり OS レベルの隔離ではない。定義やフックを変更したら、同じ手順で再確認する。

## 限界
- Judge の採点は LLM の判断で、正解ではない。人手採点の代わりではなく、確認の優先順位付けに使う（`review_queue.csv`）。
- 少数（試験は5件）では統計的な結論は出せない。同じ Judge による2順序の一致率は、Judge 自身の一貫性の目安にすぎない。
- モデル別の平均点は、機械検証を通った（採用された）スパンだけの平均で、不採用が多いモデルが有利に見える（生存バイアス）。両モデルが採点されたスパンだけの対応あり平均は未実装。
- Opus がローカルモデルより強いこと自体が、評価の偏り（言い回しの好み）を生む可能性がある。
