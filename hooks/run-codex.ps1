# Triggered by Claude Code PostToolUse:Write hook.
# Only fires Codex when Claude writes handoff/brief.md.
# After Codex finishes, exit 2 + stderr wakes Claude up via asyncRewake.
#
# Requires: codex CLI >= 0.133 (older CLIs default to gpt-5.5 but fail with
#           "model requires a newer version of Codex").
# Encoding: this file MUST be saved as UTF-8 with BOM. PowerShell 5.1 on a
#           zh-CN system reads BOMless UTF-8 as GBK, mangling the here-string
#           below and causing "string is missing the terminator: \"@" errors.

$ErrorActionPreference = "Continue"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$log = Join-Path $PSScriptRoot "codex.log"
function Log($m) {
    try { Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $m" -Encoding UTF8 } catch {}
}

$lock = $null

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $raw | ConvertFrom-Json
    $tool = $payload.tool_name
    $file = $payload.tool_input.file_path
    $basename = if ($file) { Split-Path -Leaf $file } else { "" }

    # Fast path: only handoff/brief.md is interesting
    if ($basename -ne "brief.md") { exit 0 }
    if (-not ($file -like "*\handoff\brief.md")) {
        Log "skip non-handoff brief: $file"
        exit 0
    }

    Log "TRIGGER tool=$tool file=$file"

    $handoff = Split-Path -Parent $file
    $root = Split-Path -Parent $handoff
    $brief = $file
    $result = Join-Path $handoff "result.md"
    $lock = Join-Path $handoff "codex.lock"

    # Reentry guard
    if (Test-Path $lock) {
        $age = (Get-Date) - (Get-Item $lock).LastWriteTime
        if ($age.TotalMinutes -lt 30) {
            Log "skip: lock alive (age $([int]$age.TotalSeconds)s)"
            [Console]::Error.WriteLine("Codex already running (lock age $([int]$age.TotalSeconds)s). Trigger ignored.")
            exit 2
        }
        Log "stale lock cleared (age $([int]$age.TotalMinutes) min)"
        Remove-Item $lock -Force -ErrorAction SilentlyContinue
    }

    New-Item -ItemType File -Path $lock -Force | Out-Null
    if (Test-Path $result) { Remove-Item $result -Force }

    Log "START codex exec, root=$root"

    $prompt = @"
你是 Codex 执行端。
请读取 $brief, 按 brief 的要求完成任务 (可以是代码 / 文档 / 数据分析 / 研究 / 任何形式).
工作目录是 $root.

输出规则 (按优先级):
1. 如果 brief 明确指定了输出格式 (例如"产出: 3 条发现 + 2 个洞察") → 严格按 brief 的格式输出
2. 如果 brief 没指定输出格式 → 用 Markdown 写一份给 Claude 的简洁交接报告, 必须含: ## summary (这次做了啥), ## artifacts (产出的文件 / 数据 / 结论清单), ## blockers (有阻塞就写, 没有就 "无")

不要输出寒暄。不要套用跟 brief 任务无关的标题 (例如 brief 是数据分析时, 不要硬塞 files_changed / tests).

## handoff/result.md 输出方式 (必读, 决定你这次成败)

机制: 你的最终回复会被 codex exec 通过 --output-last-message 自动写入 handoff/result.md.

**禁止用 apply_patch / shell / 任何工具调用直接修改 handoff/result.md** (即使内容长 5k、10k tokens 也禁止). 你必须**把完整内容作为最终回复 inline 输出**, 不要写 "已完成, 详见 result.md" 这种自述性总结.

为什么: 如果你用 apply_patch 写 result.md, codex exec 退出时会用你的最终消息 (那段简短自述) 覆盖你 apply_patch 写的真内容, 报告会丢失.

写**其他文件** (.py / data/*.csv / 其他 markdown / 源码修改) 不受这条限制, 正常用 apply_patch 即可. 本禁令只针对 handoff/result.md 这一个路径.
"@

    # Sandbox mode: danger-full-access (A1, 2026-05-26 修复).
    # 原因: workspace-write 在 Windows 上依赖 CodexSandboxOffline 本地账户 +
    # CreateProcessWithLogonW. Hook stable 0.133 跟 Desktop alpha 共存时
    # sandbox_users.json 缓存密码会跟系统本地账户漂移, 触发 ERROR_LOGON_FAILURE (1326)
    # → 10 次后 ERROR_ACCOUNT_LOCKED_OUT (1909, 锁 10 分钟).
    # 详见: SKILL.md "hook 已知坑 #2 · sandbox 账户锁定"
    $codexOut = $prompt | codex --ask-for-approval never exec `
        -C $root `
        --sandbox danger-full-access `
        --skip-git-repo-check `
        --color never `
        --output-last-message $result `
        - 2>&1

    $code = $LASTEXITCODE
    Log "codex exit=$code"

    if (Test-Path $lock) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }

    # A3 (2026-05-26): exit=0 不足以判 SUCCESS, 还要扫 result.md 是否含失败信号.
    # 历史坑: codex sandbox 启动失败时 exit=0 + result.md 含 "CreateProcessWithLogonW failed",
    # 旧 hook 误报 SUCCESS, Claude 拿到假成功消息浪费一轮 review.
    if ($code -eq 0 -and (Test-Path $result)) {
        $resultContent = ""
        try { $resultContent = Get-Content $result -Raw -Encoding UTF8 -ErrorAction Stop } catch {}

        $failureSignals = @(
            'CreateProcessWithLogonW failed',
            '无法读取工作区',
            '无法读取.*brief\.md',
            'shell_command 启动失败',
            'sandbox.*failed',
            '执行端无法'
        )
        $matchedSignal = $null
        foreach ($pattern in $failureSignals) {
            if ($resultContent -match $pattern) {
                $matchedSignal = $matches[0]
                break
            }
        }

        if ($matchedSignal) {
            $msg = "Codex 假成功 (exit=0 但 result.md 含失败信号: '$matchedSignal'). Hook 判 FAILURE. 详见 SKILL.md hook 已知坑 #2."
            [Console]::Error.WriteLine($msg)
            Log "FALSE-SUCCESS signal=$matchedSignal"
            exit 2
        }

        $msg = "Codex 完成 ($(Get-Date -Format 'HH:mm:ss')). result.md 已就绪, 请读取 handoff/result.md, 审核并写 handoff/review.md, 然后向用户报告 review 结论等待拍板。"
        [Console]::Error.WriteLine($msg)
        Log "SUCCESS"
        exit 2
    }

    $tail = ($codexOut | Select-Object -Last 10 | Out-String).Trim()
    $msg = "Codex 失败 (exit=$code). result.md 可能缺失/不完整。Tail: $tail"
    [Console]::Error.WriteLine($msg)
    Log "FAILURE tail=$tail"
    exit 2
}
catch {
    $err = "HOOK SCRIPT ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    [Console]::Error.WriteLine($err)
    Log $err
    if ($lock -and (Test-Path $lock)) { try { Remove-Item $lock -Force } catch {} }
    exit 2
}
