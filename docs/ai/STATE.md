# Handoff state

## 現在の状態（2026-10-10・最新）: 完全ローカル版（`main`）
所有者の決定で、`main` を **iPhone 単体版**にした。翻訳（Apple 翻訳 / Apple Intelligence）と単語・句の意味（Apple Intelligence）は、すべて iPhone の中のエンジンで動く。**Mac のローカルモデル版（FastAPI サーバー、Web UI、QR ペアリング、Tailscale、評価環境）は、ブランチ `mac-local-model`（`cef50de` の時点）に残してある**（リモートにもある）。`main` からは、サーバー・通信・ペアリング・ピン留め・Tailscale・Keychain のトークン・Ollama の評価環境・Python のテストを削除した。

- ページの翻訳の既定は Apple 翻訳。設定で Apple Intelligence も選べる。単語・句の意味は Apple Intelligence。標準辞書は別で常に使える。
- 置き換える場所の選択・検証・表示整形・意味カードの検証は、Python から Swift に移したもの（`ios/MazemazeCore/.../OnDevice/`）。基準との一致は、約 1.4 万件の正解データで `OnDeviceGoldenTests` が確認する。
- テスト（削除後）: `swift test` 160 件、DOM テスト 108 件、シミュレータ自己テスト 64 項目（偽エンジン。バックアップの書き出し・取り込み・復元を含む）、永続化の試験（再起動・上書きで残り、削除で消える）、Release ビルド OK。pytest は無くなった。
- **運用（2026-10-13）**: バックアップ（書き出し・取り込み=統合・前の状態に戻す・読めなかった辞書の取り出し）、署名の期限の表示、エンジンの確認（保守用 30 文）を追加。手順は `docs/ai/OPERATIONS.md`。実機では未確認（チェックリスト §8）。
- **実機は未確認**（`docs/ai/IPHONE_DEVICE_CHECKLIST.md`）。特に Apple 翻訳（見えない部品が設定・貼り付け画面の裏でも動くか、ダウンロードの確認画面が出るか）、Apple Intelligence の速さ・発熱・質。
- 質の測定（Apple Intelligence、この Mac）と決定の理由・限界は `docs/ai/DECISIONS.md`。Apple 翻訳は未測定。
- 以前の記録は `docs/ai/archive/`（`STATE_mac_era.md`、`PLAN.md`、`SPEC.md`、`TRANSLATION_EVAL_REPORT.md`）にある。決定の履歴は `DECISIONS.md`、運用の手順は `OPERATIONS.md`。
