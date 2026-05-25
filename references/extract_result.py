#!/usr/bin/env python3
"""
extract_result.py  —  从 codex session jsonl 重建 handoff/result.md

背景:
  run-codex.ps1 用 --output-last-message 把 codex 最后一条消息写入 result.md。
  如果 codex agent 先用 apply_patch 把完整报告写入 result.md，再说一句简短的"已完成"，
  --output-last-message 会用"已完成"覆盖完整报告 → 报告丢失。
  这个脚本从 session jsonl 里把 apply_patch 的真实内容挖出来。

用法:
  python references/extract_result.py <jsonl_path>           # 打印到 stdout
  python references/extract_result.py <jsonl_path> --write   # 写入 handoff/result.md
  python references/extract_result.py --latest               # 自动找最新 session
  python references/extract_result.py --latest --write       # 自动找 + 写入

session jsonl 路径:
  Windows: C:\\Users\\<user>\\.codex\\sessions\\YYYY\\MM\\DD\\rollout-<timestamp>-*.jsonl
  macOS/Linux: ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-*.jsonl
"""

import json
import sys
import os
import glob
import argparse
from pathlib import Path


# ── apply_patch 内容提取 ──────────────────────────────────────────────

def _parse_apply_patch_content(patch_str: str, target_keyword: str = "result.md") -> str | None:
    """
    从 apply_patch 的 patch 字符串里提取针对 target_keyword 的内容。

    apply_patch 格式示例 (Add File):
        *** Begin Patch
        *** Add File: handoff/result.md
        +# Analysis Results
        +...
        *** End Patch

    apply_patch 格式示例 (Update File):
        *** Begin Patch
        *** Update File: handoff/result.md
         context line
        -old line
        +new line
        *** End Patch
    """
    if target_keyword not in patch_str:
        return None

    lines = patch_str.splitlines()
    collecting = False
    content_lines = []

    for line in lines:
        # 找到目标文件段落的开始
        if ("Add File:" in line or "Update File:" in line or "*** " in line) and target_keyword in line:
            collecting = True
            content_lines = []
            continue

        # 遇到下一个文件段落或 End Patch 时停止
        if collecting:
            if line.startswith("*** "):
                break
            # Add File 模式: 所有 + 开头行是新内容
            if line.startswith("+"):
                content_lines.append(line[1:])
            # Update File 模式: + 是新增, 空格是上下文, - 是删除(跳过)
            elif line.startswith(" "):
                content_lines.append(line[1:])
            # 空行视为分隔
            elif line == "":
                content_lines.append("")

    result = "\n".join(content_lines).strip()
    return result if result else None


def _extract_from_function_call(entry: dict, target: str = "result.md") -> str | None:
    """从单条函数调用 JSON 里尝试提取内容。"""
    # 兼容多种 jsonl 格式的函数调用字段名
    name = (
        entry.get("name")
        or entry.get("function_name")
        or (entry.get("function") or {}).get("name", "")
    )
    if not isinstance(name, str):
        name = ""

    # 只处理文件写入类工具
    write_tools = {"apply_patch", "str_replace_editor", "create_file", "write_file",
                   "write_to_file", "replace_in_file"}
    if name not in write_tools:
        return None

    # 获取参数 (可能是 JSON 字符串或 dict)
    raw_args = (
        entry.get("arguments")
        or entry.get("input")
        or (entry.get("function") or {}).get("arguments", "")
    )
    if isinstance(raw_args, str):
        try:
            args = json.loads(raw_args)
        except json.JSONDecodeError:
            # apply_patch 的参数可能是纯 patch 字符串
            if target in raw_args:
                return _parse_apply_patch_content(raw_args, target)
            return None
    elif isinstance(raw_args, dict):
        args = raw_args
    else:
        return None

    # apply_patch: 参数里有 patch 字段
    if name == "apply_patch":
        patch = args.get("patch") or args.get("input") or ""
        if target in patch:
            extracted = _parse_apply_patch_content(patch, target)
            if extracted:
                return extracted

    # str_replace_editor / write_file: 直接有 content / new_content
    if target in str(args.get("path", "")) or target in str(args.get("filename", "")):
        content = (
            args.get("content")
            or args.get("new_content")
            or args.get("file_text")
            or ""
        )
        if content:
            return content

    return None


# ── jsonl 递归遍历 ────────────────────────────────────────────────────

def _walk(obj, apply_patch_hits: list, assistant_texts: list, depth: int = 0):
    """深度优先遍历 JSON，收集函数调用内容和 assistant 消息。"""
    if depth > 20:  # 防止无限递归
        return

    if isinstance(obj, dict):
        # 尝试作为函数调用解析
        hit = _extract_from_function_call(obj)
        if hit:
            apply_patch_hits.append(hit)
            return  # 不需要再往下钻

        # 尝试作为 assistant 消息解析
        role = obj.get("role") or obj.get("type", "")
        if role == "assistant":
            content = obj.get("content", "")
            if isinstance(content, str) and len(content) > 100:
                assistant_texts.append(content)
            elif isinstance(content, list):
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "text":
                        text = item.get("text", "")
                        if len(text) > 100:
                            assistant_texts.append(text)

        # 继续递归
        for v in obj.values():
            if isinstance(v, (dict, list)):
                _walk(v, apply_patch_hits, assistant_texts, depth + 1)

    elif isinstance(obj, list):
        for item in obj:
            _walk(item, apply_patch_hits, assistant_texts, depth + 1)


# ── 主提取逻辑 ────────────────────────────────────────────────────────

def extract_from_jsonl(jsonl_path: str) -> str | None:
    apply_patch_hits: list[str] = []
    assistant_texts: list[str] = []
    parse_errors = 0

    with open(jsonl_path, "r", encoding="utf-8", errors="replace") as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError as e:
                parse_errors += 1
                if parse_errors <= 3:
                    print(f"  [warn] line {line_num}: JSON parse error — {e}", file=sys.stderr)
                continue
            _walk(entry, apply_patch_hits, assistant_texts)

    if parse_errors > 3:
        print(f"  [warn] ... and {parse_errors - 3} more parse errors", file=sys.stderr)

    # 优先返回最长的 apply_patch 内容（最可能是真实报告）
    if apply_patch_hits:
        best = max(apply_patch_hits, key=len)
        print(f"  [info] apply_patch 命中 {len(apply_patch_hits)} 次，取最长 ({len(best)} 字符)", file=sys.stderr)
        return best

    # 退路：最长 assistant 消息（过滤掉明显的短自述）
    if assistant_texts:
        # 去掉明显的自述性短消息
        candidates = [t for t in assistant_texts
                      if not any(kw in t for kw in ["已完成", "已写入", "已校验", "详见 result"])]
        pool = candidates if candidates else assistant_texts
        best = max(pool, key=len)
        print(f"  [info] 未找到 apply_patch，用最长 assistant 消息 ({len(best)} 字符)", file=sys.stderr)
        return best

    return None


# ── 自动找最新 session ────────────────────────────────────────────────

def find_latest_jsonl() -> str | None:
    home = Path.home()
    pattern = str(home / ".codex" / "sessions" / "**" / "rollout-*.jsonl")
    files = glob.glob(pattern, recursive=True)
    if not files:
        return None
    return max(files, key=os.path.getmtime)


# ── CLI ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="从 codex session jsonl 重建 handoff/result.md",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("jsonl", nargs="?", help="session jsonl 路径")
    parser.add_argument("--latest", action="store_true", help="自动找最新 session jsonl")
    parser.add_argument("--write", action="store_true", help="写入 handoff/result.md (默认打印到 stdout)")
    args = parser.parse_args()

    # 确定 jsonl 路径
    if args.latest or not args.jsonl:
        jsonl_path = find_latest_jsonl()
        if not jsonl_path:
            print("错误: ~/.codex/sessions/ 下没有找到 rollout-*.jsonl", file=sys.stderr)
            sys.exit(1)
        print(f"  [info] 使用: {jsonl_path}", file=sys.stderr)
    else:
        jsonl_path = args.jsonl

    if not os.path.exists(jsonl_path):
        print(f"错误: 文件不存在: {jsonl_path}", file=sys.stderr)
        sys.exit(1)

    # 提取
    content = extract_from_jsonl(jsonl_path)
    if not content:
        print("错误: jsonl 里没有找到可提取的内容。", file=sys.stderr)
        print("提示: 检查 jsonl 路径是否正确；或 codex 从未写过 result.md。", file=sys.stderr)
        sys.exit(1)

    # 输出
    if args.write:
        result_path = Path("handoff") / "result.md"
        result_path.parent.mkdir(exist_ok=True)
        result_path.write_text(content, encoding="utf-8")
        print(f"  [ok] 已写入 {result_path} ({len(content)} 字符)", file=sys.stderr)
    else:
        print(content)


if __name__ == "__main__":
    main()
