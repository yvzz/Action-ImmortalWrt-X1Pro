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
  echo "      → ${DTS_DIR}mt7981b-oray-x1pro-v1-ubootmod.dts"
fi

if [ -f "$WORKSPACE/mt7981b-oray-x1pro-v1.dtsi" ]; then
  echo "[1/5] Copying shared .dtsi..."
  cp "$WORKSPACE/mt7981b-oray-x1pro-v1.dtsi" "$DTS_DIR"
  echo "      → ${DTS_DIR}mt7981b-oray-x1pro-v1.dtsi"
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
  echo "      → ${FILOGIC_DST} (stock oray_x1pro-v1 removed)"
else
  echo "[2/5] WARNING: $FILOGIC_SRC not found"
fi

# ── 3. Install board.d scripts ──────────────────────────────────────────────
BOARD_D="$OPENWRT/target/linux/mediatek/base-files/board.d"
echo "[3/5] Installing board.d scripts..."
mkdir -p "$BOARD_D"

# 02_network — MT7981 DSA 网络初始化（非 swconfig）
cat > "$BOARD_D/02_network" << 'EOFBOARD'
#!/bin/sh
# 蒲公英 X1 Pro 网络初始化 (DSA)
# gmac0 = 2.5G SFP WAN, gmac1 = GE RJ45 LAN

board_config_update

ucidef_set_interface_loopback
ucidef_set_interfaces_lan_wan "eth1" "eth0"

exit 0
EOFBOARD
chmod +x "$BOARD_D/02_network"
echo "      → ${BOARD_D}/02_network"

# 11_fix_wifi_mac — 从 bdinfo 分区读取 base MAC 并设置 WiFi MAC
# MT7981 mtd 分区: mtd0=BL2 mtd1=env mtd2=Factory mtd3=FIP mtd4=bdinfo mtd5=kpanic mtd6=ubi
cat > "$BOARD_D/11_fix_wifi_mac" << 'EOFMAC'
#!/bin/sh
# 蒲公英 X1 Pro WiFi MAC 修复
# bdinfo 分区偏移 0xDE00 存储 base MAC (LAN MAC)
# WiFi MACs 由内核 mt7615/mt7916 驱动自动从 eth MAC 派生，
# 本脚本作为 fallback 在驱动未正确派生时兜底

. /lib/functions/uci-defaults.sh

board_config_update

# 从 bdinfo mtd 分区直接读取 base MAC (分区内偏移 0xDE00)
BASE_MAC=""
if [ -b /dev/mtdblock4 ]; then
  BASE_MAC=$(dd if=/dev/mtdblock4 bs=1 skip=56832 count=6 2>/dev/null | hexdump -v -e '1/1 "%02x:"' | sed 's/:$//')
fi

if [ -z "$BASE_MAC" ] || [ "${#BASE_MAC}" -ne 17 ]; then
  # Fallback: 从 DTS nvmem 已经分配好的 eth1 MAC 推导
  BASE_MAC=$(cat /sys/class/net/eth1/address 2>/dev/null)
fi

if [ -z "$BASE_MAC" ] || [ "${#BASE_MAC}" -ne 17 ]; then
  logger -t wifi_mac "Cannot determine base MAC, skipping"
  board_config_flush && exit 0
fi

# MAC 偏移推导: LAN=base, WAN=base+1, 2.4G=base+2, 5G=base+4
mac_inc() {
  local mac="$1" inc="$2"
  local last=$(echo "$mac" | awk -F: '{print $NF}')
  local next=$(printf '%02x' $(((0x$last + $inc) % 256)))
  echo "$mac" | sed "s/:[0-9a-fA-F]\{2\}$/:$next/"
}

WLAN0_MAC=$(mac_inc "$BASE_MAC" 2)
WLAN1_MAC=$(mac_inc "$BASE_MAC" 4)

for phy in /sys/class/ieee80211/phy*; do
  [ -d "$phy" ] || continue
  idx=$(basename "$phy" | sed 's/phy//')
  case "$idx" in
    0) target_mac="$WLAN0_MAC" ;;
    1) target_mac="$WLAN1_MAC" ;;
    *) continue ;;
  esac
  current=$(cat "$phy/macaddress" 2>/dev/null)
  if [ "$current" != "$target_mac" ]; then
    logger -t wifi_mac "Setting phy${idx} MAC: $current → $target_mac"
    # 写入 phy 的 MAC (mt76 驱动读取 macaddress 属性)
    echo "$target_mac" > "$phy/macaddress" 2>/dev/null || true
  fi
done

board_config_flush && exit 0
EOFMAC
chmod +x "$BOARD_D/11_fix_wifi_mac"
echo "      → ${BOARD_D}/11_fix_wifi_mac"

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
echo "      → ${BOARD_D}/03_gpio_switches"

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
