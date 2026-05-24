# Minimal test for Claude Code asyncRewake hook on Windows + PowerShell.
# Avoids any non-ASCII string literal so PS 5.1 won't mis-decode the file.
# Uses $PSScriptRoot to locate the log next to itself.

$ErrorActionPreference = "Continue"

# Force UTF-8 I/O so Claude Code's JSON stdin (UTF-8) and our stderr message survive
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$log = Join-Path $PSScriptRoot "hook.log"

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $raw | ConvertFrom-Json

    $tool = $payload.tool_name
    $file = $payload.tool_input.file_path
    $basename = if ($file) { Split-Path -Leaf $file } else { "" }

    Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | tool=$tool | basename=$basename" -Encoding UTF8

    if ($basename -eq "hook-trigger.txt") {
        Start-Sleep -Seconds 2
        $msg = "HOOK_TEST_OK: asyncRewake fired at $(Get-Date -Format 'HH:mm:ss'). If you see this as a system-reminder, the reverse-wake channel works on Windows + PowerShell."
        [Console]::Error.WriteLine($msg)
        Add-Content -Path $log -Value "  -> EXIT 2 with stderr injected" -Encoding UTF8
        exit 2
    }

    exit 0
}
catch {
    $err = "HOOK_ERROR: $($_.Exception.Message)"
    [Console]::Error.WriteLine($err)
    try { Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $err" -Encoding UTF8 } catch {}
    exit 1
}
