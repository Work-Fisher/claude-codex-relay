# 决策复盘: 从"想搞个双 AI 协作"到"hook 链路打通"

> 一份给未来回看 / 给新会话快速理解项目演化的记录。
> 配套读: `CLAUDE.md` (协议规范), `README.md` (安装指南)。

## 起点
用户想要 Claude (规划) + Codex (执行) 串联协作, 互相监督, 减少人工切窗口。

## 决策树 (走 `mp-grill-me` 7 轮拷问)

| # | 问题 | 决定 |
|---|---|---|
| 0 | 核心目标 | **纯探索**, 允许翻车 |
| 1 | 监督方向 | **单向起步** (Claude 审 Codex), 跑几次再考虑双向 |
| 2 | 通信通道 | **文件交接** + 极简字段 (`handoff/*.md`) |
| 3 | 触发场景 | **中等复杂度新功能** (加 SKILL / 小工具 / demo) |
| 4 | 分工边界 | Claude 写"是什么 + 为什么 + 完成标准", **不传伪代码** |
| 5 | 交接格式 | 3 文件 10 字段 (brief 4 / result 3 / review 3) |
| 6 | 仲裁 | **用户拍板** (不默认听某一方) |
| 7 | 兜底 | **git init**, 建议 brief 前 commit |

## 关键技术发现 (实测确认)

### 1. Claude Code Hooks 有 `asyncRewake: true`
官方 GA 字段, 文档: https://code.claude.com/docs/en/hooks
机制: hook 后台跑, `exit 2` + stderr → 自动注入回 Claude 当前会话。

### 2. asyncRewake 不是实时弹出
消息**排队**, 附加到 Claude 下次工具调用结果末尾。**实测包装格式**: `<task-notification>` 外层 + `<system-reminder>` 内层包 `Stop hook blocking error from command "PostToolUse:Write": ...`.

### 3. 当前会话不动态加载 settings.json
改了 `.claude/settings.json` 必须**新建对话**才生效。

### 4. PS 5.1 在 zh-CN 系统的编码坑
读 BOMless UTF-8 按 GBK 解析, here-string 大坑。所有 hook 脚本必须 UTF-8 with BOM。

### 5. Edit 工具不破坏文件已有 BOM (实测)
加 BOM 后用 Edit 改逻辑, BOM 仍在 (前 3 字节 EF BB BF). 修脚本时可放心 Edit, 不会误丢 BOM。

### 6. `~/.codex/config.toml` 全局影响 hook
hook 不传 `--model` / 不重写 MCP server 列表, codex 用全局配置。这意味着:
- 全局 `model = "gpt-5.5"` → hook 跑就是 gpt-5.5
- 全局过期的 `[mcp_servers.xxx]` (OAuth 失败 / 没登录) → 每次 hook 启动都有 ~3 秒 timeout + 一堆 stderr noise (但不阻塞 codex agent loop)

### 7. PostToolUse:Write matcher 不匹配 Edit
只有 Write 工具触发 hook. 用 Edit 改 brief.md 不触发 codex (实战中改 hook 脚本 / config.toml 用 Edit, 验证过都没误触发)。

## 走过的弯路 / 排除的死路

| 方案 | 为什么否决 |
|---|---|
| **MCP 桥做反向唤醒** | Codex 自己澄清: MCP 解决工具结构化, **不解决 GUI 反向唤醒** |
| **AutoGen / CrewAI / LangGraph** | 走 orchestrator + API 模式, 丢 Codex CLI 自带工具链 |
| **Google A2A protocol** | Claude Code 和 Codex 都没原生 endpoint, 需自造适配器 |
| **fork Claude Code 源** | 维护爆炸 |
| **试图操控 Codex GUI 窗口** | Codex 桌面没外部触发入口 |
| **复制粘贴 brief 内容给 Codex** | 装 Codex CLI 后完全没必要 |

## Codex 自评的关键背书

> "全自动如果要做, **优先研究 Codex CLI non-interactive**, 而不是 GUI MCP。
> Claude Hook 可以直接调用 Codex CLI 执行 brief, 这比试图唤醒 GUI 更靠谱。"

来自 Codex 自己的诊断, 直接采纳作为最终方向。

## 现状 / 最终方案

**Claude Code Hooks (PostToolUse + asyncRewake) + Codex CLI exec non-interactive**

- `.claude/settings.json` 配置 hook
- `hooks/run-codex.ps1` 监听 brief.md 写入, 调 `codex exec`, 完成后 exit 2 唤醒 Claude
- 2 拍板点 (brief 后 + review 后), 用户始终在控制环上
- 详细协议见 `CLAUDE.md`

## 首次实战 (2026-05-24)

**任务**: `samples/hello.py` 写一个 Python hello world 验证链路 (1-2 分钟级别的最小任务)。

**实际时长**: 110 秒 (codex exec, 22:21:27 → 22:23:17, 含 MCP startup 失败 timeout)。

**路上踩的 3 个坑** (这两份文档存在的全部原因):

1. **PS 脚本无 BOM** → 中文 Windows PS 5.1 用 GBK 解析 → here-string 终止符识别失败 → hook 静默崩, 既没日志也没 lock. 第一反应"hook 没触发", 实际是 hook 被 Claude Code 正常拉起但脚本崩在 `Add-Content` 之前. **修复**: prepend BOM 字节 (`[System.IO.File]::WriteAllBytes`).

2. **codex 0.115.0 不支持默认 gpt-5.5** → 第二次跑 codex exec 启动但报 `model requires a newer version of Codex`, result.md 写 0 字节空文件. **修复**: `npm install -g @openai/codex@latest` 升到 0.133.

3. **codex MCP figma/notion OAuth 过期 / 未登录** → 每次 codex exec 启动都浪费 ~3 秒 + 一堆 stderr error noise (但不阻塞 agent loop). **修复**: `~/.codex/config.toml` 注释这两段 MCP server.

**结果**: PASS。链路 7 节点全通: Claude Write brief → hook → codex exec → result.md → asyncRewake → review → 用户拍板。

## 当前未启用的选项 (未来想升级时再看)

| 选项 | 启用条件 |
|---|---|
| **双向监督** (Codex 反审 brief) | 跑了几次发现 Claude 框架经常写歪了 → 在 hook 链路前加一步"Codex 反审 brief" |
| **MCP server 做共享工具** | 想要状态机 / 防重入升级时, 不再用单纯文件 + lock |
| **`/loop` 自动轮询** | Claude 想自己定期查 result.md (虽然有 asyncRewake 大概率用不到) |
| **去掉 brief 拍板点** | 跑熟了发现自己每次都秒过, 可省掉这步 |

## Codex 给的可直接复用命令模板

```powershell
$prompt | codex --ask-for-approval never exec `
  -C '<ROOT>' `
  --sandbox workspace-write `
  --skip-git-repo-check `
  --color never `
  --output-last-message '<ROOT>\handoff\result.md' `
  -
```

参数细节:
- `--ask-for-approval never` 必须在 `exec` 前
- `--output-last-message` 把 Codex 最终回复直接写到指定文件, 不用 parse stdout
- `--skip-git-repo-check` 早期没 git init 时加的, 现在 init 了可以去掉但留着也不影响
- `-` 表示 prompt 从 stdin 读

## 引用 commit

- `515089e` (root): 脚手架初始化 (`.claude/settings.json` / `.gitignore` / `hooks/run-codex.ps1` / `hooks/test-asyncrewake.ps1`)
- `61e161e`: `hooks/run-codex.ps1` 加 UTF-8 BOM + 文档化 codex CLI >= 0.133 要求 + 编码注意事项
- `af30709`: `.gitignore` 扩展, 整个 `handoff/` 和 `samples/` 不入库
