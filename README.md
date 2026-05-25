# Claude + Codex 双 AI 协作 hook

我是 Work-Fisher. 这是我搭的一套 Claude Code + Codex 串联工作流.

## 干啥的

Claude 给方向, Codex 写代码, 我中间盯着.

之前让 Claude 写完方案得手动 copy 到 Codex 跑, 或者反过来, 来回切窗口烦死. 装个 Claude Code 的 PostToolUse hook + asyncRewake, Claude 一写完 `handoff/brief.md`, 后台自动喂给 codex CLI, codex 跑完写 `result.md` 然后把 Claude 叫回来 review. 我只在两个地方拍板 — brief 念给我看的时候, 和 review 念给我看的时候. 其他全自动.

## 你得先有啥

- **Claude Code** — 最低版本得支持 `asyncRewake: true` 字段. 用最新版基本不会出问题
- **codex CLI**, 必须 `>= 0.133`. 我栽过, 0.115 默认走 `gpt-5.5` 但 CLI 太老报错. `npm install -g @openai/codex@latest` 装就行
- **Windows + PowerShell 5.1 或 7+** — hook 脚本是 ps1, Linux/Mac 得自己改 bash, 我没测过
- **Python 3** — 只跑 sample 用得上, 不跑可以不装

## 装

clone 完, 改 `.claude/settings.json` 那条硬编码路径:

```json
"command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\claude-codex-relay\\hooks\\run-codex.ps1\""
```

把 `C:\\path\\to\\claude-codex-relay` 换成你 clone 的位置. Claude Code 的 hook config 不吃相对路径 (反正我没试出来), 必须绝对.

注意 `\\` 不是写错, JSON 里反斜杠要双写. 写成 `D:\foo\bar` (单根) settings.json 直接 parse 失败.

**最重要一步**: 确认 `hooks/run-codex.ps1` 是 UTF-8 **with BOM**. 不是的话 PowerShell 5.1 在中文 Windows 上会按 GBK 读, here-string 解析炸, hook 一启动就崩, 连 log 都不写. 你看着以为没触发, 实际是触发了静默挂了. 这个坑我前面栽了一晚上才找出来. 验证:

```powershell
$bytes = [System.IO.File]::ReadAllBytes("...你的路径...\hooks\run-codex.ps1")
"$($bytes[0..2] | ForEach-Object { $_.ToString('X2') })"   # 应该是 EF BB BF
```

不是 `EF BB BF` 的话, 加 BOM 的命令在 `CLAUDE.md` 技术坑 #1 段.

最后 — **新建一个 Claude Code 对话**. settings.json 不动态加载, 老对话里 hook 不生效, 这个也栽过.

## SKILL 安装 (可选, 推荐)

把 `SKILL.md` 复制到你的 Claude Code 全局 SKILL 目录:

```powershell
$dest = "$env:USERPROFILE\.claude\skills\claude-codex-relay"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item SKILL.md "$dest\SKILL.md"
```

装完之后, 任何项目里跟 Claude 说 "走 codex 做 X" 就会自动激活协议 — 不用每次手动解释 2 拍板点规则.

## 用

新对话里随便说 "用 codex 给我做个 X". Claude 会:

1. 写一份 brief, **先贴出来念给你看** (不直接 Write, 不然 hook 立刻触发, 拦不住)
2. 你说 OK, Claude 才 Write `handoff/brief.md` → hook 自动拉 codex
3. codex 跑 — hello world 大概 1-2 分钟, 中等任务 3-5 分钟, 别 60 秒就以为挂了
4. 跑完 Claude 被 asyncRewake 叫醒, 自动读 result.md, 写 review, **念 review 给你**
5. 你拍 PASS / FAIL

整个过程你就在两个地方说话: brief 念完时 OK, review 念完时 PASS. 其他全自动.

## 坑

完整的技术坑在 `CLAUDE.md` 里, 装之前最好扫一眼. 几个最容易栽的:

- **PostToolUse:Write 不匹配 Edit 工具.** 你让 Claude 用 Edit 改 brief, hook 不触发, codex 不动. 改 brief 必须用 Write 重写.

- **`~/.codex/config.toml` 影响 hook.** codex 用全局配置跑, 你的 MCP server 列表里有过期的 (figma OAuth, notion token 之类), 每次跑都浪费几秒 + 一堆 stderr error noise. 没用的 MCP 注释掉.

- **codex 失败时 result.md 是 0 字节空文件.** "文件存在" 不等于 "成功", 要看非空才算.

- **result.md 是一句 "已完成" 而不是真实报告.** codex agent 有时会先用 apply_patch 把完整内容写进 result.md, 再说一句 "已写入", 然后 `--output-last-message` 用那句 "已写入" 把完整报告盖掉. 症状: codex.log 显示 SUCCESS, jsonl token 用量大 (output > 5k), 但 result.md 只有几十个字. 当前 hook prompt 已加禁令, 正常不会再踩. 如果还是中招, 用 `references/extract_result.py` 从 session jsonl 把报告挖出来:

  ```powershell
  python references/extract_result.py --latest --write
  ```

## 没打算做的事

- **不做反向唤醒** (Codex 主动喊 Claude). 试过 MCP 桥那条路, Codex 自己说了 "MCP 解决工具结构化不解决 GUI 唤醒". 死路.
- **不 fork Claude Code 源码改协议.** 维护爆炸.
- **不为简单任务走这套.** 修 typo / 改一行直接让 Claude 自己改, 中转成本比省下的时间高.

## 详细看哪

- `CLAUDE.md` — 项目级常驻协议. 新会话启动自动加载. 完整链路图 / 三文件格式 / 技术坑 / 失败兜底矩阵
- `JOURNEY.md` — 怎么决策走到这套的, 含 7 轮拷问 + 排除的死路 + 首次实战复盘
- `SKILL.md` — Claude Code SKILL 文件, 复制到 `~/.claude/skills/claude-codex-relay/` 后跨项目自动激活
- `references/extract_result.py` — 报告丢失时的恢复工具, 从 codex session jsonl 重建 result.md
- `.claude/settings.json` — hook 配置, 一行需要改
- `hooks/run-codex.ps1` — hook 主脚本, 一般不动
