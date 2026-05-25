# Claude+Codex 协作工作流 (项目记忆)

> 项目级常驻指令, 新会话启动时自动加载。
> 配套读: `JOURNEY.md` (决策复盘), `README.md` (新用户安装指南)。

## 这是什么

Claude (规划+审核) + Codex (执行写代码) 双 AI 协作链路。Claude 写 brief 触发 hook, 自动喂给 Codex CLI, Codex 写完唤醒 Claude 做 review, 用户在 2 个拍板点控环。

**实战首通**: 2026-05-24, 110 秒跑通 hello world (首通时 HEAD `af30709`).

## 整条链路

```
你: "做 X"
我 (Claude): 写 brief, 先在对话里念给你看        🛑 拍板点 1
你: "OK"
我: Write handoff/brief.md  ←── 这一刻 PostToolUse hook 触发
       │
       └→ hooks/run-codex.ps1 后台调 codex exec
              ├→ Codex 读 brief.md 干活
              ├→ Codex 写 handoff/result.md (--output-last-message)
              └→ hook exit 2 + stderr 经 asyncRewake 把我叫醒
       │
我 (被叫醒): 读 result.md, 写 review.md, 念 review  🛑 拍板点 2
你: PASS / FAIL / 改 X / 重来
```

## 必守纪律

### 2 拍板点 (不可跳过)

- ❌ **不要直接 Write brief.md** — Write 这一刻 hook 已经触发 Codex 干活, 拦不住
- ✅ **先在对话里贴出 brief 完整 markdown 待审**, 用户拍板后再 Write (是完整内容, 不是概述大意)
- ❌ Codex 干完即使 review FAIL **不要自动让他改**
- ✅ **review 先念给用户**, 等他拍板才执行下一步 (PASS 合并 / FAIL 重做 / 改 brief 重来)

### 触发场景 (什么任务才走这套流程)

- ✅ **中等复杂度新功能**: 加 SKILL / 做小工具 / 搭 demo / 写新模块
- ❌ 修 typo / 简单改 → 直接动手, 不走 Codex
- ❌ 重构旧代码 → 探索期风险高
- ❌ 写文档/规划 → Claude 自己能做, 没必要

### 分工边界

| Claude 写 brief.md | Codex 做 |
|---|---|
| 目标 / 为什么做 | 实际写代码 |
| 接口/结构: 函数签名, 数据格式, 文件位置 | 选具体 lib, 跑测试, 修 lint |
| 关键决策方向 (用"一类"库, 不指定具体) | 处理编译/运行时错误 |
| 完成判据: 测试覆盖, 跑起来什么样 | 写 result.md (格式自适应: brief 指定格式按 brief; 没指定则默认 summary/artifacts/blockers) |
| Out of scope: 明确不做什么 (**防过度工程关键**) | |

**铁律**:
- ❌ Claude **不传伪代码** (留 Codex 发挥空间, 避免踩 lib 坑)
- ✅ Codex 默认遵守 user CLAUDE.md (中文注释 / async/await / YAGNI)

## 三文件格式

设根目录为 `<ROOT>` (你 clone 时本地的绝对路径)。

### `<ROOT>/handoff/brief.md` (Claude → Codex)
```markdown
# Task: <一句话标题>
## 目标
## 接口/结构
## 完成判据
## Out of scope    ← 显式写, 防 Codex 加 main 包装/argparse/tests 之类过度工程
```

**如需固定 result.md 格式, 在 brief 里显式写** (如 `## 期望产出`). hook prompt 自适应: brief 指定格式 → 按 brief; 没指定 → 默认三段。

### `<ROOT>/handoff/result.md` (Codex → Claude, `--output-last-message` 自动写)
默认格式 (brief 未指定时):
```markdown
## summary
## artifacts
## blockers
```

### `<ROOT>/handoff/review.md` (Claude → 用户)
```markdown
# Review: <brief 标题>
## 判断    PASS / WARN / FAIL
## 理由
## 下一步  合并 / 继续修 / 放弃
```

## 时间预期

| 任务量级 | codex exec 时长 (含 MCP startup) |
|---|---|
| hello world (1 文件 3 行) | 60-120 秒 (实测 110s) |
| 中等 (1-3 文件, < 100 行) | 2-5 分钟 |
| 复杂 (多文件 / 测试 / 处理错误) | 5-10 分钟 |
| hook timeout 兜底 | 1800 秒 (30 分钟), 超时 stderr 报 FAILURE + log tail |

Write brief.md 后 60 秒还没 asyncRewake → 先看 `hooks/codex.log` 是不是空文件 (空 = 脚本崩, 不是 codex 慢)。

## 技术坑 ⚠️ (踩过的, 别再踩)

### 1. PowerShell 脚本必须 UTF-8 **with BOM**

PS 5.1 在 zh-CN 系统读 BOMless UTF-8 文件会按 GBK 解析, here-string 解析炸, 报 `string is missing the terminator: "@`. 修脚本时:

- ❌ 用 Write 工具直接覆盖 (不一定带 BOM, 风险高)
- ✅ **实战做法**: prepend BOM 字节, 不重写其他内容
  ```powershell
  $bytes = [System.IO.File]::ReadAllBytes($path)
  if (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
      $bom = [byte[]](0xEF, 0xBB, 0xBF)
      [System.IO.File]::WriteAllBytes($path, $bom + $bytes)
  }
  ```
- ✅ 或重写时用 PS 5.1 的 `Set-Content -Encoding UTF8` (PS 5.1 默认带 BOM, **PS 7+ 默认不带, 不要用 PS 7+ 重写**)

**Edit 工具不破坏文件已有 BOM** — 实测确认 (前 3 字节 EF BB BF 保持), 可放心 Edit 改逻辑。

### 2. codex CLI 版本要求

`codex >= 0.133`. 0.115 默认走 `gpt-5.5` 模型但 CLI 太老不支持, 报 `model requires a newer version of Codex`. 升级:
```bash
npm install -g @openai/codex@latest
codex --version    # 确认 >= 0.133
```

### 3. `codex exec` 参数顺序

`--ask-for-approval never` **必须在 `exec` 前面**:
- ✅ `codex --ask-for-approval never exec ...`
- ❌ `codex exec --ask-for-approval never ...`

### 4. asyncRewake 注入时机 (不是实时!)

asyncRewake 完成时如果 Claude 没在做工具调用, 消息**排队**, 附加到 Claude 下次工具调用结果末尾。**实测包装格式**:
```
<task-notification>
<summary>Stop hook feedback</summary>
</task-notification>
<system-reminder>
Stop hook blocking error from command "PostToolUse:Write": <hook 写到 stderr 的消息>
</system-reminder>
```

Claude 看到后会自动继续 — 但前提是 Claude 这一刻在做工具调用 (或者用户发了新消息)。

### 5. 防重入

`handoff/codex.lock` 防 race。lock < 30 分钟跳过新触发, > 30 分钟视为 stale 自动清理。卡死手动:
```powershell
Remove-Item <ROOT>\handoff\codex.lock
```

### 6. 当前会话不动态加载 settings.json

改了 `.claude/settings.json` **必须新建对话**才生效。

### 7. `~/.codex/config.toml` 全局影响 hook

hook 脚本不传 `--model` / 不重写 MCP 列表, codex 用全局 `~/.codex/config.toml`。这意味着:
- 全局 `model = "gpt-5.5"` → hook 跑的就是 gpt-5.5
- 全局 `[mcp_servers.xxx]` → hook 启动 codex 时都加载. OAuth 过期 / 没登录的 MCP 会污染 stderr 但**不阻塞** codex agent loop. 噪声多就在 config.toml 注释掉过期的 MCP server

### 8. PostToolUse:Write matcher **不匹配 Edit**

只有 Write 工具触发 hook. Edit 改 `handoff/brief.md` **不触发 codex**. 这意味着:
- 改 brief 必须重新 Write 整文件 (不能 Edit 局部改)
- 改 hook 脚本 / 其他文件用 Edit 不会误触发 codex

## 失败兜底

| 症状 | 排查 |
|---|---|
| Codex 写歪了代码 | `git restore .` (撤销 working tree, Codex 没 commit). 或 `git reset --hard HEAD^` 撤已 commit |
| hook 没触发, `codex.log` 不存在 | 脚本根本没启动. 大概率: settings.json 没加载 (新建对话) 或脚本 BOM 丢了 |
| hook 没触发, `codex.log` 有 ERROR 无 TRIGGER | 脚本启动了但 parse 阶段崩. 看 ERROR 内容 (常见: BOM / 中文乱码) |
| Codex 超时/失败 | hook timeout=1800s, stderr 报 FAILURE + log tail. 看 `result.md` **是否非空** (空文件 = codex 没产输出) |
| lock 卡死 | `Remove-Item <ROOT>\handoff\codex.lock` |
| 中文乱码 | 看脚本是不是 UTF-8 with BOM (见技术坑 #1) |
| review 没生成 | 看 `result.md` 是否**非空** + Claude 是否收到 asyncRewake 唤醒 (看对话有没有 `<task-notification>` 注入) |

## 文件结构

```
<ROOT>\
├── .claude/settings.json    # PostToolUse hook + asyncRewake → run-codex.ps1 (硬编码 hook 脚本绝对路径)
├── .gitignore               # 忽略整个 handoff/ + samples/ + log
├── CLAUDE.md                # 本文件
├── JOURNEY.md               # 决策复盘
├── README.md                # 给新用户的安装指南
├── handoff/                 # 运行时目录, 整体 gitignore
│   ├── brief.md             # Claude 写 → 触发 hook
│   ├── result.md            # Codex 写 (--output-last-message 自动写)
│   ├── review.md            # Claude 写 → 给用户看
│   └── codex.lock           # runtime
├── samples/                 # 测试场, gitignore
└── hooks/
    ├── run-codex.ps1        # 主 hook (必须 UTF-8 with BOM!)
    ├── test-asyncrewake.ps1 # 通道验证脚本, 调试用
    └── codex.log            # 运行日志 (gitignored)
```

## 演进规则

跑完 2-3 个真任务后回顾, 不要追求完美协议:

- 哪个 brief 字段没人写 / 没人看 → 删
- 反复缺的字段 → 加
- 哪个拍板点用户每次秒过 → 考虑省掉
- 时序问题 / race conditions 频发 → 加 `state.json` 状态机
- Codex 框架烂的发现机制: 看 `result.md` 的 `blockers` 段 + 用户自查 brief
- 想要 Codex 反审 brief (双向监督) → 当前还没启用, 看 JOURNEY.md "未来选项"

## 不要做的事

- ❌ 不要再装 MCP 桥做反向唤醒 (Codex 自己说了 GUI 解决不了, 浪费工程量)
- ❌ 不要试图操控 Codex GUI 窗口 (Codex 桌面没有外部触发入口)
- ❌ 不要为简单任务走这套流程 (中转成本 > 收益)
- ❌ 不要在 hook 脚本里直接写中文路径字符串 (用 `$PSScriptRoot` + `Split-Path` 自动解析)
