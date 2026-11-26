#!/usr/bin/env bash
# ============================================================================
# find-host.sh — 按网卡 MAC 定位主机当前 IP（在 Windows Git Bash 里跑）
#
# 背景：主机走 DHCP（热点 / 路由器），重启后 IP 会变，ssh 别名就连不上了。
# 本脚本靠网卡 MAC 认机器：扫一遍本机所在网段，再倒查 ARP 表。
#
# 用法：
#   bash find-host.sh aa-bb-cc-dd-ee-ff              # 只找，不改配置
#   bash find-host.sh aa-bb-cc-dd-ee-ff --apply      # 找到后写回 ~/.ssh/config
#
# 可选环境变量：
#   SSH_ALIAS=host        要更新的 ~/.ssh/config 里的 Host 别名
#   SSH_USER=me           登录用户名（默认取当前 Windows 用户）
#
# 查 MAC：在主机上跑 ip link 看 link/ether 那一行。
# ============================================================================

MAC="${1:-${HOST_MAC:-}}"
APPLY=0
[ "${2:-}" = "--apply" ] && APPLY=1

if [ -z "$MAC" ]; then
    echo "用法: bash $0 <MAC地址> [--apply]"
    echo "例:   bash $0 aa-bb-cc-dd-ee-ff --apply"
    exit 1
fi

SSH_ALIAS="${SSH_ALIAS:-host}"
SSH_USER="${SSH_USER:-$USER}"

mac_norm=$(echo "$MAC" | tr 'A-Z' 'a-z' | tr ':' '-')

# 本机所有 IPv4 网段（排除 VirtualBox 的 192.168.56/119 这类虚拟网卡）
prefixes=$(ipconfig 2> /dev/null | iconv -f gbk -t utf-8 2> /dev/null \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -vE '^(255|0)\.' | sort -u \
    | awk -F. 'NF==4 && !($1==192 && $2==168 && ($3==56||$3==119)) {print $1"."$2"."$3}')

[ -z "$prefixes" ] && { echo "读不到本机网段，先跑 ipconfig 看看网络是否连着"; exit 1; }

echo "本机所在网段：$(echo $prefixes | tr '\n' ' ')"
echo "正在按 MAC $mac_norm 扫描……"

found=""
for p in $prefixes; do
    for i in $(seq 1 254); do
        ping -n 1 -w 200 "$p.$i" > /dev/null 2>&1 &
    done
    wait
    hit=$(arp -a 2> /dev/null | iconv -f gbk -t utf-8 2> /dev/null \
        | grep -i "$mac_norm" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    if [ -n "$hit" ]; then found="$hit"; break; fi
done

if [ -z "$found" ]; then
    echo "没找到。可能原因："
    echo "  1) 目标机器没开机 / 不在同一网段"
    echo "  2) 路由器开了客户端隔离（AP isolation），同网段互相看不见"
    echo "  → 在目标机器上跑 ip a，或看系统设置里的 IPv4 地址"
    exit 2
fi

echo "找到：$found"
ssh-keygen -F "$found" > /dev/null 2>&1 || ssh-keyscan -H "$found" >> ~/.ssh/known_hosts 2> /dev/null

if ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$found" true 2> /dev/null; then
    echo "SSH 免密登录：正常"
else
    echo "SSH 能连但免密失败 —— 检查公钥是否在目标机器的 ~/.ssh/authorized_keys 里"
fi

if [ "$APPLY" -eq 1 ]; then
    [ -f ~/.ssh/config ] || { echo "没有 ~/.ssh/config，先手动建一个 Host $SSH_ALIAS 段落"; exit 1; }
    cp ~/.ssh/config ~/.ssh/config.bak 2> /dev/null
    sed -i "s/^\(Host $SSH_ALIAS\)/\1/; /^Host $SSH_ALIAS/,/^Host / s/^\( *HostName \).*/\1$found/" ~/.ssh/config
    echo "已更新 ~/.ssh/config（备份在 ~/.ssh/config.bak）"
    grep -A3 "^Host $SSH_ALIAS" ~/.ssh/config
else
    echo "想自动改配置就加 --apply"
fi
