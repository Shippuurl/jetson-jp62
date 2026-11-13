#!/usr/bin/env python3
"""把 /jetson/ 静态目录 location 插进 tool.kervein.club 的 443 server 块。

要点（踩过的坑）：
  - 必须插在 443 块里（80 块是纯 301，放进去不生效）
  - 不能只写 `types { html; sh; }` —— nginx 的 types 是"替换"而非"追加"，
    会把 svg/woff2 全变成 default_type，导致 <img src="*.svg"> 渲染失败。
    这里改成 include /etc/nginx/mime.types，再单独给 .sh 设 text/plain。
幂等 + nginx -t 失败自动回滚。
"""
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
        include /etc/nginx/mime.types;
        add_header Content-Disposition "inline" always;
        add_header Cache-Control "no-cache" always;
        include /etc/nginx/snippets/a2vec-security.conf;
        # 脚本按纯文本返回，方便 curl 直接看
        location ~ \\.sh$ {{ default_type text/plain; }}
    }}
"""

src = open(CONF, encoding="utf-8").read()

if MARK in src:
    lines = src.splitlines(keepends=True)
    kept, skip, depth = [], False, 0
    for l in lines:
        if MARK in l:
            skip, depth = True, 0
            continue
        if skip:
            depth += l.count("{") - l.count("}")
            if depth <= 0 and "}" in l:
                skip = False
            continue
        kept.append(l)
    src = "".join(kept)
    print("已移除旧的 /jetson/ 块")

lines = src.splitlines(keepends=True)
idx = None
for i, l in enumerate(lines):
    if l.strip().startswith("root /var/www/tool.kervein.club/current;"):
        idx = i + 1
        break
if idx is None:
    print("FAIL: 没找到 443 server 块的 root 行")
    sys.exit(1)

subprocess.run(["mkdir", "-p", "/root/nginx-backups"], check=False)
bak = "/root/nginx-backups/tool.kervein.club.conf.bak-" + time.strftime("%Y%m%d-%H%M%S")
shutil.copy2(CONF, bak)
open(CONF, "w", encoding="utf-8").write("".join(lines[:idx]) + BLOCK + "".join(lines[idx:]))

t = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
print(t.stderr.strip()[-300:])
if t.returncode != 0:
    shutil.copy2(bak, CONF)
    print("FAIL: nginx -t 失败，已回滚")
    sys.exit(1)
subprocess.run(["systemctl", "reload", "nginx"], check=True)
print("OK: 已写入 443 块并 reload；备份", bak)
