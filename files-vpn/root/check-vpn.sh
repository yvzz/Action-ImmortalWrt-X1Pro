#!/bin/sh
# ============================================================
# X1Pro L2TP/IPsec 状态检测 + 自动修复脚本
# v2-watchdog:
#   - 修复: 接口未建立时 [2] 步 die 早退导致后续修复不执行
#   - 顺序调整: 先拉起 L2TP 接口, 再补子网路由, 再查 IPsec
#   - 温和化: 接口 pending / IPsec connecting 时不打断, 避免反复重启卡死隧道
#   - 增加运行锁, 兼容 cron 看门狗与 hotplug 并发触发
# 用法:  sh /root/check-vpn.sh [接口名] [远端目标IP] [远端网段]
# ============================================================

# --- 运行锁 (cron 看门狗与 hotplug 可能并发, 10 分钟过期) ---
LOCK="/var/lock/vpn-check.lock"
if [ -e "$LOCK" ]; then
  if [ -n "$(find "$LOCK" -mmin +10 2>/dev/null)" ]; then
    rm -f "$LOCK"
  else
    exit 0
  fi
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

CONF="/tmp/l2tp-setup.conf"
[ -f "$CONF" ] && . "$CONF"

# --- 自动检测 L2TP 接口 ---
auto_detect_ifname() {
    uci show network 2>/dev/null \
        | sed -n "/network\./s/^network\.\([^.]*\)[.]proto='l2tp'$/\1/p" \
        | head -1
}

# 接口名: CLI arg > conf > UCI 自动检测, 都无则退出
[ -n "$1" ] && IFNAME="$1"
[ -z "$IFNAME" ] && IFNAME="${IFNAME:-$(auto_detect_ifname)}"
[ -z "$IFNAME" ] && { echo "[skip] 未找到 L2TP 接口"; exit 0; }

# 远端目标 IP: CLI arg > conf > UCI, 都无则退出
[ -n "$2" ] && DST_TARGET="$2"
[ -z "$DST_TARGET" ] && DST_TARGET=$(uci -q get network.$IFNAME.dst_target 2>/dev/null)
[ -z "$DST_TARGET" ] && DST_TARGET=$(uci -q get network.vpn_route.target 2>/dev/null)
[ -z "$DST_TARGET" ] && { echo "[skip] DST_TARGET 未配置"; exit 0; }

# 远端网段: conf > CLI arg > UCI > vpn_route 推断, 都无则退出
[ -z "$DST_SUBNET" ] && [ -n "$3" ] && DST_SUBNET="$3"
[ -z "$DST_SUBNET" ] && DST_SUBNET=$(uci -q get network.$IFNAME.dst_subnet 2>/dev/null)
if [ -z "$DST_SUBNET" ]; then
    RT_TARGET=$(uci -q get network.vpn_route.target 2>/dev/null)
    RT_NETMASK=$(uci -q get network.vpn_route.netmask 2>/dev/null)
    case "$RT_NETMASK" in
        255.255.255.0) DST_SUBNET="$RT_TARGET/24" ;;
        255.255.0.0)   DST_SUBNET="$RT_TARGET/16" ;;
        255.0.0.0)     DST_SUBNET="$RT_TARGET/8"  ;;
    esac
fi
[ -z "$DST_SUBNET" ] && { echo "[skip] DST_SUBNET 未配置"; exit 0; }

NET_DEV="l2tp-$IFNAME"

# 检测是否启用 IPsec (psks 非空则启用; 兜底: ipsec 二进制+配置存在也视为启用)
PSKS=$(uci -q get network.$IFNAME.psks 2>/dev/null)
USE_IPSEC=0
[ -n "$PSKS" ] && USE_IPSEC=1
[ $USE_IPSEC -eq 0 ] && [ -x /usr/sbin/ipsec ] && [ -f /etc/ipsec.conf ] && USE_IPSEC=1

# 检测 WAN (多级回退)
detect_wan() {
    WAN_DEV="$(ip route show default 2>/dev/null | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
    WAN_GW="$(ip route show default 2>/dev/null | grep 'via ' | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)"
    if [ -z "$WAN_DEV" ]; then
        WAN_DEV="$(ip route 2>/dev/null | grep 'via ' | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
        [ -z "$WAN_DEV" ] && WAN_DEV="$(ip route 2>/dev/null | grep 'proto static' | grep -v 'dev ppp\|dev l2tp\|dev br-lan' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
        [ -z "$WAN_DEV" ] && WAN_DEV="$(ip addr 2>/dev/null | grep -E '^[0-9]+: (eth|wan|usb|enp)' | sed 's/.*: \([^:@]*\).*/\1/' | head -1)"
    fi
    if [ -z "$WAN_GW" ]; then
        WAN_GW="$(ip route 2>/dev/null | grep "dev $WAN_DEV" | grep 'via ' | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)"
        [ -z "$WAN_GW" ] && WAN_GW="$(ifstatus wan 2>/dev/null | sed -n 's/.*"gateway": "\([^"]*\).*/\1/p' | head -1)"
        [ -z "$WAN_GW" ] && WAN_GW="$(uci -q get network.wan.gateway 2>/dev/null)"
    fi
}
detect_wan

PASS=0
FAIL=0
FIXED=0

# check 函数: 参数1=退出码, 参数2=描述文字
check() {
    if [ "$1" -eq 0 ]; then
        echo "  [ok] $2"; PASS=$((PASS+1))
    else
        echo "  [FAIL] $2"; FAIL=$((FAIL+1))
    fi
}

# ============================================================
# 修复函数 (全部非致命: 修复失败仅计数, 看门狗下轮重试)
# ============================================================

fix_default_route() {
    echo "  → 修复: 恢复默认路由到 WAN ..."
    ip route del default dev "$NET_DEV" 2>/dev/null
    if [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ]; then
        ip route del default 2>/dev/null
        ip route add default via "$WAN_GW" dev "$WAN_DEV" 2>/dev/null
        if ip route show default 2>/dev/null | grep -q "dev $WAN_DEV"; then
            FIXED=$((FIXED+1)); echo "  [fixed] 默认路由已恢复 $WAN_DEV via $WAN_GW"; return 0
        fi
    fi
    return 1
}

mask_from_prefix() {
    # 逐字节构造 32 位掩码, 避免 busybox ash 下 0xFFFFFFFF<<N 溢出算成 0.0.0.0
    local p=$1 byte i result=""
    for i in 0 1 2 3; do
        if [ "$p" -ge 8 ]; then byte=255; p=$((p - 8))
        else byte=0; [ "$p" -gt 0 ] && byte=$(( 256 - (1 << (8 - p)) )); p=0; fi
        result="$result$byte"; [ "$i" -lt 3 ] && result="$result."
    done
    echo "$result"
}

fix_subnet_route() {
    echo "  → 修复: 添加 $DST_SUBNET dev $NET_DEV ..."
    # 设备不存在则等接口先起来 (由 [2] fix_l2tp_up 处理), 不再 die
    [ -d "/sys/class/net/$NET_DEV" ] || { echo "  [note] $NET_DEV 设备不存在, 先拉起接口"; return 1; }
    ip route replace "$DST_SUBNET" dev "$NET_DEV" 2>/dev/null
    if ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"; then
        uci -q delete network.vpn_route 2>/dev/null
        uci set network.vpn_route=route
        uci set network.vpn_route.interface="$IFNAME"
        uci set network.vpn_route.target="${DST_SUBNET%/*}"
        uci set network.vpn_route.netmask="$(mask_from_prefix "${DST_SUBNET#*/}")"
        uci commit network
        FIXED=$((FIXED+1)); echo "  [fixed] $DST_SUBNET dev $NET_DEV"; return 0
    fi
    return 1
}

fix_ipsec() {
    # 已建立则不处理
    ipsec status 2>/dev/null | grep -q ESTABLISHED && return 0
    # 正在协商: 若存在多个 charon 实例(开机启动竞争残留的孤儿进程),
    # 协商会永远卡在 CONNECTING, 必须清理后重启; 否则等待不打断
    if ipsec status 2>/dev/null | grep -qE "connecting|CONNECTING"; then
        local n
        n=$(ps 2>/dev/null | grep -c "[c]haron")
        if [ "${n:-0}" -gt 1 ]; then
            echo "  → 检测到 ${n} 个 charon 实例(启动竞争残留), 清理后重启"
        else
            echo "  → IPsec 正在协商, 等待不打断 ..."
            local t=0
            while [ $t -lt 30 ]; do
                ipsec status 2>/dev/null | grep -q ESTABLISHED && { echo "  [ok] IPsec 协商完成"; return 0; }
                sleep 5; t=$((t + 5))
            done
        fi
    fi
    echo "  → 修复: 重启 IPsec (清理全部 charon) ..."
    [ -f /etc/strongswan.d/charon/kernel-libipsec.conf ] && \
        sed -i 's/^[[:space:]]*load[[:space:]]*=[[:space:]]*yes/load = no/' \
            /etc/strongswan.d/charon/kernel-libipsec.conf
    fix_default_route >/dev/null 2>&1
    ip xfrm state flush >/dev/null 2>&1
    /etc/init.d/ipsec stop >/dev/null 2>&1
    # 杀光所有 charon/starter (含开机启动竞争残留的孤儿实例), 清 pidfile
    killall -9 charon starter 2>/dev/null
    rm -f /var/run/charon.pid /var/run/starter.charon.pid
    sleep 1
    /etc/init.d/ipsec start >/dev/null 2>&1
    local t=0
    while [ $t -lt 60 ]; do
        ipsec status 2>/dev/null | grep -q ESTABLISHED && break
        sleep 5; t=$((t + 5))
    done
    if ipsec status 2>/dev/null | grep -q ESTABLISHED; then
        FIXED=$((FIXED+1)); echo "  [fixed] IPsec ESTABLISHED"; return 0
    fi
    return 1
}

fix_l2tp_up() {
    # netifd 正在建立(pending=true): 先等待; 若超时仍未 UP 说明 netifd 自身卡住, 强制重启
    if ifstatus "$IFNAME" 2>/dev/null | grep -q '"pending": true'; then
        echo "  → 接口正在建立中(pending), 等待最多 60s ..."
        local t=0
        while [ $t -lt 60 ]; do
            ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true' && { echo "  [ok] 接口已自动 UP"; return 0; }
            sleep 5; t=$((t + 5))
        done
        echo "  → 接口仍卡在 pending (netifd 自身卡死), 强制 ifdown/ifup"
    fi
    echo "  → 修复: 重新拉起 L2TP (ifdown/ifup) ..."
    ifdown "$IFNAME" >/dev/null 2>&1; sleep 2
    ifup "$IFNAME" >/dev/null 2>&1
    local t=0
    while [ $t -lt 60 ]; do
        ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true' && break
        sleep 5; t=$((t + 5))
    done
    if ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
        IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
        FIXED=$((FIXED+1)); echo "  [fixed] L2TP UP, IP: $IP"
        fix_default_route >/dev/null 2>&1
        fix_subnet_route >/dev/null 2>&1
        return 0
    fi
    return 1
}

fix_ping_target() {
    echo "  → 修复: ping $DST_TARGET ..."
    ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true' || fix_l2tp_up >/dev/null 2>&1
    ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV" || fix_subnet_route >/dev/null 2>&1
    [ $USE_IPSEC -eq 1 ] && { ipsec status 2>/dev/null | grep -q ESTABLISHED || fix_ipsec >/dev/null 2>&1; }
    if ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1; then
        FIXED=$((FIXED+1)); echo "  [fixed] ping $DST_TARGET 通"; return 0
    fi
    echo "  [note] ping 不通 (可能对端禁 ICMP)"
    return 1
}

fix_curl_target() {
    echo "  → 修复: curl $DST_TARGET ..."
    ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true' || fix_l2tp_up >/dev/null 2>&1
    [ $USE_IPSEC -eq 1 ] && { ipsec status 2>/dev/null | grep -q ESTABLISHED || fix_ipsec >/dev/null 2>&1; }
    ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV" || fix_subnet_route >/dev/null 2>&1
    CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
    [ "$CODE" = "000" ] && CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://$DST_TARGET/" 2>/dev/null)
    if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then
        FIXED=$((FIXED+1)); echo "  [fixed] curl HTTP $CODE"; return 0
    fi
    return 1
}

fix_internet() {
    echo "  → 修复: 外网 ..."
    fix_default_route >/dev/null 2>&1
    if ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1; then
        FIXED=$((FIXED+1)); echo "  [fixed] 外网已恢复"; return 0
    fi
    return 1
}

# ============================================================
# 检测 + 修复 (顺序: 先拉起接口, 再补路由, 再查 IPsec)
# ============================================================
echo "=============================================="
echo " L2TP/IPsec VPN 状态检测"
echo "  if=$IFNAME  dev=$NET_DEV  target=$DST_TARGET"
echo "=============================================="

# [1] 默认路由在 WAN
echo "[1] 默认路由"
ip route show default 2>/dev/null | grep -v "dev $NET_DEV" | grep -q "default"
check $? "默认路由在 WAN: $(ip route show default)"
if ! ip route show default 2>/dev/null | grep -v "dev $NET_DEV" | grep -q "default"; then
    if fix_default_route; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [WARN] 默认路由修复失败"; fi
fi

# [2] L2TP 接口 UP (先拉起接口, 后续路由/IPsec 检查才有意义)
echo "[2] L2TP 接口"
IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'
check $? "L2TP UP, IP: ${IP:-无}"
if ! ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
    if fix_l2tp_up; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [WARN] L2TP 接口修复失败, 看门狗下轮重试"; fi
fi

# [3] 远端网段路由 (接口起来后设备存在, 路由可正常添加)
echo "[3] 远端网段 $DST_SUBNET 路由"
ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"
check $? "VPN 路由: $(ip route show "$DST_SUBNET" 2>/dev/null)"
if ! ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"; then
    if fix_subnet_route; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [WARN] 子网路由修复失败"; fi
fi

# [4] IPsec ESTABLISHED
if [ $USE_IPSEC -eq 1 ]; then
echo "[4] IPsec 隧道"
ipsec status 2>/dev/null | grep -q ESTABLISHED
check $? "IPsec: $(ipsec status 2>/dev/null | grep ESTABLISHED | head -1 | sed 's/^[[:space:]]*//')"
if ! ipsec status 2>/dev/null | grep -q ESTABLISHED; then
    if fix_ipsec; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [WARN] IPsec 修复失败, 看门狗下轮重试"; fi
fi
else
    echo "[4] IPsec: 未启用 (纯 L2TP 模式), 跳过"
fi

# [5] ESP 加密
if [ $USE_IPSEC -eq 1 ]; then
echo "[5] ESP 加密"
ESP=$(ip xfrm state 2>/dev/null | grep -c "proto esp")
[ "$ESP" -ge 1 ]
check $? "ESP SA 数: $ESP"
if [ "$ESP" -lt 1 ]; then
    if fix_ipsec; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [WARN] ESP 修复失败"; fi
fi
else
    echo "[5] ESP: 未启用 (纯 L2TP 模式), 跳过"
fi

# [6] ping 远端
echo "[6] ping $DST_TARGET"
ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1
check $? "ping $DST_TARGET"
if ! ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1; then
    if fix_ping_target; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [info] ping 不通 (可能对端禁 ICMP)"; fi
fi

# [7] curl 远端
echo "[7] curl $DST_TARGET"
CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
[ "$CODE" = "000" ] && CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://$DST_TARGET/" 2>/dev/null)
[ -n "$CODE" ] && [ "$CODE" != "000" ]
check $? "HTTP ${CODE:-000}"
if [ "${CODE:-000}" = "000" ]; then
    if fix_curl_target; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [WARN] curl 修复失败"; fi
fi

# [8] 外网
echo "[8] 外网"
ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1
check $? "外网 223.5.5.5"
if ! ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1; then
    if fix_internet; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [WARN] 外网修复失败"; fi
fi

echo "=============================================="
echo " 结果: $PASS 通过, $FAIL 失败, $FIXED 已修复"
[ "$FAIL" -eq 0 ] && echo " 状态: 健康" || echo " 状态: 异常 (仍有 $FAIL 项失败, 看门狗将继续重试)"
echo "=============================================="

exit $FAIL
