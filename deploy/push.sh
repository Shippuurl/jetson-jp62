#!/usr/bin/env bash
# 把 jetson-jp62.sh + index.html + README 推到 ECS 静态站（tool.kervein.club/jetson/）
# 用法: bash deploy/push.sh
# 需要本仓库平级的 ecs.py（读 KerveinOS 环境变量工具里的 ECS_* 凭据）
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ECS="${ECS_PY:-/media/shippuu/A2Vec/toolchains/ecs.py}"
REMOTE_DIR="/var/www/jetson-jp62"
BASE="https://tool.kervein.club/jetson"
FILES=(jetson-jp62.sh index.html index.en.html index.ja.html index.de.html index.fr.html index.ko.html guide.html a2vec-logo.svg LICENSE README.md README-刷QSPI.md .nojekyll)
IMAGES=(images/jetson-board.jpg images/jumper-cap.jpg images/jumper-cap-installed.jpg \
        images/lsusb-0955.png images/jetpack-version.png images/flash-done.jpg)

[ -x /usr/bin/python3 ] || true
[ -f "$ECS" ] || { echo "找不到 ecs.py: $ECS" >&2; exit 1; }

echo "==> 本地校验"
bash -n "$SRC/jetson-jp62.sh" && echo "  语法 OK"
local_sha=$(sha256sum "$SRC/jetson-jp62.sh" | awk '{print $1}')
echo "  sha256 $local_sha"

echo "==> 上传到 $REMOTE_DIR"
python3 "$ECS" run "mkdir -p $REMOTE_DIR" >/dev/null
for f in "${FILES[@]}"; do
    python3 "$ECS" put "$SRC/$f" "$REMOTE_DIR/$f" >/dev/null
    echo "  ↑ $f"
done
python3 "$ECS" run "mkdir -p $REMOTE_DIR/images" >/dev/null
for f in "${IMAGES[@]}"; do
    python3 "$ECS" put "$SRC/$f" "$REMOTE_DIR/$f" >/dev/null
    echo "  ↑ $f"
done
python3 "$ECS" run "chmod 755 $REMOTE_DIR/jetson-jp62.sh && ls -l $REMOTE_DIR $REMOTE_DIR/images" | tail -6

echo "==> 等 nginx 稳定后验收"
sleep 3
remote_sha=$(curl -fsSL --max-time 30 "$BASE/jetson-jp62.sh" | sha256sum | awk '{print $1}')
if [ "$local_sha" = "$remote_sha" ]; then
    echo "  ✓ 远端脚本 sha256 一致"
else
    echo "  ✗ sha256 不一致: remote=$remote_sha" >&2
    exit 1
fi
for u in "$BASE/" "$BASE/index.html" "$BASE/guide.html" "$BASE/images/jetson-board.jpg" "$BASE/jetson-jp62.sh"; do
    printf '  %-46s ' "$u"
    curl -s -o /dev/null -w '%{http_code} %{content_type}\n' --max-time 20 "$u"
done

echo
echo "上线完成："
echo "  说明页  $BASE/"
echo "  一条命令 bash <(curl -fsSL $BASE/jetson-jp62.sh)"
echo "  自更新  --self-update --update-from $BASE/jetson-jp62.sh"
