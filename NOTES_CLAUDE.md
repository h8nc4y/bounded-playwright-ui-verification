# NOTES_CLAUDE — scanner hardening (019, isolated worktree)

実装担当: Claude Code (Opus 4.8)。隔離 worktree 内のみ編集。git/commit/PR・実 API・実 secret は未使用。

## このスライスで実装したこと（検証済み）

- `scripts/scan-private-markers.ps1`
  - 秘匿値プレフィックス拡充（regexMarkers）: AWS `AKIA[0-9A-Z]{16}` / GCP `AIza[0-9A-Za-z_\-]{35}` /
    Slack `xox[apbr]-…` / `xapp-…` / Stripe `(sk|rk)_live_…` / PEM `BEGIN (RSA|EC|DSA|OPENSSH|ENCRYPTED) PRIVATE KEY`。
  - 偽陽性抑制: Bearer は値が続く場合のみ（`Bearer [A-Za-z0-9._\-]{8,}`）。email は語境界＋`example.com/.org/.net` allowlist。
  - 自己免除孔の修正（020 no-blanket-exempt へ整合）: 私的パス/repo リテラルを分割連結（`"D:" + "\Agent\..."` 等）にして
    scanner ソースに verbatim を残さない。これにより `Test-SelfMarkerLine` の「scanner-marker 行丸ごと免除」を撤去でき、
    real secret は scanner 自身の行でも検出される。回帰テストで担保（"flags marker-like values even on a scanner-named line"）。
  - Detail を全 finding で `<redacted>` に統一（値非 replay）。
  - 単一行ファイルが char 単位 index される PowerShell の罠を `@(Get-Content …)` で修正（既存バグ。テストが検出）。
  - 除外ディレクトリ集合を `scripts/private-scan-config.ps1` から取得（単一情報源化）。
- `scripts/private-scan-config.ps1`（新規）: 除外ディレクトリの単一情報源。scan と assert-oss-ready が dot-source。
- `scripts/assert-oss-ready.ps1`: 除外集合を共有 config 経由に変更。単一行 `@(Get-Content)` 修正も適用。
- `scripts/check-whitespace.ps1`（新規）: whitespace lint の単一エントリ点。空ツリーハッシュをここ 1 箇所に集約。
- `tests/scan-private-markers.Tests.ps1`（新規・依存ゼロ）: 各新プレフィックスの「検出＋redact＋値非 replay」回帰、
  Bearer/email 偽陽性ガード、no-blanket-exempt、safe fixture pass。全フィクスチャは合成・temp ディレクトリ・実 secret なし。
- `.github/workflows/ci.yml`: shell を `powershell`→`pwsh` に統一。テスト step を追加。whitespace step を `check-whitespace.ps1` に。
- `SECURITY.md` / `README.md` / `SKILL.md`: 「scan はベストエフォートで全 secret 形式を保証しない」を明記。

### ローカル検証結果（pwsh 7、無課金・無ネットワーク）
- `scan-private-markers.ps1`（worktree ルート）= exit 0（passed）。
- `assert-oss-ready.ps1` = exit 0（passed）。
- `tests/scan-private-markers.Tests.ps1` = 11/11 PASS, exit 0。
- 全 .ps1 の構文トークナイズ OK。

## ゲート④ / 人間承認待ち（このスライスでは実装せず提案のみ）

### 新H-A: 「git-tracked ファイルのみ走査」モード
- 仕様の第一推奨は scanner を `git ls-files` 由来の追跡ファイルのみ走査に切り替え、CI checkout と手元実行の対象を一致させること。
- 本スライスでは**未実装**。理由:
  1. このタスクは git 操作禁止（commit/branch 不可）かつ無ネットワーク。`git ls-files` 依存の走査へ切り替えると、
     git レポジトリ状態に依存する振る舞い変更になり、隔離 worktree（git メタデータ非保証）では実機検証できない＝捏造回避のため未確認にできない。
  2. 「全作業ツリー走査 → tracked 限定」は scan の走査対象という**振る舞い変更**であり、CHANGELOG/HANDOFF の
     「scan passed」が tracked か作業ツリー全体かの意味も変わる。製品ドキュメントの記述変更を伴うため gate④（人間承認）が妥当。
- 代替（安全側・本スライスで実施済み）: 除外集合を repo 直下 `.gitignore` と整合させた。
  現状 `.gitignore` は `.claude/ .codex/ .ui-verification/ node_modules/ playwright-report/ test-results/ coverage/ dist/ build/` を ignore、
  scanner の除外集合（private-scan-config.ps1）も同じ集合＋`.git`。よって本 worktree の `docs/`（= `release-checklist.md` のみ、正当）で
  exit 1 にはならない（検証済み: scan exit 0）。
- 人間が承認する場合の実装案（提案）:
  - `param([switch]$TrackedOnly)` を追加し、有効時は `git -C $Root ls-files -z` の結果のみを走査対象にする。
    CI は checkout 済み tracked のみなので `-TrackedOnly` を CI で既定有効にすると手元/CI が一致。
  - 併せて CHANGELOG/HANDOFF/README に「scan は tracked ファイルを対象（`-TrackedOnly`）／既定は作業ツリー全体」を明記。
  - 未追跡の `docs/` に私的パスが入っても tracked でない限り exit 1 にならず、`git add` された瞬間に検出される、という受入を満たす。

### whitespace 空ツリーハッシュの 1 エントリ化（部分対応）
- `scripts/check-whitespace.ps1` を新設しハッシュをここ 1 箇所に集約、CI もこれを呼ぶ形にした。
- ただし `README.md` / `CONTRIBUTING.md` / `HANDOFF.md` / `docs/release-checklist.md` / `AGENTS.md` の本文には
  説明目的で `git diff --check <hash> HEAD` がまだ各所に残る。これらを「`pwsh -File ./scripts/check-whitespace.ps1` を実行」に
  置換すると重複が完全に消えるが、運用ドキュメントの文面変更で人間レビュー（文言・手順の妥当性）が望ましいため、
  ドキュメント本文の一括置換は**未実施**（提案）。コマンド実体は check-whitespace.ps1 に集約済み。

## 残リスク・未確認
- git-tracked-only モードは未検証（上記理由）。実 git レポジトリでの `-TrackedOnly` 実機確認は人間/オーケストレーター側で要実施。
- CI の `pwsh` step は GitHub `windows-latest` 上での実 run 未確認（ローカル pwsh 7 でのスクリプト単体実行のみ確認）。
- email allowlist は `example.com/.org/.net` のみ。`example.md` 参照や npm scope の網羅までは広げていない（過剰実装回避）。
- Slack 正規表現 `xox[apbr]-…` は既存の bot トークン・リテラル接頭辞と一部重複し得るが、二重検出は finding 重複のみで害なし。
