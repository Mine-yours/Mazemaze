# Handoff state

## iPhone アプリ v2（2026-10-09 更新・最新）
実機で動作確認できた初版（`456e845` 以降の未コミットの変更を含む）に対し、①翻訳待ち時間 ②独自ホーム ③タブ ④サーバー接続（QR ペアリング・暗号化）を実装した。**すべて未コミット**（承認待ち）。**v2 の実機確認はこれから**（`docs/ai/IPHONE_DEVICE_CHECKLIST.md`）。（当時は X・Safari 拡張・UA 変更は対象外としていたが、その後の第2段階で X に限り UA 変更を行った。末尾の「第2段階」節と `DECISIONS.md` を参照）。

### 改善内容と実測
- **翻訳待ち時間**（`ios/scripts/bench.sh`、シミュレータ + 実 Qwen3.5:9b + 実 Yahoo 記事、ページ読み込み完了→最初の翻訳）: 記事 A 温 4.9s→**1.1s**、記事 B 温 5.1s→**1.1s**、冷 7.9s→4.6〜5.7s（モデル読み込みの約 5s が残る）。改善前は JS の開始待ち 3.4s が約 7 割。1 リクエスト（約 100 文字）は p50 約 2s で、モデル律速。Ollama への並列度を上げても利得が小さいことを実測（2 並列 3.8s vs 逐次 3.1s）し、サーバーは直列のまま。bench の初回 2 回はページ読み込みが完了せず（シミュレータ直後のネットワーク）再実行で成功した（ハーネスの不安定さ）。
- **ホーム**: 独自ホーム（接続状態・暗号化の有無・お気に入り・おすすめ候補（強制しない）・最近のサイト・検索の説明）。検索語は毎回確認のうえ DuckDuckGo へ。履歴は fail-closed（ログイン・メール・LAN・クエリを保存しない）。
- **タブ**: 作成・一覧・切替・閉じる、上限 8 / 同時に WebView を持つのは 4（休止）、切替で再読み込みしない、タブ別の翻訳世代と前面優先、`target=_blank`/`window.open` は新規タブ、前回のタブの復元（安全なページだけ）。
- **接続**: QR / 貼り付けのペアリング（確認画面必須）、自己署名 TLS の指紋ピン留め（不一致は何も送らず拒否）、`.local` 名 + IP フォールバック（ピン留め時のみ）、トークンなしの Mazemaze 判定プローブ、原因別のエラー文言、保存の調査（再起動・上書きで残る／アンインストールで URL 等は消えトークンだけ残る）。

### 確認した証拠
- `swift test`（`ios/MazemazeCore`）**106 件**、`node ios/WebTests/run_dom_tests.mjs`（実 Chrome）**71 件**、`.venv/bin/python -m pytest -q` **506 件**、`./ios/scripts/simulator_selftest.sh`（専用の iPhone 17、実 WKWebView + 実 uvicorn（TLS）+ 偽 Ollama）**36 項目**（タブ・休止・世代・ピン留め成功/不一致拒否・フォールバック・サーバー側に不一致の要求が届かない・ログに本文/トークンなし）、`./ios/scripts/persistence_test.sh`、実機向け Release ビルド成功（デバッグ用の起動引数は含まれない）。`run_lan.sh` は HTTP/TLS の両モードで実起動を確認。QR は CoreImage で往復デコード（一致）。
- 独立レビュー: 設計（dev-architect、dev-test-strategist）→ 実装後（dev-reviewer: 高2・中7・低11、dev-ux-auditor: 高5・中9・低6）→ 高・中の指摘を修正（bash 3.2 での HTTP 起動失敗、設定シートがペアリングを巻き戻す、証明書エラー/暗号化表示の矛盾、無認証プローブの誤認と http でのフォールバック、タイトルへの検索語混入、短い先頭ノードで翻訳が抜ける、履歴消去の再保存 など）→ 再レビュー（実施中）。
- 守った制約: 原文保持（DOM の完全復元テスト、部分反映の途中でも完全復元）、ローカル Ollama のみ、FastAPI の認証/Host 検証は不変（`/api/warmup` も同じ検査）、既存の評価成果物は不変。backend/llm のアダプタは `keep_alive` を 30m にした（評価成果物・Judge 設定は不変）。

### 未確認（実機でしか分からないこと）
- v2 全体の実機動作。特に QR のカメラ読み取り、ローカルネットワーク許可ダイアログ後の最初の接続、実 Wi-Fi での `.local` 名の解決と IP フォールバック、自己署名証明書のピン留めの実機での挙動、`window.open` の新規タブ、実機でのタブ休止、VoiceOver・AX5・ダーク、長い記事での発熱・負荷。
- X の挙動（保留）。React/Next の水和（ハイドレーション）と DOM 書き換えの相互作用（コンソールエラーの有無）。
- パス中に秘密が入る URL（招待リンク等）は拒否リスト方式では履歴に残りうる。

### 次の最小アクション
1. v2 のコミット承認（私は未コミット）。
2. `docs/ai/IPHONE_DEVICE_CHECKLIST.md` に沿って実機確認（特に §2 ペアリング、§3 速さ、§6 タブ）。
3. 問題があれば `ios/` を調整。第2段階（X）は第1段階・v2 の完成後に改めて判断。

---

# （以下は v2 より前の記録）

## 第1段階の状況（2026-10-09 更新・最新）
方針（`CLAUDE.md` §12 / `DECISIONS.md`）: **第1段階＝SwiftUI + WKWebView の iPhone 版を、Yahoo!ニュースなどアプリ内で普通に開けるサイトで実機で快適に使える状態にする。（当時）X は保留、User-Agent は変更しない、Safari 拡張は作らない（のち X に限り更新: 末尾の第2段階の節）、既存 FastAPI+Ollama・追加費用ゼロ。第2段階（X の扱いの再検討）は着手しない。**

### 直近の変更（未コミット。コミットは承認待ち）
- 原因調査: 実機確認前に「翻訳サーバーのエラーが続いた」と出たのは、私のシミュレータ検証の起動引数（`-MazemazeAPI`）が、あなたのシミュレータのアプリ設定（接続先・トークン）に**保存されたまま**になり、停止済みのテスト用サーバーへ接続していたため。→ DEBUG の起動引数は設定を書き換えない（使い捨て）ように修正、検証は専用の iPhone 17 で行う（iPhone 17 Pro は触らない）。失敗時は接続先とエラー内容を画面に表示。
- X: x.com はアプリ内ブラウザ（標準 UA）に `302 → x-safari-https://redirect.x.com/…` を返す（curl で確認。Safari 互換 UA なら 200）。（当時）UA は変更しない。白画面の代わりに案内カード（「アプリ内ブラウザでは開けません。Mazemaze はこの制限を回避しません」「Safari で開く」「閉じる（いまのページに残る）」「ホームへ」）を表示。アドレス欄横メニューにも「Safari で開く」「ホーム」。外部アプリへ渡せるのは tel/mailto/sms/facetime/maps（タップ後のみ）。
- 実機向けの完成度: 接続エラーを原因別に表示（-1009=ローカルネットワーク未許可の可能性／タイムアウト／接続拒否／.local 解決失敗）、許可ダイアログ直後は「もう一度接続確認」の案内、設定の初回 3 ステップ・トークン表示切替、翻訳できる本文が無いページのヒント、翻訳中の表示、busy（Mac が他の処理中）は橙の自動復旧通知（失敗に数えない）、フォアグラウンド復帰で自動再試行、未設定時の「サーバーを設定する」ボタン、ツールバーのラベル・「再翻訳」。
- 実機チェックリスト: `docs/ai/IPHONE_DEVICE_CHECKLIST.md`（実機でしか分からない項目を整理）。

### 確認した証拠
- `swift test` 52 件、Chrome DOM テスト 63 件、pytest 501 件、シミュレータ自己テスト（専用の iPhone 17、実 WKWebView + 実 FastAPI + 偽 Ollama）21 項目、Release 実機向けビルド成功。自己テストの追加項目: pushState と同一 URL 再読み込みで世代が進みページが追従、Safari 誘導のカード（白画面にならない）、カード中もページの翻訳状態が保たれる、閉じるとアドレス・状態が復元、閉じたあとも翻訳が機能、翻訳対象が無いページのヒント。
- 独立レビュー: 実機準備の監査（UX）と独立コードレビューを実施し、中以上の指摘（設定を開くだけで再翻訳が走る、カードの「戻る」が履歴を戻る、キャンセルされた遷移でページの翻訳世代が壊れる、ヒントが誤案内を上書き、外部スキームの許可が広すぎる、など）を修正。修正後の再レビューも実施し、中の指摘（Safari へ渡す URL が古い/不適切になりうる、didCommit で設定を再送しない、メッセージ検証と設定判定の URL の不一致）と低の指摘（復帰時の再試行が過剰、ポップオーバー位置、README の食い違い）を修正した。再々レビューは未実施。

### 未確認（実機でしか分からないこと）
- iPhone 実機そのもの（署名・インストール、ローカルネットワーク許可ダイアログと拒否時のエラーコード、実 Wi-Fi、VoiceOver・文字拡大・ダークの見た目）。x.com が実機でどう見えるか（案内カードが出る想定だが未検証）。
- WebKit 実機での React/Next の水和との相互作用。長い記事での負荷・発熱。

---

## iPhone アプリの状態（2026-10-09・実装時点）
**個人用 iPhone ブラウザアプリ「Mazemaze」（SwiftUI + WKWebView、`ios/`）を実装した。** 許可サイト（x.com / twitter.com / news.yahoo.co.jp）を閲覧すると、本文の日本語の一部が Mac 上の既存 FastAPI + Ollama（Qwen3.5:9b）で英語に置き換わる。**iPhone 実機は未確認**。Web 版 MVP とバックエンド（`backend/`）は変更していない。**未コミット**（`ios/`、README・CLAUDE.md §12・DECISIONS・PLAN・`scripts/run_lan.sh`・`.gitignore` の変更。承認待ち）。

### 場所と使い方
- Xcode プロジェクト: `ios/Mazemaze.xcodeproj`（`ios/tools/generate_project.py` で再生成可）。純ロジックは Swift Package `ios/MazemazeCore`。ページ内スクリプトは `ios/Mazemaze/Resources/translator.js`。
- 起動手順（初心者向け）は `README.md`「iPhone アプリ」。Mac: `./scripts/run_lan.sh`（URL とトークンを表示。トークンは `.mazemaze_token` に保存）→ Xcode で署名（Team 選択）→ iPhone で実行 → アプリの設定に URL とトークン。

### 確認した証拠
- `swift test`（`ios/MazemazeCore`）: **46 件通過**（接続先・サイトポリシーの攻撃的入力、メッセージ検証、直列化、世代、キャンセル、キャッシュ、429、ブレーカ、設定/キーチェーン分離、リダイレクト非追従）。わざと壊す変異（古い世代の結果を成功扱い）でテストが失敗することを確認。
- `node ios/WebTests/run_dom_tests.mjs`（実 Chrome、モックのネイティブブリッジ）: **63 件通過**（置換、`body.innerHTML` の完全復元、除外要素、ポップオーバー、動的追加、SPA 遷移と古い世代の破棄、React 風の書き換え・削除・`normalize()`、書き換え続けるページ、XSS、原文不一致の破棄、失敗ポリシー、水和待ち、DM 除外、長い段落の分割）。ZWSP を空文字に変える変異でテストが失敗することを確認。
- `./ios/scripts/simulator_selftest.sh`（iOS 26.1 シミュレータ、実 WKWebView + Swift ブリッジ + URLSession + 実 FastAPI（LAN の実 IP 経由・トークン）+ 偽 Ollama）: **14 項目通過**。ページの JS から専用 world のスクリプトとネイティブハンドラが見えない（`typeof` = undefined）こと、除外要素が不変なこと、英語タップで原文、翻訳 OFF／原文に戻すで DOM が完全一致に戻ること、ログイン系パスと password ページが翻訳されないこと、動的追加、トークン違いの表示と停止、API サーバーログに日本語本文が出ないこと。
- 実サイト: シミュレータで**実際の Yahoo!ニュース記事**（news.yahoo.co.jp/expert/articles/…）を実 Qwen3.5:9b で翻訳し、見出し・キャプション・本文・小見出しが英語混じりになることを目視確認（スクリーンショット）。トップ/ピックアップ一覧は見出しが `<a>` のためほぼ変わらない（仕様）。
- `.venv/bin/python -m pytest -q`: 501 件通過。Release（実機向け `generic/platform=iOS`、署名なし）のビルド成功。Release バイナリにデバッグ用の起動引数・セルフテストの文字列は含まれない。`Info.plist` は `NSAllowsLocalNetworking` と `NSLocalNetworkUsageDescription` のみ。
- 独立レビュー: 設計（dev-architect、dev-test-strategist）→ 実装後（dev-reviewer、dev-ux-auditor）→ 修正後に再レビュー（dev-reviewer）。実装後の高 2 件（一時的失敗でページ全体が永久に失敗扱い／英語だけのブロックで登録枠が枯渇）、中 7 件、UX の高 5 件は修正済み。再レビューの中 4 件（同一文章の失敗が永久に再送される、同一 URL 再読み込みで世代が上がらない、同世代 configure で止まる、bridge 拒否の無限リトライ）と低〜中の指摘も修正し、テストを追加した。最終コードの**再々レビューは未実施**（修正後のテストはすべて通過）。

### 未確認・既知の問題
- **iPhone 実機は未確認**: ローカルネットワーク許可ダイアログ（シミュレータでは出ない）、実 Wi-Fi、署名とインストール、WebKit の実機での挙動、VoiceOver・Dynamic Type・ダークの実見た目。署名なしのシミュレータビルドでは Keychain が使えない（署名ありなら動作。実機は署名が必要）。
- **X は未確認**（ログインが必要で、`data-testid` は仮説。実 DOM で動かない可能性がある）。DM を送らないための除外は入れたが実 DOM では未検証。ログイン・DM・表示制限は回避しない。
- Yahoo の見出しなど**リンク内の文字は翻訳しない**（タップ遷移を妨げないため）。一覧ページは変化が少ない。React/Next の水和との相互作用（Yahoo は SSR）は、DOM 変化が静まるまで待つ対策のみ。実機・実ページでのコンソール確認は未実施。
- 進行中の要求は cancel しない設計のため、直前の長い要求の後ろで最大約 3 分待たされることがある。1 ブロック 2〜7 秒の直列処理で、長い記事は少しずつ置き換わる。
- 通信は HTTP 平文（LAN）。トークンは Mac の `.mazemaze_token` に平文（権限 600、Git 管理外）。無料 Apple ID の署名は 7 日で失効する。
- ページ側が隣り合うテキストノードや flex の親を使う箇所は翻訳しない。ZWSP を使うため、ページ側がプレースホルダの前後を編集すると復元が不完全になりうる（検知して復元を試みる）。

### 次の最小アクション
1. 変更のコミット承認（私は未コミット）。
2. 実機（iPhone）で README の手順どおりに入れ、Yahoo の記事で確認 → 問題があれば `ios/` を調整。X は実際にログインして確認し、`data-testid` を実 DOM に合わせる。
3. 必要なら再々レビュー。

---

# （以下は Web 版 MVP 時点の状態）

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

## 2026-10-09 修正: 翻訳中／休止中にタブ一覧を開くとアプリが落ちる
- 原因: `TabCard`（View）の中で `badge("翻訳中")` と書くと、ファイル先頭の自作関数ではなく SwiftUI 標準の `View.badge(_:)`（自分自身への修飾）が選ばれ、`TabCard` が自分自身を無限に含んでスタックオーバーフロー（"Thread stack size exceeded due to excessive recursion"）。バッジが出る「翻訳中・休止中・エラー・原文表示」のタブがあるときだけ起きる。
- 修正: 関数名を `statusBadge` に変更（理由をコメントに記載）。
- 再発防止: `ios/scripts/simulator_selftest.sh` の最後に、タブ一覧を開閉するループ（`-MazemazeShowLoop`）を実行して落ちないことを確認する項目を追加。旧コードでは落ち、修正後は落ちないことを確認済み。

## 2026-10-09 第2段階: X をアプリ内で開く／貼り付けて翻訳（未コミット）
- 調査・決定・「実際に行った偽装」の範囲は `docs/ai/DECISIONS.md` と `CLAUDE.md` §12。
- 実装: `BrowserIdentity`（UA と X 限定の page-world スクリプト）、設定「X を Safari として開く」、translator.js の X 用の根（`article div[dir=auto]`、本文を包む `div[role=link]` の除外解除）、`PasteSurface` と `PasteTranslateView`、`paste.html` / `paste_fill.js` / `paste_text.js`。
- シミュレータ（実 x.com、ログアウト）: UA のみ → 誘導される／UA + 2 つの目印 → 開く。プロフィール（@kantei）の投稿本文が翻訳される（偽 Ollama）。**ログイン後・実機は未確認。**
- テスト: `swift test` 117 件、DOM 85 件（X 新形式 5 件・貼り付け 9 件を追加）、シミュレータ自己テスト 44 項目（貼り付け 8 項目＋タブ一覧の開閉ループを追加）。

