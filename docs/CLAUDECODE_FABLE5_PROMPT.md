# ClaudeCode Fable5 prompt - 019_bounded-playwright-ui-verification

作成日時: 2026/07/02 08:30:54 JST。
最初に読むファイル: `docs/CLAUDECODE_FABLE5_HANDOFF.md`

## Repo-specific addendum

UI検証skillとしての価値、ほか自動検証手段との差別化、証跡粒度を再定義する。現 checkout と `HANDOFF.md` の main 記述がずれるため ancestry/merge 状態を確認する。

## Prompt to use

# ClaudeCode Fable5 共通プロンプト

Goal
対象リポジトリを ClaudeCode Fable5 で引き継いでください。Fable5 を使って最大限の推論を行い、既存実装の続きを単に進めるのではなく、開発目的・市場・利用者・価値仮説・成功指標から再検討してください。

Context
この引き継ぎには、repo ごとの既存資料パス、進捗、残タスク、gate、repo 固有注意が含まれています。まず `AGENTS.md` と対象 repo の handoff/task/requirements/design 資料を読み、確認済み事実と未確認事項を分けてください。既存資料は現状把握の材料であり、要件定義の最終正本ではありません。

Autonomy policy
Fable5 が主担当です。要件定義、市場調査、利用者価値、仕様判断、設計判断、質問設計、ClaudeDesign の wireframe 指示を主導してください。実装が必要になったら Codex GPT5.5 XHIGH skill を呼び出してよいですが、Fable5 の判断品質を維持するため、Codex への命令は対象ファイル、背景、受け入れ条件、禁止事項、検証コマンド、期待 diff、残リスクの形で具体化してください。

Stop only when
有料API/有料クラウド/課金、OAuth/secret/token入力、実ユーザー/顧客/実データの外部送信、ストア提出、公開release、production deploy、または人間の意思決定なしには進めない product 判断が必要なときだけ止まってください。止まる場合は、必要な操作、理由、代替案、確認したい質問を明確にしてください。

Do not stop for
既存資料の読解、要件整理、質問リスト作成、市場調査計画、ローカル設計案、wireframe 下書き、Codex への実装依頼文作成、local-only のコード/テスト/docs 改善、未確認事項の整理。

Constraints
秘密情報、`.env*`、`auth.json`、private key、credential-bearing log、実データ、raw production log、実ユーザーの URL/handle/スクショ/本文を読まない・貼らない。既存 dirty WIP を消さない。確認していない事実は `未確認` と書く。UI がある成果物は ClaudeDesign を使い、ワイヤーフレームまたは UI spec を作ってから実装へ進む。

Work loop
1. repo 固有 handoff の reading order に沿って資料を読む。
2. 既存要件、設計、タスク、実装状態、gate、未確認事項を 1 枚に再整理する。
3. ユーザーへ確認すべき質問を、目的・利用者・市場・競合/代替手段・成功指標・非目標・公開範囲・費用上限に分けて作る。
4. Web 上の最新情報で市場・競合・仕様・規約・料金・公開要件を調査する。既存の Web 調査資料があっても陳腐化を疑う。
5. UI がある場合は ClaudeDesign で wireframe/spec を作り、ユーザー確認用の画面単位・状態単位に分ける。
6. 実装が必要な小タスクへ分割し、Codex GPT5.5 XHIGH skill に渡す具体命令を作る。
7. Codex の成果物を Fable5 がレビューし、要件・設計・テスト・gate と照合する。
8. repo の handoff/task/design docs を更新する。

Done when
改訂版の要件定義、既存資料マップ、市場/仕様調査メモ、設計または UI wireframe 方針、完成までの task breakdown、現在進捗、残タスク、Codex へ渡す実装指示、未確認/gate が repo 単位で揃っている。

## Apply this repo-specific instruction

対象 repo は `019_bounded-playwright-ui-verification` です。まず `docs/CLAUDECODE_FABLE5_HANDOFF.md` の repo handoff を読み、そこにある要件資料、Web調査/判断資材、設計資料、タスク一覧、進捗、残タスク、gate、reading order を作業の出発点にしてください。既存資料は現状把握の根拠であり、再要件定義後の正本ではありません。

Repo-specific addendum:
UI検証skillとしての価値、ほか自動検証手段との差別化、証跡粒度を再定義する。現 checkout と `HANDOFF.md` の main 記述がずれるため ancestry/merge 状態を確認する。