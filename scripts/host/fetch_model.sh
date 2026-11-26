#!/bin/bash
# 下载 YOLOv8n 权重到 ~/yolov8n.pt（约 6 MB）
#
#   bash scripts/host/fetch_model.sh              # 默认下载到 ~/yolov8n.pt
#   bash scripts/host/fetch_model.sh /path/x.pt   # 指定位置
#
# 仓库里不放权重：二进制大文件不适合进 git，且随时可重新下载。
# 直连 GitHub 慢或被墙时，脚本会自动走镜像。
set -o pipefail

DEST="${1:-$HOME/yolov8n.pt}"

if [ -f "$DEST" ]; then
    echo "已存在：$DEST（$(du -h "$DEST" | cut -f1)），不用重复下载"
    exit 0
fi

URLS=(
    "https://ghproxy.net/https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n.pt"
    "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n.pt"
)

for u in "${URLS[@]}"; do
    echo "下载：$u"
    if curl -fL --connect-timeout 10 --max-time 180 -o "$DEST.part" "$u"; then
        # .pt 是 zip 容器，开头应为 PK，且大小不应明显偏小
        size=$(stat -c %s "$DEST.part" 2> /dev/null || echo 0)
        if [ "$size" -gt 5000000 ] && [ "$(head -c 2 "$DEST.part")" = "PK" ]; then
            mv "$DEST.part" "$DEST"
            echo "完成：$DEST（$(du -h "$DEST" | cut -f1)）"
            exit 0
        fi
        echo "  文件不完整（${size} 字节），换下一个源"
    else
        echo "  失败，换下一个源"
    fi
    rm -f "$DEST.part"
done

echo "全部源都失败了。可手动下载后放到 $DEST："
echo "  https://github.com/ultralytics/assets/releases"
exit 1
