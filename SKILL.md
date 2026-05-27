---
name: claude-codex-relay
description: >
  Claude + Codex CLI 双 AI 协作工作流. Claude 写 brief 触发 PostToolUse hook,
  hook 调 codex exec 后台跑代码, 跑完 asyncRewake 把 Claude 叫回 review.
  2 拍板点用户控环. 前置: 当前项目装好 hook (.claude/settings.json 或 settings.local.json + hooks/run-codex.{ps1,sh}) 且 codex CLI >= 0.133.
  仅在用户显式触发时激活. 触发词: 走 codex / 用 codex 做 / 用 codex 干 / 双 AI 协作 / claude-codex / claude-codex-relay.
---

# 协议

源仓库: https://github.com/Work-Fisher/claude-codex-relay

## 自检 (触发后第一件事)

先读 `.claude/settings.json` (或 `settings.local.json`) 拿 hook `command` 字段, 根据脚本扩展名判 OS 后逐项检:

1. hook `command` 路径指向真实存在的脚本 (`.ps1` for Windows / `.sh` for macOS / Linux)
2. `codex --version` >= 0.133
3. hook 脚本完整性 (OS 分支):
   - Windows / `.ps1`: UTF-8 with BOM (前 3 字节 EF BB BF):
     ```powershell
     $b = [IO.File]::ReadAllBytes('hooks\run-codex.ps1'); "$($b[0]),$($b[1]),$($b[2])"
     # 应输出 239,187,191 — 不是则按 README "装" 一节修复
     ```
   - macOS / Linux / `.sh`: executable bit:
     ```bash
     ls -l hooks/run-codex.sh   # mode 应含 x; 没有则 chmod +x hooks/run-codex.sh
     ```
4. `handoff/codex.lock` 不存在 (有 = 上次卡死, 删之)

任一不过 → 告知用户具体哪条 + 给修复命令, 引向源仓库 README (macOS / Linux 用户还可参考 `README-macOS.md`)。

## 2 拍板点协议 (不可跳过)

1. 接到指令 → 草 brief, **念完整 markdown 待审** (不直接 Write, 一 Write hook 立刻触发拦不住)
2. 用户 OK → `Write handoff/brief.md` (这一刻 PostToolUse hook 触发 codex)
3. 等 asyncRewake (60-120s 简单 / 2-5 分钟中等 / 5-10 分钟复杂 / 30 分钟兜底)
4. 收到唤醒 → `Read handoff/result.md` (空文件 = codex 失败, 查 codex.log)
5. `Write handoff/review.md` 念给用户, **等拍 PASS / FAIL** 才执行下一步

brief 必含 4 段: 目标 / 接口或结构 / 完成判据 / **Out of scope** (显式列, 防 codex 过度工程).

## 失败速查

| 症状 | 排查 |
|---|---|
| 60s 无 asyncRewake | `hooks/codex.log` 不存在 = 脚本崩 (查 BOM); 有 START 无 SUCCESS = 还在跑; FAILURE = 看 tail |
| `result.md` 是 0 字节 | codex 失败 (常见: model 版本不支持). 升 codex CLI 到 >= 0.133 |
| **`result.md` 是简短"已完成"总结 (<500 字节) + codex.log 显示 SUCCESS + jsonl token 用量大 (output > 5k)** | **典型 hook 覆盖坑** — codex agent 用 apply_patch 写了完整内容, 但 `--output-last-message` 用最后那条简短消息覆盖了. 走 `references/extract_result.py <jsonl_path>` 从 session jsonl 重建. 根治见下节 "hook 已知坑 #1" |
| **`result.md` 含 "CreateProcessWithLogonW failed: 1326/1909"** | **Windows sandbox 账户锁定** — sandbox 密码漂移 → 重试 → 账户锁定 → exit=0 但实为假成功. 立即改用 `--sandbox danger-full-access`. 详见 "hook 已知坑 #2" |
| codex 写歪 | `git restore .` 撤 working tree; `git reset --hard HEAD^` 撤已 commit |
| lock 卡死 | Windows: `Remove-Item handoff/codex.lock` · macOS / Linux: `rm handoff/codex.lock` |

session jsonl 路径: `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-*.jsonl` (Windows: `C:\Users\<user>\.codex\sessions\...`)

## hook 已知坑 #1 · `--output-last-message` 覆盖

**机制**: `run-codex.ps1` 当前用 `codex exec --output-last-message $result`, 让 codex CLI **退出时**把 agent 最后一条消息写入 `result.md`. 但 codex agent 本身可能用 `apply_patch` 工具直接把完整内容写到 `handoff/result.md`. 两个写入路径打架, **最后那次覆盖第一次** → 完整报告丢失.

**触发条件 (满足任一就会踩)**:
- 输出超过 ~2k tokens (agent 倾向于把长内容用 apply_patch 写而非 inline 输出)
- brief 让 codex "写到 handoff/result.md" (agent 把这理解成"用工具写文件", 而不是"用最终消息表达")

**症状**: result.md 内容是 "已按 brief 完成..., 文件已校验包含 N 个段落..." 这种自述, 而不是真实分析.

**3 个根治方向 (选一)**:

1. **改 hook prompt** 加一条: "**禁止用 apply_patch / shell 写 handoff/result.md. 直接把完整内容作为你的最终回复输出, hook 会把最终回复写入 result.md.**" → 让最终消息=完整内容
2. **去掉 `--output-last-message $result`** + 改 prompt 强制 "**用 apply_patch 把内容写入 handoff/result.md, 最终回复只说一句'已写入'**" → 让 agent 工具调用是真源
3. **brief 模板里加同样的指令** (临时绕开, 不改 hook) — 但每个 brief 都要写, 容易忘

推荐 1, 因为 long output 也能 inline (codex 没有 token 截断, 只是 agent 习惯用工具), 一次改 hook 永久生效.

**当前状态**: 方向 1 在 `run-codex.ps1` 和 `run-codex.sh` 都已实施 (prompt 里的 `## handoff/result.md 输出方式` 一节). 新跑的任务不应再踩此坑.

兜底: 历史 session 丢了报告 → 用 `references/extract_result.py` 重建.

## hook 已知坑 #2 · sandbox 账户锁定 (Windows)

**机制 (2026-05-26 Codex Desktop 实证)**:

Codex Windows sandbox 用 Windows Secondary Logon (`CreateProcessWithLogonW`) 创建子进程, 跑命令时**用本地账户** `<HOSTNAME>\CodexSandboxOffline` (或 `CodexSandboxOnline`).
凭据缓存在 `C:\Users\<user>\.codex\.sandbox-secrets\sandbox_users.json`.
当**多个 Codex 入口**共存 (例如 hook 用稳定版 0.133, Desktop 用 alpha 0.133-alpha.1) 时, 各自刷新 sandbox 状态会导致**缓存密码跟系统本地账户密码漂移**.

**症状链** (典型):

1. 密码漂移 → `CreateProcessWithLogonW` 收到坏密码 → `1326 ERROR_LOGON_FAILURE`
2. codex 多次并行重试 (例如读 brief.md / AGENTS.md / 目录列表) → 触发本地账户 Lockout (threshold 10 次)
3. Account locked → 后续都是 `1909 ERROR_ACCOUNT_LOCKED_OUT` (锁定 10 分钟)
4. `result.md` 内容是 "执行端无法读取工作区... shell_command 启动失败: CreateProcessWithLogonW failed: 1326/1909"
5. 但 codex exit=0, hook 误报 SUCCESS, Claude 拿到假成功消息

**Windows Security 日志可证**:
- 4625 多次失败: `Status=0xc000006d`, `SubStatus=0xc000006a` (坏密码)
- 4740: 账户锁定
- 锁定后 4625 变 `Status=0xc0000234` (账户已锁)

**3 个修复方向**:

1. **临时**: hook 用 `--sandbox danger-full-access` 绕过 sandbox 登录链路 (立刻恢复)
2. **永久 (推荐, 已实施 2026-05-26)**: hook 永久改成 `--sandbox danger-full-access` (代价: 失去 sandbox 隔离, 但 codex agent 自身 `--ask-for-approval` 还在控)
3. **系统层**: 清理重建 `CodexSandboxOffline/Online` 凭据让 `.sandbox-secrets/sandbox_users.json` 跟本地账户密码重新一致 — **只在你想保留 sandbox 模式时才做**

**当前状态**: hook (`run-codex.ps1` 第 87 行) 已永久改为 `--sandbox danger-full-access`. 同时第 98 行加了 result.md 失败信号检测 (扫 "CreateProcessWithLogonW failed / 无法读取工作区 / shell_command 启动失败" 等), 含失败信号即使 exit=0 也判 FALSE-SUCCESS, 防 hook 静默误报.

**预防**: 不要让 Codex stable + alpha 在同一 Windows 上同时使用 sandbox 模式. 如果走 `danger-full-access`, 此问题永久不复发.

## 禁

- 不直接 Write brief.md (要先念给用户拍板)
- 不用 Edit 改 brief.md (PostToolUse 不匹配 Edit, hook 不触发)
- review FAIL 不自动改, 让用户拍板
- 不为修 typo / 改一行走这套 (中转成本 > 收益)
