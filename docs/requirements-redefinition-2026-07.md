# 再要件定義ドラフト — 価値・差別化・証跡粒度（2026-07）

作成: ClaudeCode Fable5（2026-07-03）。相談レビュー: Codex GPT-5.5（同日・条件付き Go）。
更新: 2026-07-28（§1 / §6 の事実を現況へ同期。提案内容と質問リストの意味は不変）。
位置づけ: これは**提案ドラフト**であり、`AGENTS.md` §10 の不変条件（製品要件）を変更するものではない。
意味を変える項目は §14④ ゲートとして「人間への質問」節に隔離した。

## 1. 確認済み事実と未確認事項の分離

### 確認済み（local git / repo docs / GitHub live で確認）

- `main` は release-ready。T-001〜T-017 / T-021 / T-023 / T-025〜T-029 は done。
  公開exampleは11ファイル（checklist / report template / server runbook文書・実行可能template /
  evidence matrix / failed / protected route / responsive overflow / blank render target /
  hover-focus state / loading-empty-error state）。
- 本ドラフト §6 の R-6（README「What It Solves」への価値定式化の反映）は T-016 として
  実装済み。R-5（非Windows `pwsh` 検証）は T-021 として実装済み。回答待ちの
  R-1〜R-4 は `TASKS_BACKLOG.md` の T-022 / T-018〜T-020 に対応する。
- 現物の主成果物は `SKILL.md`（運用規律の文書）であり、UI 検証を実行するコードは同梱しない。
  `scripts/` はリポジトリ自身の OSS 健全性チェックであって UI 検証スクリプトではない
  （`tests/` の回帰テストも scanner 自身のためのもの）。
- ブランチ保護 + 必須 CI「Validate repository」が有効。open issue / open PR 0 件
  （2026-07-28 に `gh` で確認）。

### 未確認

- macOS と native Linux host の `pwsh` 実機動作。Debian GNU/Linux 12コンテナでは
  PowerShell 7.5.8 / Git 2.39.5、network無効、repository read-only mountで
  check:all 4ステップを確認済み。
- 外部利用者の存在・利用実態（star / fork / 転用事例）。
- Codex 以外のランタイム（Claude Code の Skill 形式等）へそのまま載せた場合の互換性。
- 同種の bounded + truthful reporting 特化 skill の不存在（調査範囲で見当たらなかった、
  以上の主張はしない）。

## 2. 価値仮説の再定義

### 従来の定式化

「Playwright / ブラウザ自動化で Web UI 変更を検証する手順書」。

### 再定義（提案）

2025〜2026 年で、エージェントがブラウザを操作する**能力**そのものは Playwright MCP・
Chrome DevTools MCP・エージェント内蔵ブラウザ等の普及によりコモディティ化した。
本スキルの価値は能力の提供ではなく、**「エージェントがいつ browser verification を
claim してよいか」を定める事前契約（pre-claim evidence contract）**にある。

1. **有界実行契約（bounded execution）** — dev server 起動 / health check / ブラウザ待機 /
   cleanup のすべてに有限タイムアウト・試行回数上限・必ず走る cleanup 経路を要求する。
2. **正直な報告契約（truthful reporting）** — 実施していない検証カテゴリを passed と書かず、
   `未確認` を第一級の報告語彙として扱う。
3. **証跡分離契約（evidence separation）** — 検証カテゴリは相互に含意しない
   （build 緑 ≠ UI 検証、DOM 存在 ≠ 描画成功、hover 確認 ≠ focus 確認）。

この 3 契約は使用ツールに依存しない。Playwright スクリプトでも、MCP ツール経由でも、
in-app browser でも適用できる、可搬（Markdown のみ）な報告契約であることが
ツール系プロダクトとの本質的な違い。

### 強制力の限界（過大に言わない）

本スキルは強制実行基盤ではない。「幻覚的検証を防ぐ」とは主張せず、
**「過大報告を検出・抑制しやすい報告契約を課す」**と表現する。契約文だけでは
boilerplate 化しうるため、実効性は「passed には evidence pointer を必須にする」等の
検証可能な条件（§4）に依存する。

### 2026-07 Web 調査の要点（詳細な出典 URL はセッション報告側に保持）

- Playwright MCP（Microsoft 公式）と Chrome DevTools MCP（Google 公式）が 20 以上の
  エージェント製品に採用され、ブラウザ操作能力の標準レイヤーとして定着した。両者とも
  「観測手段」の提供であり、cleanup 規律・未検証カテゴリの明示・証跡分離は上位レイヤーに
  委ねられている。
- skill マーケットプレイス（skills.sh 等）が 2026 年に急拡大。UI 検証系 skill
  （チェックリスト型・CLI ラッパー型）は既に存在するが、調査範囲では bounded 実行と
  正直な報告規律そのものを主目的にした skill は確認できなかった（不存在は未確認）。
- エージェントの「検証スキップ・幻覚的検証（reward hacking）」は 2026 年に研究テーマ化
  （ツール実行レシートによる事後検出、検証スキップ率のベンチマーク等）。事後検出・測定が
  主流で、人間可読な事前契約アプローチは希少。
- ゾンビプロセス（残留 dev server / headless browser）対策ツールは「事後 kill」型が主流。
  本スキルの「実行前から cleanup 経路を設計上保証する」bounded 契約とは補完関係。

## 3. 差別化 — レイヤーモデル

代替手段は競合ではなくレイヤーが異なる、という整理が最も正確で崩れにくい。

| レイヤー | 担うもの | 代表例 | 本スキルとの関係 |
| --- | --- | --- | --- |
| capability | ブラウザ操作・観測の能力 | Playwright MCP / Chrome DevTools MCP / in-app browser | 補完。その上に載る契約が本スキル。 |
| artifact | 実行痕跡の生成 | Playwright trace / reporter / screenshot | 補完。evidence pointer の参照先になる。 |
| post-hoc attestation | 実行事実の事後照合 | tool receipts / audit log 研究 | 補完。本スキルは「事前に何を claim してよいか」を縛る側。receipts が普及すれば evidence pointer として利用できる。 |
| resource control | 残留プロセスの事後処理 | zombie-process killer 系ツール / CI timeout | 補完。本スキルは事前の bounded 設計を要求する側。 |
| **pre-claim evidence contract** | **検証主張の事前契約** | **本スキル** | — |

同一レイヤーで比較すべき代替: UI 検証チェックリスト型 skill、E2E テスト生成 skill、
visual regression（CI 上の baseline 比較）、accessibility audit、QA チェックリスト。
本スキルの勝ち筋は「テストの上手さ」ではなく**「最終報告の正直さ」**。

### 想定される弱み（正直に記録する）

- `SKILL.md` のコード例は Playwright API 直書き前提で、MCP ツール経由の検証手順
  （コードを書かない経路）が明文化されていない。
- インストール手順・スクリプトが Windows / PowerShell 中心。
- 「規律の文書」はツールと違い効果測定が難しく、採用の動機付けが弱い。
- skill マーケットプレイスの急拡大により、差別化点を明確に打ち出さないと
  チェックリスト型 skill 群に埋没するリスクがある。
- IDE ネイティブのブラウザプレビュー / 視覚差分機能が高度化しており、「外付け skill が
  必要な理由」を継続的に説明する必要がある。

## 4. 証跡粒度の再定義（提案）— sparse claim ledger

現状の粒度: 検証カテゴリのリスト + 「カテゴリは相互に含意しない」原則 + examples による
シナリオ別の例示。

概念モデルとしては `(route/state) × (viewport) × (カテゴリ)` が証跡の識別単位だが、
**全直積の表を必須にすると小さな UI 修正でも行数が爆発し、機械的に `未確認` を並べる
だけの形骸化を招く**（相談レビューの主要指摘）。よって「関係する claim だけを行にする」
sparse claim ledger を提案する。

- **主キー**: `route/state + viewport + category`（変更に関係する組だけ記載する）
- **属性**: `method`（検証手段。軸ではなく属性）/ `verdict` / `evidence pointer` / `notes`
- **verdict 4 値**: `passed` / `failed` / `blocked` / `未確認`（未実施）
  - `passed` は evidence pointer 必須（スクショパス・console 抜粋・計測値等）。
  - `failed` は再現手順または証跡必須。
  - `blocked` は blocker の内容と、bounded な再試行/代替確認の有無を必須。
  - `未確認` は理由と「次に確認すべき最小作業」を必須。
- **applicability は verdict と別軸**: `required` / `optional` / `not_applicable`。
  「不要だからやらない」と「未実施」を混同しない。
- **規模別 tier**: 全 UI 変更に ledger 全体を課すのではなく、変更規模に応じた最小構成を
  定義する（例: 文言変更なら該当 route × 3 viewport × visual のみ、等）。

`examples/evidence-matrix.md` は既にこの方向の軽量な先行例であり、ledger 形式は
その一般化として位置づける。

## 5. 人間への質問リスト

相談レビューを踏まえ、意思決定に効く 4 つの決定軸 + 運営判断 3 問に整理した。

### 決定軸（製品要件に直結・§14④ を含む）

| # | 質問 | 影響 |
| --- | --- | --- |
| D1 | 本スキルは**軽量な運用契約（Markdown のみ）に留める**か、claim ledger の schema / 機械検証（checker script）まで持つか。 | checker を持つと実効性が上がるが、軽量さ・可搬性という現在の強みを削る。 |
| D2 | verdict 4 値（passed / failed / blocked / 未確認）+ applicability 別軸を `SKILL.md` 本体へ明文化してよいか（判定基準の変更 = §14④）。 | 承認されれば R-2 として実装。 |
| D3 | claim ledger は全 UI 変更に必須とするか、**変更規模別 tier** とするか。 | tier 制でないと形骸化リスク（相談レビュー指摘）。 |
| D4 | MCP ツール経由（コードを書かない）検証経路の明文化は「例の追加」（自走可）と「対象範囲の拡張」（§14④）のどちらと扱うか。 | 本ドラフトでは §14④ 側に倒して質問扱い。 |

### 運営判断

| # | 質問 | 影響 |
| --- | --- | --- |
| O1 | 第一目的は (a) 自分のマルチエージェント運用の内部規律か、(b) OSS として外部利用者獲得か。成功指標は何か（例: 自案件での未確認明示率 / star・fork / 参照数）。 | (b) なら英語化・他ランタイム互換・マーケットプレイス掲載の優先度が上がる。 |
| O2 | skill マーケットプレイス / ディレクトリへの掲載意向はあるか（現 Non-Goals は GitHub Marketplace 掲載なしを明記。変更は §14④）。 | 掲載するなら差別化点の英語での明文化が前提タスクになる。 |
| O3 | ゼロ円運用（local + GitHub Actions 無料枠、有料サービス不使用）を今後も維持でよいか。 | 維持なら現 Non-Goals のまま。 |

## 6. タスク分解案（`TASKS_BACKLOG.md` へ転記済み）

| 仮ID | 内容 | ゲート | 台帳 ID / 状態 |
| --- | --- | --- | --- |
| R-1 | 本ドラフトを起点に要件正本（REQUIREMENTS 相当）を整備 | 質問リスト回答後 | T-022 / blocked |
| R-2 | verdict 4 値 + applicability 別軸 + passed の evidence pointer 必須化を `SKILL.md` へ明文化 | D2 承認後 | T-018 / blocked |
| R-3 | MCP ツール経由の検証経路を examples または `SKILL.md` に追記 | D4 の判断後 | T-019 / blocked |
| R-4 | sparse claim ledger の合成 example を追加（evidence-matrix の一般化） | D3 の tier 方針決定後 | T-020 / blocked |
| R-5 | 非 Windows `pwsh` 実機検証の記録（実機が無い間は `未確認` を維持） | 自走可 | T-021 / done |
| R-6 | 差別化レイヤーモデル・価値定式化を README「What It Solves」へ反映 | 文言明確化なら自走可 | T-016 / done |

## 7. 本ドラフトの扱い

- 既存資料（`AGENTS.md` §10 / `README.md` / `SKILL.md`）が引き続き正本。本ドラフトは
  質問リストへの回答が得られるまで提案に留まる。
- 市場・競合の Web 調査結果および相談レビューの全文は、第三者リポジトリ URL を
  リポジトリ内に書かない運用のため、本ファイルには URL を残さずセッション報告側に保持する。
