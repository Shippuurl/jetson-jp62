#!/usr/bin/env python3
"""把 /jetson/ 静态目录 location 插进 tool.kervein.club 的 **443 server 块**，
插在 root 行之后（HTTP 的 80 块是纯 301，放进去不生效）。幂等 + 失败回滚。"""
import re, shutil, subprocess, sys, time

CONF = "/etc/nginx/sites-enabled/tool.kervein.club.conf"
MARK = "# ---- jetson-jp62 工具（脚本 + 说明页），独立目录，不走 SPA 兜底 ----"
BLOCK = f"""
    {MARK}
    location ^~ /jetson/ {{
        alias /var/www/jetson-jp62/;
        index index.html;
        autoindex on;
        charset utf-8;
        default_type text/plain;
        types {{ text/html html htm; text/plain sh md txt; image/svg+xml svg; }}
        add_header Content-Disposition "inline" always;
        add_header Cache-Control "no-cache" always;
        include /etc/nginx/snippets/a2vec-security.conf;
    }}
"""

src = open(CONF, encoding="utf-8").read()

# 1) 先清掉可能被插错位置（80 块）的旧块
if MARK in src:
    lines = src.splitlines(keepends=True)
    kept, skip = [], False
    for l in lines:
        if MARK in l:
            skip = True
            continue
        if skip:
            if re.match(r"\s*\}\s*$", l):     # 该 location 的收尾
                skip = False
            continue
        kept.append(l)
    src = "".join(kept)
    print("已移除旧的 /jetson/ 块，准备插到正确位置")

lines = src.splitlines(keepends=True)
idx = None
for i, l in enumerate(lines):
    if l.strip().startswith("root /var/www/tool.kervein.club/current;"):
        idx = i + 1
        break
if idx is None:
    print("FAIL: 没找到 443 server 块的 root 行")
    sys.exit(1)

bak = "/root/nginx-backups/tool.kervein.club.conf.bak-" + time.strftime("%Y%m%d-%H%M%S")
subprocess.run(["mkdir", "-p", "/root/nginx-backups"], check=False)
shutil.copy2(CONF, bak)
open(CONF, "w", encoding="utf-8").write("".join(lines[:idx]) + BLOCK + "".join(lines[idx:]))

t = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
print(t.stderr.strip()[-300:])
if t.returncode != 0:
    shutil.copy2(bak, CONF)
    print("FAIL: nginx -t 失败，已回滚")
    sys.exit(1)
subprocess.run(["systemctl", "reload", "nginx"], check=True)
print("OK: 已插入 443 块并 reload；备份", bak)
