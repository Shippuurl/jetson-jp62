#!/usr/bin/env python3
"""串口日志：采集 → 规则提炼 → 全量落盘 → 打包。单文件，无第三方依赖（pyserial 仅采集时需要）。

设计边界
  - 只读串口：不发送任何刷写/控制字节。
  - 规则只做大小写不敏感的文字匹配（不执行正则、不执行代码），命中不等于定论。
  - 原始字节永远保留（full.bin），解码失败也不丢数据。
  - 规则集带版本与 sha256：更新时校验、拒绝回退、备份旧版、原子替换；
    但哈希只防传输损坏，不防上游被改（要防需要签名，未实现）。

命令行
  python uart-logs.py                       自动选口，采 60 秒，打包
  python uart-logs.py --seconds 0           持续采集，Ctrl-C 结束（仍打包）
  python uart-logs.py --port COM3 --baud 115200
  python uart-logs.py --input boot.log      离线回放已有日志
  python uart-logs.py --list [--json]       列出候选串口
  python uart-logs.py --update-rules <url|dir> [--force]
  python uart-logs.py --make-index          重新生成 rules/index.json 的哈希
  python uart-logs.py --pack <run_dir>      打包已有会话目录
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import pathlib
import re
import shutil
import sys
import time
import zipfile

BASE = "https://raw.githubusercontent.com/Shippuurl/jetson-jp62/main/"
# GitHub 在国内常被墙：更新规则时按顺序回退（可用 --rules-url 指定内网镜像）
BASES = [BASE, "https://tool.kervein.club/jetson/"]
HERE = pathlib.Path(__file__).resolve().parent
RULES_VERSION_FALLBACK = 0

# pyserial 不是必需：离线回放/打包不需要它
try:  # pragma: no cover - 环境相关
    from serial.tools import list_ports  # type: ignore
except Exception:  # pragma: no cover
    list_ports = None

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")

# 常见 USB-TTL 的 VID/PID（打分用）：命中越靠前越优先
USB_HINTS = {
    (0x1A86, 0x7523): ("CH340", 40),
    (0x1A86, 0x55D4): ("CH343", 40),
    (0x1A86, 0x55D3): ("CH343", 40),
    (0x10C4, 0xEA60): ("CP2102", 40),
    (0x10C4, 0xEA70): ("CP2105", 38),
    (0x0403, 0x6001): ("FT232", 40),
    (0x0403, 0x6015): ("FT231X", 38),
    (0x2E8A, 0x000A): ("Raspberry Pi Pico", 36),
    (0x0483, 0x5740): ("ST VCP", 34),
    (0x2341, 0x0043): ("Arduino", 20),
}
# 明确不该默认选中的（蓝牙虚拟口、ACPI 主板口）
USB_PENALTY = {
    (0x0A12, 0x0001): -50,  # CSR 蓝牙
    (0x8087, 0x0026): -50,
    (0x8087, 0x0A2B): -50,
}

DEFAULT = {
    "version": 0,
    "context": 3,
    "rules": [
        {"id": "fault", "severity": "error", "context": 3,
         "terms": ["error", "fail", "panic", "timeout", "watchdog", "assert", "abort", "unable"]},
        {"id": "boot-stage", "severity": "info", "context": 2,
         "terms": ["MB1", "MB2", "UEFI", "Linux version", "Booting Linux", "Reached target"]},
    ],
}

BOARD_TERMS = {
    "jetson": ["tegra", "jetson", "orin", "L4T", "nvgpu", "tegra234"],
    "raspberrypi": ["Raspberry Pi", "bcm27", "raspi", "bcm2835", "bcm2711"],
}


# --------------------------------------------------------------------------- 规则
def validate(data):
    """规则结构校验：出错直接抛 ValueError，绝不半加载。返回规范化的 dict。"""
    if not isinstance(data, dict):
        raise ValueError("rules must be an object")
    rules = data.get("rules")
    if not isinstance(rules, list) or not rules:
        raise ValueError("rules must be a non-empty list")
    ctx_default = int(data.get("context", 3))
    if not 0 <= ctx_default <= 30:
        raise ValueError("context must be 0..30")
    out = []
    for r in rules:
        if not isinstance(r, dict):
            raise ValueError("rule must be an object")
        rid = r.get("id")
        if not isinstance(rid, str) or not rid.strip():
            raise ValueError("rule id required")
        terms = r.get("terms")
        if not isinstance(terms, list) or not terms or not all(isinstance(t, str) and t.strip() for t in terms):
            raise ValueError(f"{rid}: terms must be non-empty strings")
        ctx = int(r.get("context", ctx_default))
        if not 0 <= ctx <= 30:
            raise ValueError(f"{rid}: context must be 0..30")
        sev = r.get("severity", "error")
        if sev not in ("error", "warn", "info"):
            raise ValueError(f"{rid}: severity must be error|warn|info")
        out.append({"id": rid, "terms": terms, "context": ctx, "severity": sev,
                    "advice": r.get("advice", "")})
    return {"version": int(data.get("version", 0)), "context": ctx_default, "rules": out}


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def user_rules_dir() -> pathlib.Path:
    if os.name == "nt":
        base = os.environ.get("APPDATA") or (pathlib.Path.home() / "AppData" / "Roaming")
    elif sys.platform == "darwin":
        base = pathlib.Path.home() / "Library" / "Application Support"
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or (pathlib.Path.home() / ".config")
    return pathlib.Path(base) / "serial-log" / "rules"


def target_rules_dir() -> pathlib.Path:
    """更新写入的位置：显式 SERIAL_LOG_RULES_DIR 优先，否则用户配置目录。"""
    env = os.environ.get("SERIAL_LOG_RULES_DIR")
    return pathlib.Path(env) if env else user_rules_dir()


def rules_search_path(cli_value: str | None) -> pathlib.Path | None:
    """--rules → $SERIAL_LOG_RULES_DIR → 用户配置目录 → 内置目录。"""
    for cand in (cli_value, os.environ.get("SERIAL_LOG_RULES_DIR"), user_rules_dir()):
        if cand and pathlib.Path(cand).exists():
            return pathlib.Path(cand)
    if (HERE / "rules").exists():
        return HERE / "rules"
    return None


def read_index(folder: pathlib.Path) -> dict | None:
    idx = folder / "index.json"
    if not idx.exists():
        return None
    data = json.loads(idx.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or "files" not in data:
        raise ValueError("index.json 缺 files")
    return data


def load_rules(path_arg, board="auto", verbose=True):
    """返回 (规则 dict, 元信息)。不带 index.json 的旧目录按单文件 uart.json 处理。"""
    folder = rules_search_path(path_arg)
    if folder is None:
        return dict(DEFAULT, source="builtin"), {"source": "builtin", "version": DEFAULT["version"]}

    if folder.is_file():  # 直接给了单个规则文件
        raw = folder.read_bytes()
        data = validate(json.loads(raw))
        return dict(data, source=str(folder)), {"source": str(folder), "version": data["version"],
                                                "sha256": sha256_bytes(raw)}

    index = read_index(folder)
    if index is None:
        legacy = folder / "uart.json"
        if not legacy.exists():
            return dict(DEFAULT, source="builtin"), {"source": "builtin", "version": DEFAULT["version"]}
        raw = legacy.read_bytes()
        data = validate(json.loads(raw))
        return dict(data, source=str(legacy)), {"source": str(legacy), "version": data["version"],
                                                "sha256": sha256_bytes(raw)}

    wanted = {"common"} if board == "common" else ({"common", board} if board in BOARD_TERMS else {"common"})
    rules, files, versions = [], [], []
    for entry in index.get("files", []):
        name = entry.get("name")
        if not name:
            continue
        f = folder / name
        if not f.exists():
            if verbose:
                print(f"[rules] 缺文件，跳过：{name}", file=sys.stderr)
            continue
        raw = f.read_bytes()
        want = entry.get("sha256")
        if want and sha256_bytes(raw) != want:
            raise ValueError(f"规则文件校验失败：{name}（本地 sha256 不匹配 index.json）")
        data = validate(json.loads(raw))
        this_board = data.get("board", entry.get("board", "common"))
        versions.append(data["version"])
        if this_board in wanted:
            rules.extend(data["rules"])
            files.append(name)
    if not rules:
        return dict(DEFAULT, source="builtin"), {"source": "builtin", "version": DEFAULT["version"]}

    merged = {"version": max(versions or [0]), "context": index.get("context", 3),
              "rules": rules, "source": str(folder)}
    meta = {"source": str(folder), "version": merged["version"], "files": files,
            "board": board, "index_version": index.get("version")}
    if verbose:
        print(f"[rules] v{merged['version']} · {len(rules)} 条 · {', '.join(files)} · board={board}", file=sys.stderr)
    return merged, meta


def detect_board(text: str, configured: str = "auto") -> str:
    if configured in BOARD_TERMS or configured == "common":
        return configured
    low = text[:40000].lower()
    best, best_n = "common", 0
    for board, terms in BOARD_TERMS.items():
        n = sum(low.count(t.lower()) for t in terms)
        if n > best_n:
            best, best_n = board, n
    return best


# --------------------------------------------------------------------------- 分析
def analyze(raw: bytes, rules: dict):
    """返回 (行列表, 命中列表, 解码文本)。行号从 1 开始；命中带上下文窗口。"""
    text = ANSI.sub("", raw.decode("utf-8", "replace"))
    lines = text.splitlines()
    hits, seen = [], set()
    for r in rules.get("rules", []):
        terms = [t.lower() for t in r.get("terms", [])]
        ctx = int(r.get("context", rules.get("context", 3)))
        for i, line in enumerate(lines):
            low = line.lower()
            if any(t in low for t in terms):
                lo, hi = max(0, i - ctx), min(len(lines), i + ctx + 1)
                key = (r["id"], i)
                if key in seen:
                    continue
                seen.add(key)
                hits.append({"rule": r["id"], "severity": r.get("severity", "error"),
                             "line": i + 1, "text": line.strip()[:400],
                             "context": lines[lo:hi], "advice": r.get("advice", "")})
    hits.sort(key=lambda h: h["line"])
    return lines, hits, text


def write_outputs(folder: pathlib.Path, raw: bytes, lines, hits, rules, meta):
    (folder / "full.bin").write_bytes(raw)
    (folder / "full.log").write_text("\n".join(lines), encoding="utf-8")
    important = []
    for h in hits:
        important.append(f"#{h['line']} [{h['severity']}/{h['rule']}] {h['text']}")
        for c in h["context"]:
            important.append(f"    | {c}")
        if h.get("advice"):
            important.append(f"    -> {h['advice']}")
    (folder / "important.log").write_text("\n".join(important) or "(no rule hits)", encoding="utf-8")
    (folder / "rules.json").write_text(json.dumps(rules, ensure_ascii=False, indent=2), encoding="utf-8")
    (folder / "rules-meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    return important


def package(folder: pathlib.Path, rules: dict, source: str, status: dict):
    """打包：all-logs.zip / important-logs.zip / summary.json / index.html。"""
    folder = pathlib.Path(folder)
    raw_path = folder / "full.bin"
    raw = raw_path.read_bytes() if raw_path.exists() else b""
    summary = {
        "status": status.get("status", "ok"),
        "source": source,
        "bytes": len(raw),
        "sha256": sha256_bytes(raw),
        "rules_version": rules.get("version", 0),
        "rules_source": rules.get("source", ""),
        "reconnects": status.get("reconnects", 0),
        "end_reason": status.get("end_reason", ""),
        "created": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "important_lines": len((folder / "important.log").read_text(encoding="utf-8").splitlines())
        if (folder / "important.log").exists() else 0,
    }
    (folder / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    all_members = ["full.bin", "full.log", "important.log", "summary.json", "rules.json", "rules-meta.json"]
    with zipfile.ZipFile(folder / "all-logs.zip", "w", zipfile.ZIP_DEFLATED) as z:
        for name in all_members:
            p = folder / name
            if p.exists():
                z.write(p, arcname=name)
    with zipfile.ZipFile(folder / "important-logs.zip", "w", zipfile.ZIP_DEFLATED) as z:
        for name in ["important.log", "summary.json", "rules.json", "rules-meta.json"]:
            p = folder / name
            if p.exists():
                z.write(p, arcname=name)

    (folder / "index.html").write_text(
        "<!doctype html><meta charset=utf-8><title>Jetson logs</title>"
        "<style>body{font:15px/1.7 system-ui;margin:40px auto;max-width:640px;color:#202428}"
        "a{color:inherit}code{background:#f4f5f6;padding:1px 5px}</style>"
        f"<h1>串口采集 · {html.escape(folder.name)}</h1>"
        f"<p>状态 <code>{html.escape(str(summary['status']))}</code> · {summary['bytes']} 字节 · "
        f"规则 v{summary['rules_version']} · 命中 {summary['important_lines']} 行</p>"
        "<p><a href=\"all-logs.zip\" download>下载全部日志（zip）</a><br>"
        "<a href=\"important-logs.zip\" download>下载重要日志（zip）</a></p>"
        "<p>本地文件：<code>full.log</code> / <code>important.log</code> / <code>summary.json</code></p>",
        encoding="utf-8")
    return summary


# --------------------------------------------------------------------------- 采集
def scored_ports():
    if list_ports is None:
        return []
    out = []
    for p in list_ports.comports():
        vid, pid = p.vid or 0, p.pid or 0
        name, score = USB_HINTS.get((vid, pid), (p.description or "USB serial", 10))
        score += USB_PENALTY.get((vid, pid), 0)
        desc = (p.description or "").lower()
        if "bluetooth" in desc or "acpi" in desc:
            score -= 40
        if vid or pid:
            score += 5
        out.append({"device": p.device, "description": p.description or "", "vid": vid, "pid": pid,
                    "chip": name, "score": score,
                    "hwid": p.hwid or "", "serial": getattr(p, "serial_number", "") or ""})
    out.sort(key=lambda x: x["score"], reverse=True)
    return out


def do_list(as_json=False):
    ports = scored_ports()
    if as_json:
        print(json.dumps(ports, ensure_ascii=False, indent=2))
        return 0
    if not ports:
        print("没找到串口设备。检查：USB-TTL 驱动是否装上、线是否支持数据、是否在容器里（需要 --device）。")
        return 1
    print(f"候选串口 {len(ports)} 个（得分高者优先）：")
    for i, p in enumerate(ports, 1):
        flag = "  ← 推荐" if i == 1 and p["score"] >= 30 else ("  (低可信)" if p["score"] < 20 else "")
        print(f"  {i}) {p['device']:<22} {p['chip']:<18} score={p['score']:<4} {p['description']}{flag}")
    return 0


def pick_port(requested=None):
    if requested:
        return requested
    ports = scored_ports()
    if not ports:
        raise SystemExit("没找到串口设备；用 --list 看看，或显式 --port")
    best = ports[0]
    if best["score"] >= 30 or len(ports) == 1:
        print(f"[serial-log] 自动选择 {best['device']}（{best['chip']}，score={best['score']}）", file=sys.stderr)
        return best["device"]
    print("多个候选端口，请选择：", file=sys.stderr)
    for i, p in enumerate(ports, 1):
        print(f"  {i}) {p['device']}  {p['chip']}  score={p['score']}  {p['description']}", file=sys.stderr)
    if not sys.stdin.isatty():
        print(f"[serial-log] 非交互环境，取最高分 {best['device']}", file=sys.stderr)
        return best["device"]
    while True:
        try:
            n = int(input("序号 > ").strip() or "1")
        except ValueError:
            continue
        if 1 <= n <= len(ports):
            return ports[n - 1]["device"]


def capture(port, baud, seconds, folder: pathlib.Path, progress=True):
    """逐字节读，实时落盘。返回 status。"""
    import serial  # 只有这里需要 pyserial

    folder.mkdir(parents=True, exist_ok=True)
    buf = bytearray()
    line_buf = bytearray()
    reconnects = 0
    end_reason = "duration"
    started = time.time()

    def flush_line(stamp=True):
        nonlocal line_buf
        if not line_buf:
            return
        text = bytes(line_buf).decode("utf-8", "replace").rstrip("\r\n")
        prefix = dt.datetime.now().strftime("%H:%M:%S.%f")[:-3] + " " if stamp else ""
        with (folder / "full.log").open("a", encoding="utf-8") as fh:
            fh.write(prefix + text + "\n")
        line_buf = bytearray()

    (folder / "full.log").write_text("", encoding="utf-8")
    with (folder / "full.bin").open("wb") as raw_fh:
        while True:
            if seconds and time.time() - started >= seconds:
                break
            try:
                with serial.Serial(port, baud, timeout=0.2) as ser:
                    ser.reset_input_buffer()
                    while True:
                        if seconds and time.time() - started >= seconds:
                            break
                        chunk = ser.read(4096)
                        if not chunk:
                            continue
                        raw_fh.write(chunk)
                        raw_fh.flush()
                        buf.extend(chunk)
                        line_buf.extend(chunk)
                        while b"\n" in line_buf:
                            idx = line_buf.index(b"\n") + 1
                            head = line_buf[:idx]
                            line_buf = line_buf[idx:]
                            text = bytes(head).decode("utf-8", "replace").rstrip("\r\n")
                            ts = dt.datetime.now().strftime("%H:%M:%S.%f")[:-3]
                            with (folder / "full.log").open("a", encoding="utf-8") as fh:
                                fh.write(f"{ts} {text}\n")
                        if progress and len(buf) % 8192 < 4096:
                            print(f"\r[serial-log] {len(buf)} 字节", end="", file=sys.stderr)
                    break
            except KeyboardInterrupt:
                end_reason = "ctrl-c"
                break
            except Exception as exc:  # 断线重连
                reconnects += 1
                end_reason = f"disconnected: {exc}"
                with (folder / "full.log").open("a", encoding="utf-8") as fh:
                    fh.write(f"[serial-log] reconnected ({reconnects}) after: {exc}\n")
                if reconnects >= 3:
                    break
                time.sleep(2)
    flush_line()
    if progress:
        print("", file=sys.stderr)
    return {"status": "ok" if end_reason in ("duration", "ctrl-c") else "incomplete",
            "reconnects": reconnects, "end_reason": end_reason, "bytes": len(buf)}


# --------------------------------------------------------------------------- 规则更新
def _fetch(url_or_dir: str) -> bytes:
    """本地路径直接读；否则按 BASES 依次回退取 .tmp 同目录的相对文件。"""
    p = pathlib.Path(url_or_dir)
    if p.exists():
        return p.read_bytes() if p.is_file() else b""
    import urllib.request
    last = None
    for base in BASES:
        url = url_or_dir if url_or_dir.startswith("http") else base + url_or_dir
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "serial-log/1"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read()
        except Exception as exc:  # 换下一个源
            last = exc
    raise SystemExit(f"取规则失败：{url_or_dir}（最后错误：{last}）")


def update_rules(src: str, force=False, verbose=True):
    """从本地目录或 HTTP 源更新规则：校验 sha256、拒绝回退、旧版备份、原子替换。

    本地目录：直接读该目录；HTTP：先 source 自身的 index.json，文件按相对名取，
    失败再回退到 BASES（GitHub → 自建站）。
    """
    folder = target_rules_dir()
    src_path = pathlib.Path(src)
    is_local = src_path.is_dir()
    if is_local and src_path.resolve() == folder.resolve():
        raise SystemExit("更新源不能与目标目录相同")

    index_raw = (src_path / "index.json").read_bytes() if is_local else _fetch(src.rstrip("/") + "/index.json")
    index = json.loads(index_raw)
    new_ver = int(index.get("version", 0))

    old_ver = 0
    old_index = folder / "index.json"
    if old_index.exists():
        try:
            old_ver = int(json.loads(old_index.read_text(encoding="utf-8")).get("version", 0))
        except Exception:
            old_ver = 0
    if new_ver < old_ver and not force:
        raise SystemExit(f"拒绝回退：远端 v{new_ver} < 本地 v{old_ver}（要覆盖加 --force）")

    staging = folder.with_suffix(".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    fetched = []
    try:
        for entry in index.get("files", []):
            name = entry["name"]
            raw = (src_path / name).read_bytes() if is_local else _fetch(name)
            want = entry.get("sha256")
            if want and sha256_bytes(raw) != want:
                raise SystemExit(f"sha256 不匹配，已中止：{name}")
            validate(json.loads(raw))          # 结构不对也中止，避免写坏规则
            (staging / name).write_bytes(raw)
            fetched.append(name)
    except SystemExit:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    (staging / "index.json").write_bytes(index_raw)

    if folder.exists():                        # 旧版整目录备份
        backup = folder.with_name(f"rules.bak.{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.move(str(folder), str(backup))
        if verbose:
            print(f"[rules] 旧版已备份：{backup}")
    os.replace(staging, folder)                # 同盘原子替换
    if verbose:
        print(f"[rules] 已更新到 v{new_ver}：{', '.join(fetched)} → {folder}")
    return new_ver


def make_index(folder: pathlib.Path):
    """为本目录的规则文件生成 index.json（发布前固定哈希）。"""
    entries, version = [], 0
    for f in sorted(folder.glob("*.json")):
        if f.name == "index.json":
            continue
        data = json.loads(f.read_text(encoding="utf-8"))
        validate(data)
        version = max(version, int(data.get("version", 0)))
        entries.append({"name": f.name, "board": data.get("board", "common"),
                        "sha256": sha256_bytes(f.read_bytes())})
    index = {"version": version, "context": 3, "files": entries}
    (folder / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"已生成 {folder / 'index.json'}（v{version}，{len(entries)} 个文件）")
    return index


# --------------------------------------------------------------------------- 主流程
def session_dir(root: pathlib.Path) -> pathlib.Path:
    ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    d = root / ts
    d.mkdir(parents=True, exist_ok=True)
    return d


def main():
    p = argparse.ArgumentParser(description="串口日志采集 / 筛选 / 打包")
    p.add_argument("--port")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--seconds", type=float, default=60, help="0 = 直到 Ctrl-C")
    p.add_argument("--input", "--replay", dest="input", type=pathlib.Path, help="离线回放已有日志")
    p.add_argument("--output", type=pathlib.Path, default=pathlib.Path.home() / "Downloads" / "Jetson-Logs")
    p.add_argument("--rules", help="规则目录或单个规则文件")
    p.add_argument("--rules-url", default=BASE + "rules/")
    p.add_argument("--board", default="auto", choices=["auto", "common", "jetson", "raspberrypi"])
    p.add_argument("--offline", action="store_true", help="不联网取规则")
    p.add_argument("--list", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--update-rules", metavar="URL_OR_DIR")
    p.add_argument("--force", action="store_true")
    p.add_argument("--make-index", action="store_true")
    p.add_argument("--pack", metavar="RUN_DIR")
    args = p.parse_args()

    if args.list:
        return do_list(args.json)

    if args.pack:
        d = pathlib.Path(args.pack)
        raw = (d / "full.bin").read_bytes() if (d / "full.bin").exists() else b""
        rules, meta = load_rules(args.rules, args.board, verbose=False)
        lines, hits, _ = analyze(raw, rules)
        write_outputs(d, raw, lines, hits, rules, meta)
        package(d, rules, str(d), {"status": "packed"})
        print(f"已打包：{d / 'all-logs.zip'}")
        return 0

    if args.make_index:
        folder = pathlib.Path(args.rules or rules_search_path(None) or HERE / "rules")
        make_index(folder)
        return 0

    if args.update_rules:
        update_rules(args.update_rules, force=args.force)
        return 0

    # 规则：先用内置/本地，采集完再按内容判断板型（auto 时）
    rules, meta = load_rules(args.rules, "common" if args.board == "auto" else args.board)

    if args.input:
        raw = args.input.read_bytes()
        out = session_dir(args.output)
        (out / "full.bin").write_bytes(raw)
        (out / "source.txt").write_text(str(args.input), encoding="utf-8")
        status = {"status": "replayed", "end_reason": "input"}
        source = f"file:{args.input}"
    else:
        if args.offline:
            pass
        port = pick_port(args.port)
        out = session_dir(args.output)
        print(f"[serial-log] {port} @ {args.baud} 8N1 · {('持续直到 Ctrl-C' if not args.seconds else str(int(args.seconds)) + 's')}"
              f" · 输出 {out}", file=sys.stderr)
        status = capture(port, args.baud, args.seconds, out)
        source = f"serial:{port}"
        rules2, meta2 = load_rules(args.rules, args.board)
        rules, meta = rules2, meta2

    raw = (out / "full.bin").read_bytes() if (out / "full.bin").exists() else b""
    if args.board == "auto":
        text = raw.decode("utf-8", "replace")
        board = detect_board(text, "auto")
        if board != "common":
            print(f"[serial-log] 日志看起来是 {board}，切换到 {board} 规则集", file=sys.stderr)
            rules, meta = load_rules(args.rules, board)
    lines, hits, _ = analyze(raw, rules)
    write_outputs(out, raw, lines, hits, rules, meta)
    summary = package(out, rules, source, status)

    print()
    print(f"Saved locally: {out}")
    print(f"All: {out / 'all-logs.zip'}")
    print(f"Important: {out / 'important-logs.zip'}")
    print(f"Shortcut: {(out / 'index.html').as_uri()}")
    print(f"{summary['bytes']} bytes · {summary['important_lines']} important lines · rules v{summary['rules_version']} · {summary['status']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
