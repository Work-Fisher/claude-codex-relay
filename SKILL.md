---
name: claude-codex-relay
description: >
  Claude + Codex CLI 双 AI 协作工作流. Claude 写 brief 触发 PostToolUse hook,
  hook 调 codex exec 后台跑代码, 跑完 asyncRewake 把 Claude 叫回 review.
  2 拍板点用户控环. 前置: 当前项目装好 hook (.claude/settings.json + hooks/run-codex.ps1) 且 codex CLI >= 0.133.
  仅在用户显式触发时激活. 触发词: 走 codex / 用 codex 做 / 用 codex 干 / 双 AI 协作 / claude-codex / claude-codex-relay.
---

# 协议

源仓库: https://github.com/Work-Fisher/claude-codex-relay

## 自检 (触发后第一件事)

1. `.claude/settings.json` 存在, `command` 字段路径指向真实存在的 `hooks/run-codex.ps1`
2. `codex --version` >= 0.133
3. `hooks/run-codex.ps1` 是 UTF-8 with BOM (前 3 字节 EF BB BF) — 验证:
   ```powershell
   $b = [IO.File]::ReadAllBytes('hooks\run-codex.ps1'); "$($b[0]),$($b[1]),$($b[2])"
   # 应输出 239,187,191 — 不是则按 README "装" 一节修复
   ```
4. `handoff/codex.lock` 不存在 (有 = 上次卡死, 删之)

任一不过 → 告知用户具体哪条 + 给修复命令, 引向源仓库 README。

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
| codex 写歪 | `git restore .` 撤 working tree; `git reset --hard HEAD^` 撤已 commit |
| lock 卡死 | `Remove-Item handoff/codex.lock` |

## 禁

- 不直接 Write brief.md (要先念给用户拍板)
- 不用 Edit 改 brief.md (PostToolUse 不匹配 Edit, hook 不触发)
- review FAIL 不自动改, 让用户拍板
- 不为修 typo / 改一行走这套 (中转成本 > 收益)
