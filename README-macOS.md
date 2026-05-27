# macOS / Linux 适配指南

这份文档给 **macOS / Linux** 用户。Windows 用户看主 [README.md](./README.md)。

工具的核心机制(Claude 规划 → Codex 执行 → asyncRewake 唤醒 → 用户拍板)在 macOS / Linux 上**完全可用**,只是底层 hook 脚本从 PowerShell 换成了 bash。

## 这版与 Windows 版的差异

| | Windows | macOS / Linux |
|---|---|---|
| Hook 脚本 | `hooks/run-codex.ps1` | `hooks/run-codex.sh` |
| Shell | PowerShell 5.1+ / 7+ | bash 3.2+(系统自带) |
| JSON 解析 | PS `ConvertFrom-Json` | `jq`(系统大概率自带) |
| 中文 BOM 坑 | ⚠️ 必须 UTF-8 with BOM | ✅ 无此问题(原生 UTF-8) |
| 路径分隔符 | `\` | `/` |
| 文件 mtime | `Get-Item.LastWriteTime` | `stat -f %m`(macOS BSD)|
| sandbox 账户锁定 | ⚠️ 已知坑 #2 | ✅ 无 Windows 登录机制问题 |

实战首通(macOS): 2026-05-27, **31 秒**跑通 hello world(比 Windows 的 110s 还快)。

## 前置依赖

```bash
# 1. codex CLI >= 0.133(同 Windows)
npm install -g @openai/codex@latest
codex --version    # 确认 >= 0.133
codex login        # 首次需登录(可走 ChatGPT 账号)

# 2. jq(99% macOS 已自带;Linux 上 apt/yum install jq)
which jq && jq --version

# 3. Claude Code 支持 asyncRewake 的新版(同 Windows)
claude --version
```

## 安装

### 方式一:项目级安装

```bash
git clone https://github.com/Work-Fisher/claude-codex-relay.git
cd claude-codex-relay
chmod +x hooks/run-codex.sh
```

### 方式二:Skill 跨项目激活

```bash
dest="$HOME/.claude/skills/claude-codex-relay"
mkdir -p "$dest"
cp SKILL.md "$dest/SKILL.md"
```

## 配置 hook(必做一步)

`.claude/settings.json` 默认是 Windows PowerShell 版。macOS / Linux 用户**有两种做法**:

### 推荐:用 `.claude/settings.local.json` override(不污染主配置)

```bash
cat > .claude/settings.local.json <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "/绝对路径/到/claude-codex-relay/hooks/run-codex.sh",
            "asyncRewake": true,
            "timeout": 1800
          }
        ]
      }
    ]
  }
}
EOF
```

把 `command` 字段改成你机器上 `run-codex.sh` 的**绝对路径**。

> `.claude/settings.local.json` 已在 `.gitignore` 里(本仓库随 PR 一并加上),不会污染 git。

### 替代:直接改 `.claude/settings.json`

复制上面 JSON 内容,粘到 `.claude/settings.json` 覆盖原 Windows 版本。注意这样改后**不要 commit**(会破坏 Windows 用户使用)。

### 关键

- **command 必须是绝对路径**(macOS Claude Code 启动 hook 时 cwd 不一定是项目根)
- 脚本必须 `chmod +x`(否则 Claude Code 执行会报 Permission denied)
- **改完必须新建 Claude 对话**才会重新加载 settings.json

## 验证

跑一个不依赖 Claude Code 的端到端冒烟测试:

```bash
cd /path/to/claude-codex-relay
mkdir -p handoff
cat > handoff/brief.md <<'EOF'
# Task: 冒烟测试
## 目标
在仓库根写一个 hello.txt, 内容 "Hello from Codex on macOS"。
## 完成判据
hello.txt 存在且内容正确。
## Out of scope
不装包, 不写测试。
EOF

# 模拟 Claude Code 发的 hook payload
echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PWD/handoff/brief.md\"}}" \
  | bash hooks/run-codex.sh
echo "exit=$?"
```

**预期**(60-120 秒内):
- stderr: `Codex 完成 (HH:MM:SS). result.md 已就绪, 请读取 ...`
- exit code: `2`(asyncRewake 信号)
- `hello.txt` 出现在仓库根
- `handoff/result.md` 含 codex 的报告
- `hooks/codex.log` 末行是 `SUCCESS`

如果上面冒烟通过,说明 hook 脚本 + codex 链路完整 OK。剩下的"Claude Code → asyncRewake 反向唤醒"环节,需要在 Claude Code 里写真实 brief.md 触发,无法在脚本层验证。

## macOS 已知坑

### 1. `stat` 命令 BSD vs GNU 差异

`run-codex.sh` 用的是 macOS BSD 语法 `stat -f %m`(取文件 mtime 用于 lock 文件年龄判断)。Linux 上 GNU `stat` 用 `-c %Y`。**如果在 Linux 跑**,把脚本中所有 `stat -f %m` 改成 `stat -c %Y`。

将来如需双平台兼容,可改用 `python -c "import os, sys; print(int(os.path.getmtime(sys.argv[1])))" "$lock"` 这种 Python 单行。

### 2. PowerShell 失败信号字符串保留

为了和 Windows 版保持行为一致,bash 版的 `failure_signals` 数组里**保留了** `CreateProcessWithLogonW failed` 这种 Windows 专属字符串。它在 macOS 上永远不会匹配到,留着不影响功能(grep 找不到是免费的)。

### 3. Codex sandbox 模式

bash 版与 ps1 版一样使用 `--sandbox danger-full-access`。macOS 上没有 Windows 那个 `CodexSandboxOffline` 账户漂移问题,理论上可用更严格的 `workspace-write` 模式,但**尚未充分测试**——保守起见保持与 ps1 一致。

### 4. 中文路径

macOS + bash + UTF-8 处理中文路径(如 `工坊/`)**没有问题**,但 `command` 字段里的中文要确保整个 JSON 是 UTF-8 编码(默认就是)。

## 文件结构(macOS 视角)

```
<ROOT>/
├── .claude/
│   ├── settings.json              # Windows 版 hook (主)
│   └── settings.local.json        # 你的 macOS override (gitignored)
├── hooks/
│   ├── run-codex.ps1              # Windows hook
│   ├── run-codex.sh               # macOS / Linux hook (新增)
│   ├── test-asyncrewake.ps1       # Windows 通道验证
│   └── codex.log                  # 运行日志 (gitignored)
├── handoff/                       # 运行时 (gitignored)
├── README.md                      # 主文档 (Windows 视角)
├── README-macOS.md                # 本文件
├── SKILL.md                       # Skill 协议
├── CLAUDE.md                      # 项目级常驻指令
└── JOURNEY.md                     # 决策复盘
```

## 致谢

bash 版本由 macOS 用户在 2026-05-27 移植,核心协议与 ps1 版完全一致。原 PowerShell 版已踩过的所有坑(参数顺序、--output-last-message 机制、asyncRewake 时序、防重入 lock、假成功检测)在 bash 版里都已对应实现。
