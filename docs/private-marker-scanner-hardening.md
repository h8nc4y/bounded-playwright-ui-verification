# Private marker scanner hardening

## 目的

公開前scannerが、ambient Git設定、hostile path、巨大入力、child process残存、
index/worktree driftをcleanと誤判定しないようにする。Playwright skill本体の要件、
browser verification手順、製品gateは変更しない。

## 影響範囲

- `scripts/private-marker-process.ps1`: bounded child process境界。
- `scripts/scan-private-markers.ps1`: scan対象の確定、Git blob読取、検出、報告。
- `tests/scan-private-markers.Tests.ps1`: synthetic hostile fixtureとcross-platform回帰。
- `scripts/private-scan-config.ps1`: directory除外の単一情報源。
- `scripts/assert-oss-ready.ps1`: 公開契約と回帰fixtureのreadiness needle。
- README、SECURITY、CHANGELOG、HANDOFF、TASKS_BACKLOG: 利用者向け保証範囲と限界。

## 維持する019固有契約

1. T-024のtracked-only化は行わない。Git repositoryではindex snapshotとregular
   working treeを走査し、さらに除外対象外のuntracked text fileも走査する。
2. directory除外は`private-scan-config.ps1`を単一情報源とする。local agent state、
   UI verification一時成果物、report、coverage、build outputは既存どおり除外する。
3. 公開URL allowlistはこのrepository自身だけとする。
4. reserved example domainのemailと、値を伴わないBearer proseはfalse positiveにしない。
5. 既存の`-Root`呼出し、test file path、temp cleanupを維持する。

## 強化する境界

1. child Gitはambient cloneやcaller overrideを固定allowlistへ最終sanitizationし、
   `GIT_*`だけでなく非Git名のcredential、marker、loader制御も継承しない。PATHは
   target directoryと固定OS directoryだけに限定し、hook、filter、pager、prompt、
   network protocolも無効化する。
2. operation時計はenvironment準備より前に開始し、Process.Start、containment、
   target、stdioへ同じ残時間を渡す。cleanupは本体残時間を再利用せず、独立した単一の
   absolute slackでtree停止、wait、stream drainを行う。
3. Windowsではsuspended processをkill-on-close Jobへ割り当ててからresumeする。
   launch失敗、timeout、output超過、parent-first exitでもchild tree停止とstream drainを
   有限時間で確認する。最初の実行可能なbounded callをASTで固定し、binary
   stdin/stdout/stderr、EOF、exit codeを完全一致で検証する。AST gateはscope prefix、
   target function/aliasのshadow、Alias/Function provider代入、module-qualified
   bootstrap pathと`PSScriptRoot` provenance、Set/New-Variable、Variable provider、
   その間接参照とcustom mutation alias、PSVariable `.Set*()` / `.Value`、
   `Copy-Item` / `Move-Item` / `Rename-Item` / dynamic `New-Item`、`Get-Command`、
   class constructor/method/継承、
   function/class間の推移的wrapperを正規化し、dynamic invocationをfail closedにする。
   Job handleはclose成功後だけ所有権を放棄し、close失敗時はdirect child terminate、
   bounded wait、同じhandleのclose再試行を行う。POSIXではexternal/nativeの両経路で
   session作成後のready PIDを受け、`getpgid(pid) == pid`を確認してからtargetをrelease
   する。external `setsid`はBusyBox/util-linux共通のoption-free operand形を使う。
4. index stage/debugをbinary-safeに解析し、intent-to-add、conflict、gitlink、
   malformed path、index driftをfail closedにする。blobはbatchで取得し、network fetchしない。
   Windows PowerShell 5.1のstdin BOM混入を防ぎ、native Git `cat-file --batch`のraw
   responseをbyte完全一致で検証する。
5. worktreeはrootからleafまでreparse/symlinkを検査し、read前後の型と長さを再確認する。
6. Git probeでvalid worktreeを確立できず、scan rootまたはancestorに`.git`
   file/directoryがある場合は固定`git-probe`診断でfail closedにする。markerは親directoryを
   非再帰列挙してentry名で確認し、targetが消えたdangling junction/symlinkも見落とさない。
   確定したnon-Git fallback root内のnested `.git` directoryとleaf `.git` fileは除外して
   followしない。正常な`git worktree add`の`.git` fileは実物fixtureでindex/worktree
   unionとroot境界を確認する。
7. textはstrict UTF-8で読み、file、entry、line、regex match、finding、byte、process、
   output、deadlineの各budgetを超えた場合は固定診断でfail closedにする。process helperや
   scan configのbootstrap、process boundary、Git isolationの作成/削除が例外を返しても、
   absolute pathや内部例外を出さず固定のredacted診断1行とexit code 2だけを返す。
   最初のfailureでstack unwind中のcleanupも失敗した場合は診断を再出力しない。
8. finding reportはpathをsanitizationし、生値を常にredactする。prefix、header、row、
   truncation notice、実OS newlineを含む最終UTF-8 payload全体を16KiB以下に制限し、
   stdoutへ一度だけ書く。finding/cleanのどちらもemit直前にscan-wide deadlineを再確認する。
9. local追加markerはignored `.private-markers.local`または専用環境変数からだけ読み、
   件数・長さ・bytesを制限してliteral ruleとして扱う。
10. `assert-oss-ready.ps1`はCIのtrigger、permissions、job、stepをjob所有範囲内で完全一致
   検証する。現行`actions/checkout@v4`はmutable tagであり、immutable SHA固定ではない。
   workflow編集は`AGENTS.md` §14①の人間gateなので、この変更では安全保証へ読み替えない。

## 検証計画

- Windows PowerShell 5.1とPowerShell 7でreadiness、scanner self-test、
  repository scan、whitespaceを完走する。
- Microsoft公式Debian系.NET SDK image
  `mcr.microsoft.com/dotnet/sdk:9.0`同梱のPowerShellとGitを使い、
  network無効・repository read-only mountで同じfull gateを実行する。
- staged treeに対してGitleaks、Semgrep、AST、UTF-8 BOM/LF/NUL、diff checkを実行する。
- commit前にtree/hashをfreezeし、P1/P2/P3独立レビューを通す。

## 非対象

- T-024のtracked-only mode。
- `.github/workflows/ci.yml`の変更。
- mutable checkout tagのimmutable SHA固定（§14①の人間承認が必要）。
- Playwright skill本文の製品要件変更。
- API、OAuth、secret、実データ、課金、deploy、release、tag。
