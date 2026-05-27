#!/usr/bin/env bash
# Triggered by Claude Code PostToolUse:Write hook (macOS / Linux port).
# Bash port of run-codex.ps1; see CLAUDE.md / README.md for behavior details.
#
# Requires:
#   - codex CLI >= 0.133
#   - jq (for parsing Claude Code hook payload JSON)
#   - macOS / Linux with bash 3.2+
#
# After Codex finishes, exit 2 + stderr wakes Claude up via asyncRewake.
#
# Encoding note: bash + macOS/Linux default to UTF-8, so the BOM dance the
# Windows .ps1 has to do is not needed here.

set -u  # error on undefined vars; we deliberately NOT use set -e for finer control

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/codex.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" >> "$LOG" 2>/dev/null || true
}

lock=""
cleanup() {
    # Only remove lock if THIS instance owns it (lock var still set).
    # If we exited because another instance owns it, we cleared `lock` first.
    [ -n "$lock" ] && [ -f "$lock" ] && rm -f "$lock"
}
trap cleanup EXIT

# === read hook payload from stdin ===
if [ -t 0 ]; then
    # No stdin attached, nothing to do
    exit 0
fi
raw="$(cat)"

if [ -z "$raw" ]; then
    log "stdin empty, exit 0"
    exit 0
fi

tool="$(printf '%s' "$raw" | jq -r '.tool_name // empty' 2>/dev/null || echo "")"
file="$(printf '%s' "$raw" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")"

basename_=""
if [ -n "$file" ]; then
    basename_="$(basename "$file")"
fi

# Fast path: only handoff/brief.md is interesting
if [ "$basename_" != "brief.md" ]; then
    exit 0
fi

case "$file" in
    */handoff/brief.md) ;;
    *)
        log "skip non-handoff brief: $file"
        exit 0
        ;;
esac

log "TRIGGER tool=$tool file=$file"

handoff="$(dirname "$file")"
root="$(dirname "$handoff")"
brief="$file"
result="$handoff/result.md"
lock="$handoff/codex.lock"

# === Reentry guard ===
if [ -f "$lock" ]; then
    lock_mtime="$(stat -f %m "$lock" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age=$(( now - lock_mtime ))
    if [ "$age" -lt 1800 ]; then  # 30 min
        log "skip: lock alive (age ${age}s)"
        echo "Codex already running (lock age ${age}s). Trigger ignored." >&2
        # Don't remove the live lock owned by another instance.
        lock=""  # prevent trap cleanup from touching it
        exit 2
    fi
    log "stale lock cleared (age $(( age / 60 )) min)"
    rm -f "$lock"
fi

touch "$lock"
[ -f "$result" ] && rm -f "$result"

log "START codex exec, root=$root"

# === Codex prompt (here-doc; $brief / $root expand) ===
prompt="$(cat <<EOF
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
EOF
)"

# === Run codex ===
# Sandbox mode: danger-full-access (parity with ps1; macOS doesn't have the
# Windows CodexSandboxOffline / LogonW issue, but keeping the same setting for
# behavioral parity until we test a more restrictive mode).
codex_out="$(printf '%s' "$prompt" | codex --ask-for-approval never exec \
    -C "$root" \
    --sandbox danger-full-access \
    --skip-git-repo-check \
    --color never \
    --output-last-message "$result" \
    - 2>&1)"
code=$?

log "codex exit=$code"

# Lock cleared on normal exit path (trap covers crash path)
rm -f "$lock"
lock=""

# === Success path with false-success detection ===
if [ "$code" -eq 0 ] && [ -f "$result" ]; then
    result_content="$(cat "$result" 2>/dev/null || echo "")"

    # Failure signals lifted from upstream ps1. The Windows-specific signals
    # ('CreateProcessWithLogonW failed') won't appear on macOS, but we keep
    # them in the list for fidelity and because grep-not-finding-them is free.
    failure_signals=(
        'CreateProcessWithLogonW failed'
        '无法读取工作区'
        '无法读取.*brief\.md'
        'shell_command 启动失败'
        'sandbox.*failed'
        '执行端无法'
    )
    matched_signal=""
    for pattern in "${failure_signals[@]}"; do
        m="$(printf '%s' "$result_content" | grep -oE "$pattern" 2>/dev/null | head -1 || true)"
        if [ -n "$m" ]; then
            matched_signal="$m"
            break
        fi
    done

    if [ -n "$matched_signal" ]; then
        msg="Codex 假成功 (exit=0 但 result.md 含失败信号: '$matched_signal'). Hook 判 FAILURE. 详见 SKILL.md hook 已知坑 #2."
        echo "$msg" >&2
        log "FALSE-SUCCESS signal=$matched_signal"
        exit 2
    fi

    msg="Codex 完成 ($(date '+%H:%M:%S')). result.md 已就绪, 请读取 handoff/result.md, 审核并写 handoff/review.md, 然后向用户报告 review 结论等待拍板。"
    echo "$msg" >&2
    log "SUCCESS"
    exit 2
fi

# === Failure path ===
tail_="$(printf '%s' "$codex_out" | tail -10)"
msg="Codex 失败 (exit=$code). result.md 可能缺失/不完整。Tail: $tail_"
echo "$msg" >&2
log "FAILURE tail=$tail_"
exit 2
