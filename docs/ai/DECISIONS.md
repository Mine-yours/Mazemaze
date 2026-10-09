# Decisions (append-only ADR notes)

For each significant decision record: date, context, alternatives, choice, consequences, and reversal plan if relevant.

## 2026-10-08 モデル別 Adapter を分ける
- Context: `qwen3.5:9b` は JSON Schema 出力に対応するが、`translategemma:12b` は completion のみで、公式の翻訳プロンプト形式（文脈欄なし）を使うのが前提。
- Alternatives: 共通プロンプト＋共通パーサ。
- Choice: Qwen は全スパンを1回で JSON Schema 出力、TranslateGemma は公式プロンプトでスパンごとに1回。
- Consequences: Gemma は文脈を受け取らない（Qwen は全文を文脈として受け取る）ため、比較条件が完全には揃わない。レポートに明記する。
- Reversal: Adapter は `backend/llm/` 内で独立しており、差し替えは容易。

## 2026-10-08 LLM出力は検証し、部分採用する。失敗したスパンは日本語のまま
- Choice: 無効ID・欠落・重複・空・日本語混入・長すぎ・保護トークン（URL/メール/数字）欠落は不採用。有効なIDだけ採用する（部分採用）。`format_compliant`（形式遵守）と採用数は別指標として記録する。
- Consequences: 「3万円」のように数字を含むスパンは、訳で数字が変わるため不採用になりやすい。評価データではそのようなスパンを避けている。

## 2026-10-08 本文は正規化しない
- Choice: NFC/NFKC も改行統一も行わない。オフセットは Python のコードポイント単位。span 内の改行と、結合文字を切断する span は拒否する。
- Consequences: 将来 JS 側で扱うときは UTF-16 への変換が必要。フロントはオフセットを計算せず、サーバーが返すセグメント列を順に描画する。

## 2026-10-08 通信は loopback 限定、クラウド推論は禁止
- Choice: 接続先ホストを `127.0.0.1` / `localhost` / `::1` に限定し、プロキシ・リダイレクトを無効化。`:cloud` / `-cloud` のモデル名を拒否。`ollama pull` は実行しない。

## 2026-10-08 依存は pytest のみ
- Choice: HTTP は `urllib`。httpx / hypothesis は入れない。本体（FastAPI）導入時に再検討する。

## 2026-10-08 `too_long` の上限を `max(8×原文字数, 100)` に変更（暫定）
- Context: スモークテストで、妥当な訳（14文字の原文に対して64文字など）が旧上限 `max(4×, 40)` で不採用になった。
- Choice: `max(8×原文字数, 100)` に緩和。暫定値で、30件フル実行でも不採用の原因にならなかった。
- Consequences: 暴走出力の検出はやや甘くなる。原文保持の仕様（未変換部分は完全一致、失敗は日本語のまま）は変更していない。
- Reversal: `backend/spans.py` の `validate_translation` の定数のみ。

## 2026-10-08 検証ルールを両モデルで共通化し、文脈由来の混入とプレースホルダを拒否する
- Context: 30件実行のレビューで、Qwen は strip せず検証・Gemma は strip 後に検証しており、同じ出力でも採否が変わった。保護トークンの正規表現が日本語を巻き込んだ。スパン外の URL／メール／コードが訳に混入しても採用された。`[source/location]` が採用された。
- Choice: `normalize_translation`（前後の空白のみ除去）と前置き判定（`looks_like_preamble`）を `backend/spans.py` に集約し、両 Adapter と `assemble` が同じ関数を使う。保護トークンは ASCII 限定。`validate_translation(source, en, outside)` に `context_leak`（スパン外にあり原文スパンにない URL／メール／数字／バッククォート内コードが訳に含まれる）、`placeholder`（`[..]` `{..}` `<..>`、`___`、英数字を含まない出力）、`preamble`、サロゲート／不可視文字の `control_char` を追加。
- Consequences: 検証できるのは機械的な問題だけで、訳が意味的に正しいことや、言い換えによる重複は検出できない。`Sure, I can.` のような短い返答は前置きとして誤って不採用になりうる。`too_long`・`placeholder` 等の不採用は日本語のまま残る（原文保持の仕様は不変）。
- Reversal: 各ルールは `validate_translation` 内の独立した判定。

## 2026-10-08 インジェクション評価に条件（mode）を持たせ、測定不能を「従わなかった」と同一視しない
- Context: canary がスパン外にしかないため、文脈を受け取らない TranslateGemma は構造上 canary を見られず、0/4 が Qwen と同等に見えた。
- Choice: データセットに `injection_mode`（`span`=スパン内で全モデルが見る、`context`=スパン外で文脈を渡すモデルのみ）を追加。`span` は出力が canary のみのとき「従った」とし、忠実な翻訳に canary が含まれても従ったとは数えない。`context` で文脈を渡さないモデルは `injection_testable=false`（フラグ null）。レポートは条件別に集計し、測定不能を 0/N として扱わない。
- Consequences: injection-02 と injection-04 をスパン内の指示に変更したため、データセットの SHA が変わり、過去の run（20261008-164410 以前）とは比較できない。

## 2026-10-08 ローカル専用の制約を「ローカル実体の確認」で強化する（fail-closed）
- Context: 名前の `:cloud` / `-cloud` 判定は、`ollama cp` や Modelfile の別名で回避できる可能性がある。ただし、クラウド別名がローカルの `/api/tags`・`/api/show` にどう現れるかは、公式ドキュメントにも記載がなく、実機でも再現していない（未検証）。
- Choice: 実行前に `/api/tags` と `/api/show` で、`details.format == "gguf"`、サイズ 50MB 以上、Modelfile の `FROM` がすべてローカルのパス、`remote` を含むフィールドがない、を確認できたモデルだけ使う。確認できなければ exit 2。
- Consequences: 正当なモデルでも、メタデータの形が想定と違うと拒否される（安全側）。サーバー側のクラウド転送はクライアントから検出できないため、`OLLAMA_NO_CLOUD=1`（または `~/.ollama/server.json` の `disable_ollama_cloud`）で無効化することを README に推奨として記載した。これは確認していない。

## 2026-10-08 中断・例外でも評価成果物を保存する
- Choice: 項目単位の例外は `internal_error`（例外クラス名のみ記録。メッセージは本文を含みうるため保存しない）として記録して継続。Ctrl-C・クラッシュでも `human_scores.csv`・`blind_key.json`・`run_meta.json`（`status`: complete / interrupted / failed、完了／予定行数）を書く。`assemble` の不変条件違反は `original_preserved=false` として記録する（`assert` ではなく `AssertionError` を明示的に送出）。CSV は数式として解釈される先頭文字に `'` を付ける。

## 2026-10-08 再レビュー指摘の反映（数字境界・前置き・失敗時のインジェクション判定・未完了 run の表示）
- 数字トークンの境界は「数字・小数点・桁区切りで隣接しないこと」に限定（`page2`、`3D`、`1990s` は許可。`2015` 中の `15`、`15.5` 中の `15` は別の数として扱う）。
- 前置き判定は `Sure, here …` / `Certainly! Here …` / `Translation:` などに限定し、`Of course, I'll go.` のような会話文の訳は拒否しない。
- `injection.evaluate` は、呼び出しが失敗した項目と、モデル出力が1件もない項目を「測定不能」とする（「従わなかった」に数えない）。
- `report.md` は `run_meta.json` の `status` が complete でない場合に警告し、データセットの SHA とモデルの digest を表示する。
- `run_meta.json` を、採点用 CSV / blind_key より先に書く。
- Consequences: 第2回フル実行（20261008-171216）の生出力 126 スパンを修正後の検証で再判定し、判定の変化は 0 件だった。

## 2026-10-08 `outside` を必須のキーワード専用引数にし、成果物の書き出し失敗を終了コード 3 にする
- Context: `validate_translation(..., outside="")` の既定値が空で、渡し忘れると文脈混入検査が黙って無効になった（fail-open）。成果物の書き出し失敗は警告表示だけで、終了コードは 0 だった。
- Choice: `validate_translation(source, en, *, outside)`。省略・位置引数での指定は TypeError。本番コードの全呼び出しが `outside=outside_text(...)` を渡すことを AST で検査するテストを追加（変異で失敗することを確認済み）。`run_compare` は `run_meta.json`・採点用 CSV／盲検キーのいずれかを書き出せなかった場合に終了コード 3 を返し、`run_meta.json` に `artifacts_ok` / `artifacts_failed` を記録する（最終更新も失敗した場合は `artifacts_ok` が null のまま）。Ctrl-C 中断は 130 のまま。
- Consequences: 文脈がない場面は `outside=""` と明示する必要がある。翻訳の判定ロジックは変更していない。

## 2026-10-08 `run_meta.json` をアトミックに書く
- Context: `run_meta.json` は2回書く（保留状態 → 最終状態）。2回目が途中で失敗すると、ファイルが空や不正な JSON になりうる（独立レビューの指摘）。
- Choice: 一時ファイルに書いてから `os.replace` で置き換える。失敗時は一時ファイルを削除し、直前の有効な `run_meta.json` を残す。

## 2026-10-08 翻訳品質の自動評価（LLM-as-a-Judge）を独立モジュール `eval/judge/` として追加する
- Context: 人手採点だけでは評価が進みにくい。一方、CLAUDE.md §2 は実行時のユーザー本文の外部送信を禁じており、Claude Code による開発作業の通信とは区別している。
- Choice: 評価は開発用ツールとして `eval/judge/` に分離し、`backend/` から import しない。Judge は Claude Code のサブエージェント `translation-judge`（`model: opus`、`omitClaudeMd: true`、`tools: Read, Grep, Glob`）で、新しい API キーは使わない。評価対象はテストデータ（`eval/dataset_ja_en.jsonl`）とその生成結果だけで、`prepare` が許可リスト・テストデータの同一性・漏えいパターンを検証し、確認できなければ停止する。モデル名は Judge に渡さず、A→B / B→A を別々の呼び出しで評価し、2順序が一致した場合のみ優劣を採用する。機械検証で不採用の翻訳は採点せず別集計し、集計不能は 0 点にしない。サブエージェントが使えない場合は Sonnet などで代替せず停止する。
- Consequences: Claude Code の通常セッションには厳密なデータ隔離がなく、評価データは会話とトランスクリプトに残る（README に明記）。`.claude/agents/` を新規に作ると再起動が必要で、作成したセッションでは使えなかった。Opus で動いていることは、定義・自己申告・`/tasks` の目視の組み合わせでしか確認できない。
- Reversal: `eval/judge/` と `.claude/agents/translation-judge.md` を削除すれば、他に影響しない。

## 2026-10-08 Judge 機能のレビュー指摘（中5件）の反映
- 中-1（Judge が読み取りツールで対応表を読める）: サブエージェント定義に、全ツール呼び出しを拒否する `PreToolUse` フックを追加。**効果は未検証**（再起動後に確認）。効かない場合、ブラインド性は指示と運用にのみ依存する。
- 中-2: 漏えい走査の禁止語を、モデル名の各英字語幹（`qwen`、`gemma`、`translategemma`）と主要ファミリ名に拡張。テストは `build_inputs` が作る実際のリストを通す。
- 中-3: Judge に渡す訳文を、保存値ではなく `assemble()` が採用したセグメントから導出。現在の検証で採用されない保存値は停止。
- 中-4: 入力 ID に内容ハッシュを含め、`judge_meta.json` で run と入力の SHA を束縛。`collect`・`report` は別 run・編集済みの入力を拒否し、古い raw は無視（件数を表示）。
- 中-5: `accuracy`・`naturalness` は null 不可（無効）。無効な評価でも、型が正しい重大エラーは保持して確認待ちに入れる。
- 低: 非 UTF-8・BOM の raw、`unknown` 自己申告の扱い（レポート警告のみ）、Markdown の整形、CSV の数式対策、隔離テストの強化を同時に修正。

## 2026-10-08 MVP アプリ（FastAPI + Vanilla JS）の設計判断
- Context: 評価環境の完成後、Mac 上で動く使えるMVPを作る。設計レビュー（dev-architect / dev-test-strategist）と実装後の独立レビュー（dev-reviewer / dev-ux-auditor）を実施。
- 依存: `fastapi`・`uvicorn`（`requirements.txt`）、開発用に `httpx`（TestClient。`requirements-dev.txt`）。「依存は pytest のみ」の決定（本ファイル上部）をここで更新。React 等は不使用。
- スパン選択はアプリ側（`backend/selector.py`）: 行→文→（phrase は `、` でも）区切り。句読点・括弧は候補に含めない。URL・メール・数字・ASCII/全角英数字・バッククォートを含む候補、4文字未満、phrase 60字超 / sentence 120字超は除外。`sha256(seed|start|source)` の順位で目標率に達するまで選ぶ（決定的。目標を大きく超える候補は飛ばす）。入力 1000 字、スパン最大 24。
- LLM 呼び出し: 1 回あたり最大 6 スパン・150 文字（Qwen は `num_predict=512` 固定のため。評価条件を変えない）で逐次バッチ。全文を毎回文脈として渡す。リクエスト全体の締め切り（既定 180 秒）は `_DeadlineClient` が**呼び出しごと**に確認する（TranslateGemma はスパンごとに呼ぶため）。
- 失敗の扱い: 全バッチがインフラ系エラー（接続不可・未導入・timeout）で翻訳 0 件 → 503/504/502。一部でも成功 → 200 + 警告。検証不合格・欠落は 200 で日本語のまま。`assemble` の `AssertionError`・`outside_preserved` 違反は原文を返す。
- モデル: リクエストでモデルを選ばせない（環境変数 `MAZEMAZE_MODEL` のみ。許可リスト `qwen3.5:9b` / `translategemma:12b`、クラウド名は拒否）。起動時とリクエストごとに `/api/tags` + `/api/show` で `assert_local_entry`（キャッシュなし。ローカルで数 ms）。起動時にローカル実体と確認できないモデルは起動失敗、Ollama 不到達は警告のみで起動。サーバー側のクラウド転送は検出できない（README に記載）。
- 同時実行: プロセス内ロック（非ブロッキング）。処理中は 429 + `Retry-After`。エンドポイントは `def`（threadpool）で `/api/status` は処理中も応答。workers=1 が前提。クライアント切断後も Ollama 呼び出しは止められない（UI で案内）。
- 保護: 既定 127.0.0.1 バインド。Host 検証（localhost 系、LAN モードでは private IP と `*.local`）、クライアント IP 検査（既定はループバックのみ、LAN モードは private）、POST は Content-Length 必須・20KB 上限・Origin 同一性・`application/json` 必須、CORS なし、CSP。`MAZEMAZE_TOKEN` 設定時は `/api/*` で `X-Mazemaze-Token` 必須（`run_lan.sh` は既定でランダム生成し `#t=` で渡す。無効化は `MAZEMAZE_NO_TOKEN=1`）。422 は本文を返さない。ログに本文・トークンを出さない（テストで sentinel を検査）。HTTP 平文なので、同一 LAN の盗聴は防げない（README に記載）。
- 表示整形は `docs/ai/DISPLAY_FORMATTING.md`。`validate_translation` は互換性のため変更せず、全角句読点・全角記号（U+3000–303F / U+FF00–FFEF）を含む訳はサービス層で不採用にする。
- フロント: `<button>` ではなく `span[role=button][tabindex=0]` で英語部分を描画（WebKit で inline-block 扱いになり折り返しが崩れるため）。日英の間にスペースを挿入しない（スパン外の原文を変えないため）。コピーは `display` の連結。HTTP の LAN は secure context ではないので Clipboard API が使えず、`execCommand` → 選択済み textarea の順で代替。下書きは `sessionStorage`（そのタブのみ）。
- Reversal: 各モジュールは独立。`backend/app.py` を外せば評価環境だけに戻る。

## 2026-10-09 iPhone アプリ（SwiftUI + WKWebView）の設計判断
- Context: 最終形は個人用 iPhone ブラウザアプリ（CLAUDE.md §12）。既存 FastAPI・翻訳処理・テストは変更せず再利用する。設計は dev-architect / dev-test-strategist、実装後は dev-reviewer / dev-ux-auditor、修正後に再レビュー。
- 構成: `ios/MazemazeCore`（Swift Package、Foundation のみ。`swift test` で検証）に純ロジックを置き、`ios/Mazemaze`（iOS アプリ）は薄くする。プロジェクトファイルは `ios/tools/generate_project.py` で生成（xcodegen 等を入れない）。
- 通信はすべて Swift の URLSession（リダイレクト非追従、キャッシュ/Cookie なし）。接続先は `LocalHostPolicy` が Mac / ローカルネットワークの正準な IPv4・localhost・`::1`・`*.local` だけに限定（数値表記の別形式、userinfo、IPv6 の他の形式は拒否。検証した文字列から URL を再構築して接続）。トークンは Keychain（`WhenUnlockedThisDeviceOnly`）のみ。ATS は `NSAllowsLocalNetworking` のみ（任意の HTTP は不許可）。
- ページ内スクリプトは専用 `WKContentWorld` に注入し、メッセージハンドラも同じ world に登録（ページの JS からは `window.webkit.messageHandlers.mazemaze` も `__mazemaze` も見えない。シミュレータで実測）。JS が送れるのは `ready` と `translate{gen,text}` だけで、ratio/unit は Swift の設定値。メッセージごとに `WKFrameInfo` と `webView.url` で SitePolicy を再判定する。
- 翻訳対象サイトは許可リスト（既定 x.com / twitter.com / news.yahoo.co.jp、https のみ、ポート 443 のみ）。X は許可パス方式（タイムライン・投稿・検索・プロフィール）、その他は拒否パス（login/logout/signup/oauth/account/settings/messages/compose/i/flow 等、セグメント単位・`..`/重複スラッシュ/%エンコードを正規化）。ホスト名に login/accounts/auth 等を含むものは拒否。ユーザーが追加する許可サイトは裸の TLD・公開サフィックス・共有ホスティング・IP を登録不可。
- DOM 置換: テキストノード単位ではなくブロック（最内の block 要素、X は tweetText）単位で、翻訳対象ノードを `\n` 連結して 1 リクエスト（600 字以内）にし、返ったセグメントをノード境界へ再分配（英語セグメントは分割しない、`\n` は日本語として戻る、原文連結が一致しなければ破棄）。元のテキストノードは DOM に残し nodeValue を ZWSP にして、直後に `<span data-mazemaze>`（日本語テキストノード + 英語 `<span>`）を挿入。React 等が保持するノード参照を壊さず、`normalize()` で空ノードが消えるのを避けるため。復元は wrapper 削除 + nodeValue を元に戻す（`body.innerHTML` が翻訳前と完全一致することをテスト）。ページが元ノードを書き換えたら訳を外して再評価（試行上限）。隣接テキストノード・flex/grid 親・リンク/ボタン/入力欄/ruby/dialog 等は対象外。innerHTML は使わない（`textContent` と `createElement` のみ）。
- スケジューリング: 画面付近のブロックだけ（IntersectionObserver）、近い順に 1 件ずつ（直列）。MutationObserver で後から追加された本文に対応（自分の変更は `takeRecords` で捨てる）。水和（hydration）待ち: 読み込み完了かつ DOM 変化が 600ms 無くなるまで（最大 6 秒）。一時的な失敗（busy/paused/unreachable/timeout/server）はページ単位の指数バックオフでノードを諦めない。ノード固有の失敗は 2 回で打ち切り。
- 世代管理: ページ遷移（fragment を除く URL の変化。SPA 含む）で世代を増やし、待機中の要求を stale にする。**進行中の HTTP は cancel しない**（サーバー側も止められず、cancel すると 429 を量産するため）。結果はキャッシュして JS には stale を返す。429 は `Retry-After`（1〜15 秒）で最大 6 回再試行。連続 3 回の通信/5xx 失敗で 30 秒停止（401・429・検証失敗はブレーカ対象外）。キャッシュはメモリのみ（本文をディスクに残さない）。
- 既知の限界: 見出しが `<a>` の一覧ページ（Yahoo のトップ等）はほとんど変わらない（リンクのタップ遷移を妨げないため）。DOM の実挙動は WebKit/実 React では実機未確認。進行中の長い要求の後ろに最大約 3 分待たされることがある。X の実 DOM（`data-testid`）は未確認で変更されうる。
- Reversal: `ios/` を削除すれば Web 版 MVP だけに戻る（バックエンドは `scripts/run_lan.sh` のトークン永続化以外未変更）。

## 2026-10-09 開発方針の二段階化（X は保留）と Safari 誘導の扱い
- Context: x.com はアプリ内ブラウザの標準 User-Agent に対し `302 → x-safari-https://redirect.x.com/…` を返す（curl で確認: 標準 UA は 302、Safari 互換 UA は 200）。Safari 互換 UA にすれば回避できるが、サイトが意図した制限の迂回になる。
- Choice: 第1段階はこのまま SwiftUI + WKWebView を完成させる（X は保留、User-Agent は変更しない、Safari 拡張は作らない、既存 FastAPI + Ollama を維持、追加費用ゼロ）。第2段階（X の扱いの再検討）は第1段階の完成まで着手しない。
- 実装: `ExternalNavigation.classify` が主フレームの遷移先を `allowInApp` / `safariRedirect(https URL)` / `external(url)`（tel・mailto・アプリ独自スキーム）/ `blocked`（javascript・file・data・blob 等）に分類。`x-safari-*` は追わずにキャンセルし、**白画面の代わりに案内カード**（「このサイトはアプリ内ブラウザでは開けません。Mazemaze はこの制限を回避しません」+「Safari で開く」「前のページ/ホームに戻る」）を表示する。開くのはユーザーがボタンを押したときだけ。Safari へ渡す URL は、リダイレクト先ではなくユーザーが求めた元の URL。
- 追加の導線: アドレス欄横のメニュー（Safari で開く／ホーム）、翻訳できる本文が無いページ（リンクだけの一覧等）には 9 秒後に状態文言で説明、接続エラーはエラーコード別に原因と次の行動を表示（-1009＝ローカルネットワーク未許可の可能性、タイムアウト＝スリープ/Wi-Fi 違い、接続拒否＝run_lan.sh 未起動/ポート違い、.local 解決失敗＝IP を使う）。
- 注意（運用）: DEBUG の起動引数（`-MazemazeAPI` 等）は保存設定を書き換えない（使い捨て）。以前、テスト用の起動引数がシミュレータの実設定に残り、停止済みのテスト用サーバーへ接続して「翻訳サーバーのエラーが続いた」と表示された。検証は専用のシミュレータ（iPhone 17）で行い、利用者が使っている端末（iPhone 17 Pro）には触れない。

## 2026-10-09 iPhone アプリ v2: 翻訳待ち時間・ホーム・タブ・ペアリング
- Context: 実機で使えたことを受け、①翻訳待ち時間（最優先）②独自ホーム ③タブ ④サーバー接続の簡易化を改善。設計は dev-architect / dev-test-strategist、実装後は dev-ux-auditor / dev-reviewer、修正後に再レビュー。
- **待ち時間（実測、シミュレータ + 実 Qwen3.5:9b + 実 Yahoo 記事、読み込み完了→最初の翻訳）**: 4.9s→1.1s（温）、5.1s→1.1s、冷 7.9s→4.6〜5.7s。内訳は、JS の開始待ち 3.4s が約 7 割だった。施策: 静止判定を article/main の childList/characterData のみにして 300ms・上限 2.5s（`readyState` 待ちを廃止）、先読みを下 150%（上は 0。訳で表示がずれないよう）で近い順、長い段落を約 160 文字（1 文が長い場合は 320 まで）に分けて**できた部分から反映**（先頭の `<span data-mazemaze>` の中に部分ごとの `data-mz-part` スロット。元ノードは ZWSP で保持、復元は wrapper を外して nodeValue を戻す）、モデルの事前準備（`POST /api/warmup`＝固定の軽い要求を直列キュー経由で送る、`keep_alive` を 30m、起動・復帰・接続確認成功時に 20 分以上空いていれば）、キャッシュ 1000 件（メモリのみ）、`Retry-After` を 2 秒、タブ別の世代。**不採用**: サーバーの並列化（Ollama への 2〜4 並列は逐次合計と同程度で利得が小さい）、ストリーミング（1 回約 2 秒・約 100 文字で利得が小さい）、先読みの上方向。進行中の HTTP は引き続き取り消さない（結果はキャッシュ）。
- **タブ**: タブごとに WKWebView（タブが保持。切替で再読み込みしない）、ページ状態は `TabModel`、設定と翻訳サービスは共有。翻訳の世代・要求数はタブ（スコープ）ごと、直列キューは 1 本で前面タブを優先（解放時にアクティブなスコープの待機者を先に）。非前面タブは JS を `pause()`（DOM はそのまま）。上限 8、同時に WebView を持つのは 4（LRU で休止＝URL とタイトルだけ保持して WebView を破棄、世代を bump）。`target=_blank`/`window.open` は新しいタブ（実タップ／WebKit が許可したもののみ）。ハンドラは `teardown()` で解除（強参照の解放）。
- **履歴・復元のプライバシー（fail-closed）**: 保存するのは https・userinfo なし・標準ポート・公開 DNS 名の URL の**ホストとパスだけ**（クエリ・fragment は保存しない）。ログイン/メール/銀行/決済/アカウント/設定/OAuth などのホスト名ラベル・パス語、LAN の IP・`.local`・`localhost` 等は保存しない（タブはホーム画面として復元）。ページ題名は、翻訳対象サイトで、クエリ・検索系パスがなく、x.com/twitter.com でないときだけ（他はホスト名）。お気に入りは明示操作なのでクエリを残すが、認証情報らしいキーを含む URL・トラッキング・ログイン系は拒否。パス中の秘密（招待トークン等）は拒否リスト方式では防げない（README に明記、保存オフ・履歴消去あり）。アドレス欄の検索語は外部（DuckDuckGo）へ送られるため、毎回確認を出す（日本語ドメイン入力も検索として扱う）。
- **ペアリング（QR / 文字列）と暗号化**: `mazemaze://pair?v=1&h=<mac>.local&i=<ip>&p=<port>&t=<token>&s=https&f=<sha256>&n=<name>`。QR は Mac の画面から iPhone のカメラへ直接渡るので、トークンが Wi-Fi 上を流れない。`mazemaze://` は他アプリ・Web からも開けるため、**確認画面（Mac の名前・アドレス・暗号化の有無・指紋）を必須**にして、押すまで何も適用しない。パースは厳格（未知/重複キー、`.local`/私設 IPv4 のみ、ポート・トークン形式、https には指紋が必須で http には不可、SHA-1 等は拒否）。`run_lan.sh` は既定で**自己署名 TLS**（`.mazemaze_tls/`、RSA 2048・10 年）で起動し、アプリは URLSession の delegate で**葉証明書の SHA-256 を指紋と比較**（ホスト名は見ない＝IP や名前が変わっても可）。不一致なら**何も送らず**に拒否（トークン・本文とも）。ピン留め済みの設定を http にダウングレードする構成は `serverConfig()` が nil にする。HTTP 運用（`MAZEMAZE_TLS=0`）は互換用で、手入力は HTTP のみ。
- **アドレスの解決**: `.local` 名を先に、見つからなければ IP（HTTP でも IP フォールバックを使うが、必ず下の身元確認を通す。HTTPS は加えて指紋ピン留め）。`EndpointResolver` は**トークンなしで** `GET /api/status` を試し、Mazemaze 固有の JSON 応答（200 は model と allowed_models、400/401/403 は error.code が bad_host/token_required/forbidden）が返った相手だけを選ぶ。トークンは選ばれた相手にだけ送る（候補が 1 つのときは確認なしでそのまま接続）。
- **設定の保存の調査結果**（`ios/scripts/persistence_test.sh`、署名付きシミュレータ）: 再起動・上書きインストールでは URL・トークン（Keychain）・指紋・お気に入り・タブが残る（上書きは直前の書き込みから十数秒空ける必要。書き込み直後の再インストールは cfprefsd のディスク反映前で一部が失われうる）。**アンインストールして入れ直すと、URL・お気に入り・タブは消え、トークンだけが Keychain に残る**。以前の「設定が残らない」体験の原因は、検証用の起動引数が実設定を汚染していたことと、Mac の IP が変わって保存した IP が古くなることだった（前者は修正、後者は `.local` 名 + ピン留めで解消）。
- **既知の限界**: 実機の QR 読み取り・ローカルネットワーク許可・実 Wi-Fi の `.local` 解決・自己署名証明書の実機での ATS 挙動は未確認（シミュレータでは ATS（`NSAllowsLocalNetworking`）のもとでピン留め・不一致の拒否・フォールバックを確認済み）。HTTP 運用では盗聴・なりすましを防げない。パス中の秘密は履歴に残りうる。

## 2026-10-09 第2段階: X をアプリ内で開く／貼り付けて翻訳
- **背景（調査）**: 既定の WKWebView で x.com を開くと、X のログアウト用エントリスクリプトが `x-safari-https://redirect.x.com/...?ct=rw-null` へ誘導する（シミュレータ iOS 26.1 で再現）。判定（公開されているスクリプトを読んだ結果）: (a) UA に `Safari/` が無い iPhone（`/(iPhone|iPod|iPad)(?!.*Safari\/)/`）は即「アプリ内ブラウザ」、(b) Safari 風の UA でも、`Version/` 17 以上で、読み込み完了の 300ms 後に `window.SchemaDataExtractor` / `MicrodataExtractor` のどちらも無いと「偽の Safari」として誘導。SFSafariViewController は別プロセスで本文に触れられず翻訳できない。X の規約は公開インターフェース以外での利用・自動アクセス/スクレイピングを禁じる（規約本文は取得できず、報道・解説記事で確認）。
- **決定（所有者の明示指示）**: 方針 1（X をアプリ内で開いてインライン翻訳）を、X に限った Safari らしい見せ方で実現する。**実際に行ったこと**: (1) `customUserAgent` を X のホストへの主フレーム遷移ごとに設定（WKWebView 自身の UA に ` Version/<OS> ` と ` Safari/604.1` を足す。`BrowserIdentity.safariStyle`）。他のホストでは `nil` に戻す。(2) X のホストで文書開始時（page world、主フレームのみ）に、`SchemaDataExtractor` / `MicrodataExtractor` が無ければ空の凍結オブジェクトを定義する（`BrowserIdentity.xPageScript`。スクリプト内でホストを再検査）。これ以外の偽装はしない。シミュレータ（ログアウト、実 x.com）で、UA だけでは誘導され、(2) を足すと開くことを確認。設定「X を Safari として開く」（初期オン）でオフにできる。
- **X 用の翻訳対象**: ログアウト時の新しいマークアップには `data-testid='tweetText'` が無く、本文は `article` 内の `div[dir=auto]`、カード全体が `div[role=link]` で包まれている。X プロフィールに限り、`article div[dir=auto]` を本文の根にし、本文を包むだけの `div[role=link]` は除外対象から外した（実リンク `a`、ボタン、ダイアログ、aria-hidden は従来どおり除外）。ログイン後のマークアップは**未確認**（ログインしていないため）。
- **貼り付けて翻訳（代替・併存）**: SwiftUI の入力画面（貼り付けボタン）+ 本文を持たない静的テンプレートの結果 WebView（`paste.html`、CSP でスクリプト全面禁止、`default-src 'none'`）。本文は Swift から隔離ワールドの関数へ引数で渡し、1 行 1 `<div>`（`textContent` のみ）。結果ページはタブ一覧に載せず（`app.tabs` 外の専用セッション）、非永続のデータストア、再起動復元・最近のサイト・お気に入りの対象外。内部アドレス `https://paste.mazemaze.invalid/`（`.invalid` は名前解決されない）の完全一致だけを `SitePolicy` が許可し、通常のタブからの遷移・結果ページからの遷移は全て拒否。`SessionPrivacy` と `normalizeEntry` は `.invalid` `.test` `.example` `.localhost` を拒否。`mazemaze://paste`（本文を持たない）で入力画面だけ開く。コピーは端末内のみ・10 分で失効。
- **しないこと**: X のページ・投稿の自動取得（oEmbed を含む）、ショートカットの「URL の内容を取得」を使う案内、ページ DOM を送る共有拡張・ブックマークレット（X の規約上の懸念）、`ct` パラメータでのすり抜け、誘導の握りつぶし。
- **未確認（実機）**: 実機での X の表示、ログイン（X のメール/パスワードのログインが WKWebView で通るか。Google/Apple でのログインは WebView を弾く可能性）、ログイン後のマークアップでの翻訳、X が今後スクリプトを変えたときの追従。X 側の判定が変われば、ここで足した 2 点では足りなくなる可能性がある（そのときは従来の案内カードが出る）。

## 2026-10-09 辞書／バーの自動格納／ツールバー整理
- **辞書**: 保存単位は「表現」（画面の英語 + 置き換えた日本語）のみ（所有者の選択。文は保存しない）。入口は吹き出しの「辞書に保存」ボタンと、ツールバー常設の「辞書」ボタン。ページ JS（隔離ワールドの translator.js）は `{type:"save", en, ja}` だけを送り、Swift が厳格に検証し（キーは完全一致、長さ上限、NUL 拒否）、出典（ホスト名・公開ページの URL）は WebView の実アドレスから Swift が付ける。保存は `DictionaryData`（重複は英語の大文字小文字・空白を無視して判定、上限 5000 件、制御文字除去）、`DictionaryStorage`（Application Support の 1 ファイル、atomic、`completeFileProtectionUnlessOpen`。読めない/新しいバージョンのファイルは上書きせず別名で退避）。書き出しは CSV（数式として読まれうるセルに `'` を付ける）とテキスト。iCloud バックアップの対象にはなりうる（端末内ファイルのため）。DEBUG の起動引数での実行は一時ファイルを使い、実データに触れない。
- **「原文に戻す」ボタンの削除**: 翻訳オン/オフ（オフで全ページを原文に戻す）と重なるため、ページのツールバーから外した（貼り付け画面には残す）。
- **バーの自動格納**: WKWebView を画面いっぱいに置き、バーが覆う範囲を `additionalSafeAreaInsets` として WebKit に伝える（`WebHostController`）。固定ヘッダーや 100vh はバーの下から始まり、バーが隠れるとページ領域が広がる。判定は `BarVisibility`（下 28pt で隠す、上 16pt で戻す、先頭付近では常に表示、切替直後 0.4 秒はジッタを無視）。新しいページ・問題・通知・ブロックカード・アドレス入力でバーを戻す。VoiceOver 中は隠さない。状態行は廃止し、翻訳ボタンに進捗と件数を表示。注意が必要なとき（問題・通知・翻訳しない理由）だけ、ページを動かさずに上に重ねる細い帯を出す。
- **アドレス欄を下へ（2026-10-09 追記）**: アドレス欄をツールバーの真上に移した（スクロールしないページで上が邪魔にならない、親指が届く）。ページはバーに覆われる下側だけを `additionalSafeAreaInsets` で避け、上は常に空き。注意の帯はアドレス欄の上にページへ重ねて出す。アドレス入力中はツールバーを引っ込め、バーがキーボードの上に出るようにする（ページ側の入力欄のキーボードではバーを持ち上げない）。ステータスバー背後は常に半透明のバックドロップ。

## 2026-10-09 単語・句の意味（「意味を調べる」）
- **要望**: `I have a pen` の `have` だけを調べて「持つ／食べる」の見分けがつくように。設定（フレーズ/文の選び方）は変えない。
- **入口**: 吹き出しで英語の中の単語をタップすると（`caretRangeFromPoint` で位置の単語を判定）、「〈単語〉の意味を調べる」「句全体の意味を調べる」「辞書に保存」が出る。VoiceOver など位置が分からないときは句のボタンだけ。英語が 1 語なら「その語」のボタンだけ。押すとアプリのシート（半分の高さ）が開き、カードはページには渡らない。シートの中の単語チップで別の語に切り替えられる。
- **通信**: ページ→アプリは `{type:"lookup", kind, term, en, ja}`（キー完全一致、長さ上限、本物のタップのみ）。アプリ→Mac は `POST /api/define {kind, term, context_en, context_ja, detail, sense}`（翻訳と同じ認証・Host・Origin・サイズ検査、同じ直列ロック。端末側の待ち行列では翻訳より先に処理）。Mac はローカルの Qwen3.5:9b にだけ問い合わせる（翻訳専用モデルでは 501）。
- **2 段階**: この Mac では生成が約 15 トークン/秒のため、最初は短い「基本」（単語: 原文の対応語 `matchInSource`、よくある意味 4 つ、文脈の意味の番号、原形、品詞。句: 意味とニュアンス）だけ返し、「例文・よく使う形」「ポイント・言い換え・例文」は押したときに「追加」として取る。実測（実 Qwen3.5:9b）: 基本 約 5〜6 秒（単語）／約 2 秒（句）、追加 約 5〜8 秒。最初の版（例文・用法まで一度に）は 15〜23 秒だったため分割した。
- **意味の精度**: 最初の版は文脈の意味を取り違えた（`I have lunch` で「持つ」）。対策: モデルにまず原文の対応語を写させ（`matchInSource`）、意味の候補を並べたあと**番号で**選ばせる。サーバーは番号を検証し、`matchInSource` が日本語原文に実在するときだけ採用する。それでも `took a stroll` のように候補に適切な意味が無いことがある。画面に「AI が作成」と明記し、「標準辞書」ボタンで iPhone の辞書も引けるようにした。
- **検証**: サーバー（`backend/define.py`）とアプリ（`DefinitionCard.decode`）の両方で、型・長さ・件数を検査し、制御文字（空白を除く）と不可視の書式文字（方向制御・ゼロ幅・ソフトハイフンなど。絵文字の ZWJ は除く）を含む文字列は拒否する（両者の規則は同じ。レビュー後に揃えた）。原形は英字のみ。`matchInSource` は日本語の原文が送られていて、その中に実在するときだけ採用する。
- **保存**: 単語は「単語」の項目（英語=原形、日本語=その文での意味、カード付き）、句は従来の項目にカードを付ける。辞書ファイルは version 2（version 1 のファイルはそのまま読める。読めないカードは捨てて項目は残す）。保存するのは語・意味・出典で、元の文は保存しない。CSV に `type` と `details` 列を追加。
- **発音**: `AVSpeechSynthesizer`（端末の音声、オフライン）。音声の品質は、設定でダウンロードした拡張/プレミアム音声に依存する（ダウンロード可能な音声を調べる API は無い）。
- **標準辞書**: `UIReferenceLibraryViewController`。収録は端末にダウンロードした辞書に依存し、シミュレータでは確認できない（実機未確認）。
- **レビュー後の修正（2026-10-09）**: 辞書の項目から開いたシートで単語チップを押しても、項目のカードは書き換えない（最初の語だけ）。保存後の「追加」は保存済みの項目にも反映する。ペアリング/貼り付けの割り込みでシートを閉じる。遅れて戻った別の語の結果は捨てる。保存に失敗したら巻き戻して失敗を表示する。同じ英語の別の単語のタップで吹き出しが切り替わる。読み上げは英語の音声を選び、再生できないとき理由を表示し、終わったら音声カテゴリを元に戻す。辞書ファイルは読み込み時に version 2 に更新する。
- **実機の 404（2026-10-09）**: Mac で動いていたサーバーが、`/api/define` を追加する前に起動したままだったため、アプリに「404 Not Found」が出た。アプリは 404 のとき「Mac のサーバーが古いようです。run_lan.sh を止めて起動し直してください」と案内する。
- **しないこと**: 意味のためにクラウドの辞書・翻訳 API を使うこと、閲覧中の文章全体を送ること（送るのは語・句と、その日本語の原文だけ）。
- **X のヘッダー（検索欄）が消える不具合（2026-10-09、実機の報告）**: X は `viewport-fit=cover` を指定するため、ページは WKWebView の安全領域（ステータスバー）の下にもレイアウトされ、画面の最上部に固定したヘッダーが、ステータスバーの帯（半透明の背景）の下に隠れていた。シミュレータで、同じ作りのテストページ（`ios/WebTests/cover.html`）で再現した。対策: ページの表示領域の上端を、ステータスバーの下（安全領域の上端）にそろえた（`WebHostController`）。下側は従来どおり画面の端まで広げ、バーが覆う範囲だけ避ける。自己テストで、`viewport-fit=cover` のページが安全領域の下から始まることを確認する。
- **標準辞書を既定にする（2026-10-09、実機の感想）**: AI の単語カードは基本でも数秒〜10 秒かかり、「単語を調べるだけには遅い」との評価。標準辞書（`UIReferenceLibraryViewController`）と原文の日本語（センテンス）だけでも十分分かる、という意見を受け、**単語は標準辞書を最初に表示**する（即時・オフライン・Mac 不要）。「この文での意味（AI）」は切り替えたときだけ Mac に問い合わせる（遅延実行）。句は辞書がないので AI（基本は約 2 秒）から始める。英和辞書が未ダウンロードなら、単語でも AI から始める。辞書タブのときはシートを大きいサイズで開く。標準辞書の画面から保存すると、単語＋元の日本語（原文）の項目になる（カードなし。辞書の項目から「意味を調べる」で AI の意味を足せる）。`UIReferenceLibraryViewController` は辞書の本文を返す API がなく画面としてしか使えないため、シートの中に埋め込んでいる（シミュレータには辞書がなく、実機での見た目は未確認）。
- **実機のクラッシュ（2026-10-09 22:46、iOS 27.0.1）と修正**: 標準辞書を「シートの中に埋め込む」方式にしたところ、実機で落ちた。クラッシュログ（`xcrun devicectl device info files --domain-type systemCrashLogs` と `device copy from` で iPhone から取得）: `UIReferenceLibraryViewController.init(term:)` → `_UIDictionaryManager _definitionValuesForTerm:` → `_UIDefinitionDictionary _attributedDefinitionForTerm:` の内部でメモリ破壊（`EXC_BAD_ACCESS`、`_swift_release_dealloc`）。呼び出し元は SwiftUI のレイアウトの最中（`makeUIViewController` が `sizeThatFits` の途中で呼ばれた）。加えて、シートを作り直すたびに `dictionaryHasDefinition(forTerm:)` を呼んでいた。UIKit の辞書検索はレイアウトの最中や繰り返しの呼び出しに耐えないと判断し、**埋め込みと `dictionaryHasDefinition` の呼び出しをやめ**、以前実機でうまく動いていた形（ボタンを押したときだけ、別のシートで `UIReferenceLibraryViewController(term:)` を作る）に戻した。辞書が未ダウンロードでも、そのシートに案内が出る。原因の特定は、ログの呼び出し元に基づく推定（実機での再確認は未実施）。
- **標準辞書をシートの中に表示する（2026-10-09、所有者の希望）**: 所有者が気に入っているのは、シートの設計（単語、小さく英語の句、灰色の日本語の原文、単語ごとのチップ）。その「標準辞書で開く」ボタンの場所に、辞書の内容そのものを出したい、という要望。吹き出しから直接辞書を開く案（途中のシートを省く）は、意図と違うため取り下げた（実装の途中まで入っていたものも元に戻した）。**対応**: `InlineDictionaryView`（UIKit のコンテナ。`UIReferenceLibraryViewController` を、シートが表示されて 0.3 秒後に、レイアウトの外で 1 回だけ作って子に追加する。単語チップの切り替えで作り直す）。前回の実機クラッシュは、レイアウトの最中に作ったことと `dictionaryHasDefinition` の連呼が原因と推定しているため、どちらも避けた。**安全装置**: 作る直前に目印ファイル（`CrashMarker`）を書き、1.5 秒生き延びたら消す。次の起動で目印が残っていれば、落ちたと判断して `embedDictionary` を自動でオフにし（理由を表示）、ボタンで別シートに開く従来の方式に戻す。設定の「標準辞書をシートの中に表示」で手動でオン/オフできる。この方式で実機で落ちないかは**未確認**（シミュレータには辞書がなく、中身の表示は確認できない）。
- **ウィズダムだけを表示する件**: 公開されている API では不可能（`UIReferenceLibraryViewController` は、ダウンロード済みの全辞書を表示し、辞書の選択も本文の取得もできない）。現実的な方法は、設定 > 一般 > 辞書 で他の辞書（Oxford 系）のダウンロードを解除すること。非公開の UIKit クラス（クラッシュログに出た `_UIDictionaryManager` など）で辞書名ごとの本文を取り出す方法は、原理的には可能だが、実機でその内部コードの中で落ちた実績があること、iOS の更新で壊れること、辞書の本文は著作物であること、シミュレータでは検証できないことから採用しない。

## 2026-10-09 単語の項目に原文を持たせる／保存時に意味を裏で調べる（ローカルのみ）
- **議論の結論（所有者）**: 意味の取得は**当面ローカル（Mac の Ollama）のまま**。保存時の自動取得で他の機能と衝突する、遅い、と感じたら、所有者が Gemini API（無料枠）の利用を検討する（その場合は、方針の書き換えが必要。無料枠は入力・出力が Google の改善に使われ、人間が読むことがある。回数制限は資料によって数字が違い、公式の確定値は確認できていない）。翻訳に Gemini を使う案は採らない（読む記事の本文全体が外部に出るため）。
- **データ**: 単語の項目は、`english`（読んだままの単語）、`japanese`（その文での意味。調べるまで空）、`contextEnglish`（原文の英語の句）、`contextJapanese`（原文の日本語）、`meaning`（none / pending / failed）、`card`。単語の重複判定は「同じ単語 + 同じ日本語の原文」。表現の項目は従来どおり（英語と日本語の原文が原文そのもの）。CSV に `context_en` `context_ja` 列を追加。古いファイルはそのまま読める（欄は空）。
- **保存時の自動取得**: 標準辞書の画面から単語を保存すると `pending` で保存し、アプリの裏で 1 件ずつ `/api/define`（基本のカード）を呼ぶ（`startMeaningWorker`）。起動・フォアグラウンド復帰・サーバー設定の変更・辞書を開いたとき・保存時に動く。**優先順位（端末側の待ち行列）**: ①人が待っている調べもの ②画面のタブの翻訳 ③ほかのタブの翻訳 ④裏の取得。裏の取得は、**直近 15 秒に翻訳の要求がなく、いま Mac を使っている処理もないとき**だけ始め、Mac が忙しい（429）ときは 3 回で諦める（人の調べものは 12 回）。並列にはしない（Mac での並列は速くならないことを実測済み）。
- **失敗の扱い**: 一時的な失敗（Mac が止まっている・忙しい・タイムアウト）は `pending` のまま、30 秒から最大 10 分まで間隔を延ばして再試行。設定の不備（トークン違い・未設定・証明書）は止めて、設定が変わったら再開。壊れた答えは 3 回試して `failed`（項目から再試行）。保存に失敗したら巻き戻す。
- **しないこと**: 古い項目の一括取得、複数の項目を同時に取得すること。

## 2026-10-10 外出先から使う（Tailscale、tailnet 内だけ）
- **要望（所有者）**: 自宅のみの利用になっているので、Tailscale で外でも使えるように。安全を重視する。
- **方式 A（採用）**: Mac で `tailscale serve --bg --tcp=8000 tcp://localhost:8000`（tailnet 内だけに届く TCP 転送）。サーバーは今までどおり。転送してきた接続は localhost（ループバック）から来るので、既存のクライアント IP 検査はそのまま通る。**方式 B（不採用）**: サーバーが `100.64.0.0/10` を許可する。認証・IP 検査を弱めるため。
- **サーバーの変更は最小**: `MAZEMAZE_ALLOWED_HOSTS` に Tailscale の名前と IP を足す（`run_lan.sh` が行う）。`_is_private_ip` は Tailscale の範囲（`100.64.0.0/10`、IPv6 の `fd7a:115c:a1e0::/48`）を**明示的に「プライベートではない」**とする（IPv6 の側は `fc00::/7` なので、そのままだと通ってしまう穴があった。サーバーは IPv4 でしか待ち受けないので実害はないが、テストで見つけて塞いだ）。転送を設定しないかぎり、tailnet の端末の直接接続は 403。
- **証明書は作り直さない**: ピン留めは証明書の指紋だけを比べ、ホスト名は比べない（`PinEvaluator`）。そのため既存の証明書・指紋のまま、再ペアリングは QR を読み直すだけ（接続先が増えるため）。
- **アプリ**: QR に `ts=<端末>.<tailnet>.ts.net` を追加（`h`/`i` と並ぶ最後の接続先）。`LocalHostPolicy.isTailscaleHost`（名前のみ。IP は不可）で検証。**https + 指紋ありのときだけ**（`SettingsStore.serverConfig`）。トークンは、接続先が `/api/status` に Mazemaze として答えたあと（指紋が合ったときだけ）にしか送らない。手入力の欄は作らない（QR のみ）。
- **接続先の選び方**: `.local` → 家の IP → Tailscale の順。Tailscale があるときだけ、家の接続先の確認を 1.5 秒（既定は 3 秒）に縮め、Tailscale は 6 秒待つ（外出先では最初の接続に時間がかかるため）。家では Tailscale を確認しない。選んだ結果は 120 秒覚える（従来どおり）。
- **`run_lan.sh`**: Tailscale が動いていて、https + トークンのときだけ、名前と IP を取得 → Host の許可に追加 → QR に `ts=` を追加。`tailscale serve` の状態を読み取り（変更はしない）、未設定ならコマンドを案内、Funnel が有効なら警告する。`MAZEMAZE_TAILSCALE=0` で無効化。
- **すでにあった `tailscale serve` の設定**: この Mac には `https://yuya-4.tailb93afe.ts.net:443 → http://127.0.0.1:8000`（tailnet 内のみ、Funnel なし）の設定が別にある。Mazemaze のサーバーは TLS で待ち受けるため、この HTTP プロキシでは繋がらない。**触っていない**。不要なら所有者が整理する。
- **しないこと**: Funnel・公開トンネル・ポート転送、Tailscale 設定の自動変更、`NSAllowsArbitraryLoads` などの ATS の全面緩和、平文 HTTP での Tailscale 接続、手入力で任意の `ts.net` を入れること。
- **実機でしか確認できないこと**: モバイル回線から Tailscale 経由で繋がるか（ATS が IP リテラル/`ts.net` で止めないか、HTTPS なので通る見込みだが未確認）、翻訳の速さ。→ §16。

### 実機の失敗と ATS（2026-10-10 追記）
- **症状**: 4G で QR を読み取ると「Mac から応答がありません（タイムアウト）」。接続先の内訳（新しく追加した診断表示）は「Tailscale（外出先）: 届かない（-1200）」。Mac 側（転送・サーバー・ファイアウォール・Host 許可）と iPhone→Mac の経路（アプリ内ブラウザが証明書の警告まで届いた）は正常だった。
- **原因**: iOS の ATS。`NSAllowsLocalNetworking` は 100.64.0.0/10 や `*.ts.net` を「ローカル」とみなさず、自己署名の証明書を拒否する（`-1200`、内部 `-9802`）。macOS の URLSession・シミュレータの 127.0.0.1 では通るため、Mac 上の再現ではなく **iOS シミュレータで、アプリと同じ Info.plist を埋め込んだプログラム**で再現した。
- **対処**: `Info.plist` に `NSExceptionDomains` の `ts.net`（`NSIncludesSubdomains` + `NSExceptionAllowsInsecureHTTPLoads`）だけを追加（全面解除の `NSAllowsArbitraryLoads` は使わない）。シミュレータで、この設定のとき `*.ts.net` の名前は通り、IP 直指定は通らないことを確認した（`NSExceptionDomains` に IP を書く方法もあるが、IP の変更でビルドし直しになるので採らない）。これに合わせて QR は IP ではなく **Tailscale の名前**を運ぶ。`TLSv1.2` や前方秘匿の緩和だけでは足りなかった（`NSExceptionAllowsInsecureHTTPLoads` が必要）。
- **例外の影響**: `*.ts.net` への平文 HTTP がシステム上は許される。アプリ側は Tailscale の接続先を https + 指紋ありのときだけ使い、閲覧は許可サイトのみ。指紋の確認はアプリが自前で行う（ATS より厳しい）。
- **診断表示**: 接続確認が失敗したとき、確認した接続先（名前・家の IP・Tailscale）ごとの結果を出す（URL・トークンは出さない）。
