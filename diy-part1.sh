#!/bin/bash
#
# Combined DIY Part 1 Script
# Handles:
#   1. Copy X1 Pro DTS into kernel DTS tree
#   2. Patch filogic.mk with oray_x1pro-v1 device
#   3. Install board.d scripts (02_network, 11_fix_wifi_mac)
#   4. Custom local packages + theme cloning
#
set -euo pipefail
WORKSPACE="$GITHUB_WORKSPACE"
OPENWRT="$WORKSPACE/openwrt"

echo "=== DIY Part 1: Device setup ==="

# ── 1. Copy X1 Pro ubootmod DTS into kernel source tree ──────────────────
DTS_DIR="$OPENWRT/target/linux/mediatek/files/arch/arm64/boot/dts/mediatek/"
mkdir -p "$DTS_DIR"

if [ -f "$WORKSPACE/mt7981b-oray-x1pro-v1-ubootmod.dts" ]; then
  echo "[1/5] Copying ubootmod DTS..."
  cp "$WORKSPACE/mt7981b-oray-x1pro-v1-ubootmod.dts" "$DTS_DIR"
  echo "      → $DTS_DIRmt7981b-oray-x1pro-v1-ubootmod.dts"
fi

if [ -f "$WORKSPACE/mt7981b-oray-x1pro-v1.dtsi" ]; then
  echo "[1/5] Copying shared .dtsi..."
  cp "$WORKSPACE/mt7981b-oray-x1pro-v1.dtsi" "$DTS_DIR"
  echo "      → $DTS_DIRmt7981b-oray-x1pro-v1.dtsi"
fi

# ── 2. Patch filogic.mk: 去掉 stock oray_x1pro-v1，只保留 ubootmod ────────
FILOGIC_SRC="$WORKSPACE/filogic.mk"
FILOGIC_DST="$OPENWRT/target/linux/mediatek/filogic.mk"

if [ -f "$FILOGIC_SRC" ]; then
  echo "[2/5] Patching filogic.mk (remove stock oray_x1pro-v1, keep ubootmod only)..."
  cp "$FILOGIC_SRC" "$FILOGIC_DST"
  # 用 awk 彻底删除 stock oray_x1pro-v1 Device 块 + TARGET_DEVICES 行
  awk '
    BEGIN { skip = 0 }
    /^define Device\/oray_x1pro-v1$/ && !/ubootmod/ { skip = 1 }
    skip && /^endef$/ { skip = 0; next }
    skip && /^TARGET_DEVICES += oray_x1pro-v1$/ { next }
    skip { next }
    { print }
  ' "$FILOGIC_DST" > "${FILOGIC_DST}.tmp" && mv "${FILOGIC_DST}.tmp" "$FILOGIC_DST"
  echo "      → $FILOGIC_DST (stock oray_x1pro-v1 removed)"
else
  echo "[2/5] WARNING: $FILOGIC_SRC not found"
fi

# ── 3. Install board.d scripts ──────────────────────────────────────────────
BOARD_D="$OPENWRT/target/linux/mediatek/base-files/board.d"
echo "[3/5] Installing board.d scripts..."
mkdir -p "$BOARD_D"

# 02_network — 修复 LAN/WAN 端口顺序
cat > "$BOARD_D/02_network" << 'EOFBOARD'
#!/bin/sh
# 蒲公英 X1 Pro 网络初始化
# WAN = Port 0 (2.5G SFP), LAN = Port 1 (GE)

[ -e /etc/config/network ] && exit 0

ucidef_set_interface_loopback

# Port 0 = WAN (2.5G BASE-X SFP)
ucidef_set_interface_wan "eth0"
# Port 1 = LAN (GE RJ45)
ucidef_add_switch "switch0" "1" "eth1"
ucidef_add_switch_vlan "switch0" "1" "1 2 3 4 5*"
ucidef_add_switch_vlan "switch0" "2" "0 6"

uci set network.lan.device="switch0"
uci commit network

exit 0
EOFBOARD
chmod +x "$BOARD_D/02_network"
echo "      → $BOARD_D/02_network"

# 11_fix_wifi_mac — 读取 bdinfo 分区 MAC 地址并写入网络接口
cat > "$BOARD_D/11_fix_wifi_mac" << 'EOFMAC'
#!/bin/sh
# 蒲公英 X1 Pro MAC 地址修复
# 从 bdinfo (mtd5, 0x580000) 读取 MAC，写入 wlan0 / wlan1

WIFI_MAC_FILE="/tmp/wifi_mac_applied"
[ -f "$WIFI_MAC_FILE" ] && exit 0

# bdinfo 分区偏移: 0x580000, MAC 存储在偏移 0xDE00 (bdinfo 内)
# 通过读取整个 bdinfo 分区，再用 hexdump 提取对应字节
BDINFO_DEV="/dev/mtdblock5"   # kpanic=4, bdinfo=5

apply_mac() {
  local iface="$1"
  local mac="$2"
  [ -z "$mac" ] && return 1
  ip link set dev "$iface" address "$mac" 2>/dev/null && \
    logger -t fix_wifi_mac "Set $iface MAC → $mac" && return 0
  return 1
}

# 读取 MAC (bdinfo 内偏移 0xDE00, 6 字节)
if [ -b "$BDINFO_DEV" ]; then
  # dd 跳过 0x580000 + 0xDE00 = 0x65E00 bytes, 读取 6 字节
  WIFI_MAC=$(dd if="$BDINFO_DEV" bs=1 skip=$((0x580000 + 0xDE00)) count=6 2>/dev/null | hexdump -v -e '1/1 "%02x:"' | sed 's/:$//')
  # 格式: aa:bb:cc:dd:ee:ff
  if [ -n "$WIFI_MAC" ] && [ "${#WIFI_MAC}" -eq 17 ]; then
    # 从 bdinfo 读的是 WAN MAC (偏移 0xDE00), WiFi MAC = WAN+1
    WAN_MAC="$WIFI_MAC"
    # 计算 LAN MAC (WAN MAC 最后一个字节 +1)
    LAST=$(echo "$WAN_MAC" | awk -F: '{print $NF}')
    NEXT=$(printf '%02x' $(((16#$LAST + 1) & 0xFF)))
    LAN_MAC=$(echo "$WAN_MAC" | sed "s/:[0-9a-fA-F]\{2\}$/:$NEXT/")
    # WiFi MAC = LAN MAC + 1
    W1_LAST=$(printf '%02x' $(((16#$NEXT + 1) & 0xFF)))
    WIFI0_MAC=$(echo "$LAN_MAC" | sed "s/:[0-9a-fA-F]\{2\}$/:$W1_LAST/")
    W2_LAST=$(printf '%02x' $(((16#$W1_LAST + 1) & 0xFF)))
    WIFI1_MAC=$(echo "$WIFI0_MAC" | sed "s/:[0-9a-fA-F]\{2\}$/:$W2_LAST/")
    
    # 2.4G = wifi0, 5G = wifi1
    apply_mac "wlan0" "$WIFI0_MAC"
    apply_mac "wlan1" "$WIFI1_MAC"
    apply_mac "wlan2" "" # 没有第三个 radio
    
    touch "$WIFI_MAC_FILE"
  fi
fi

exit 0
EOFMAC
chmod +x "$BOARD_D/11_fix_wifi_mac"
echo "      → $BOARD_D/11_fix_wifi_mac"

# ── 4. 03_gpio_switches (GPIO 按键注册) ────────────────────────────────────
cat > "$BOARD_D/03_gpio_switches" << 'EOFGPIO'
#!/bin/sh
# 蒲公英 X1 Pro GPIO 按键注册
[ -e /etc/config/system ] && exit 0

uci set system.@system[0].hostname='Oray-X1Pro'
uci add system button
uci set system.@button[-1].button='reset'
uci set system.@button[-1].action='released'
uci set system.@button[-1].handler='reboot'
uci set system.@button[-1].min='5'
uci set system.@button[-1].max='30'

uci add system led
uci set system.@led[-1].name='sys'
uci set system.@led[-1].sysfs='white:status'
uci set system.@led[-1].trigger='heartbeat'
uci set system.@led[-1].default='1'

uci commit system
exit 0
EOFGPIO
chmod +x "$BOARD_D/03_gpio_switches"
echo "      → $BOARD_D/03_gpio_switches"

# ── 5. 自定义本地 packages ─────────────────────────────────────────────────
echo "[4/5] Installing custom packages..."
if [ -d "$WORKSPACE/package/luci-compat-keep" ]; then
  mkdir -p "$OPENWRT/package"
  cp -r "$WORKSPACE/package/luci-compat-keep" "$OPENWRT/package/"
  echo "      → package/luci-compat-keep"
fi

# ── 6. Clone theme packages (idempotent) ────────────────────────────────────
echo "[5/5] Cloning theme packages..."
[ -d "$OPENWRT/package/luci-theme-aurora" ] || \
  git clone https://github.com/eamonxg/luci-theme-aurora "$OPENWRT/package/luci-theme-aurora"
[ -d "$OPENWRT/package/luci-app-aurora-config" ] || \
  git clone https://github.com/eamonxg/luci-app-aurora-config "$OPENWRT/package/luci-app-aurora-config"
[ -d "$OPENWRT/package/luci-app-bandix" ] || \
  git clone https://github.com/timsaya/luci-app-bandix "$OPENWRT/package/luci-app-bandix"
[ -d "$OPENWRT/package/openwrt-bandix" ] || \
  git clone https://github.com/timsaya/openwrt-bandix "$OPENWRT/package/openwrt-bandix"

echo "=== DIY Part 1 done ==="
