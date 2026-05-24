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
请读取 $brief, 按 brief 的要求完成代码/文档/测试任务。
工作目录是 $root.

完成后, 你的最终回复必须是写给 Claude 的交接结果, Markdown 格式, 包含以下小标题:
## summary
## files_changed
## tests
## blockers

不要输出寒暄。你的最终回复会被 codex exec 自动写入 handoff/result.md。
"@

    $codexOut = $prompt | codex --ask-for-approval never exec `
        -C $root `
        --sandbox workspace-write `
        --skip-git-repo-check `
        --color never `
        --output-last-message $result `
        - 2>&1

    $code = $LASTEXITCODE
    Log "codex exit=$code"

    if (Test-Path $lock) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }

    if ($code -eq 0 -and (Test-Path $result)) {
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
