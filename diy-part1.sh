#!/bin/bash
#
# Combined DIY Part 1 Script
# Handles: custom packages + theme cloning + X1Pro ubootmod device setup
# Uses TR3000's proven hardware DTS (.dtsi) with X1 Pro model + 112M UBI
#
set -x
WORKSPACE="$GITHUB_WORKSPACE"

# Copy custom local packages into OpenWrt tree
if [ -d "$GITHUB_WORKSPACE/package/luci-compat-keep" ]; then
  mkdir -p package
  cp -r "$GITHUB_WORKSPACE/package/luci-compat-keep" package/
fi

# Clone theme packages (idempotent - only clone if not present)
[ -d "package/luci-theme-aurora" ] || git clone https://github.com/eamonxg/luci-theme-aurora package/luci-theme-aurora
[ -d "package/luci-app-aurora-config" ] || git clone https://github.com/eamonxg/luci-app-aurora-config package/luci-app-aurora-config
[ -d "package/luci-app-bandix" ] || git clone https://github.com/timsaya/luci-app-bandix package/luci-app-bandix
[ -d "package/openwrt-bandix" ] || git clone https://github.com/timsaya/openwrt-bandix package/openwrt-bandix

# ==============================================================================
# X1 Pro ubootmod device support (128M NAND only)
#
# Strategy: use TR3000's hardware .dtsi (same GPIO, keys, LEDs, eth, USB, WiFi)
# Only override: model name, compatible string, and UBI partition size.
# This eliminates the 5G WiFi reset bug from the previous custom DTS approach
# by inheriting TR3000's proven spi-cal, NMBM, and eeprom configuration.
# ==============================================================================
if [ -f "$WORKSPACE/mt7981b-oray-x1-pro.dts" ]; then
  echo "=== Adding Oray X1 Pro ubootmod support ==="

  # ---------- 1. DTS ----------
  mkdir -p target/linux/mediatek/files/arch/arm64/boot/dts/mediatek
  cp "$WORKSPACE/mt7981b-oray-x1-pro.dts" \
     target/linux/mediatek/files/arch/arm64/boot/dts/mediatek/

  # ---------- 2. Device definition in filogic.mk ----------
  cat >> target/linux/mediatek/image/filogic.mk << 'EOF'

define Device/oray_x1_pro
  DEVICE_VENDOR := Oray
  DEVICE_MODEL := X1 Pro
  DEVICE_DTS := mt7981b-oray-x1-pro
  SUPPORTED_DEVICES += cudy,tr3000-v1-ubootmod
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 114688k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware automount
endef
TARGET_DEVICES += oray_x1_pro
EOF

  # ---------- 3. Patch upstream scripts to add X1 Pro ----------
  python3 << 'PYEOF'
"""Add oray,x1_pro entries to upstream board/hotplug/preinit scripts."""
import re

patches = [
    # 02_network: add MAC setup for X1 Pro (from bdinfo@0xde00, same as TR3000)
    (
        "target/linux/mediatek/filogic/base-files/etc/board.d/02_network",
        r'^(\tcudy,tr3000-v1\))$',
        lambda m: (
            '\toray,x1_pro)\n'
            '\t\twan_mac=$(mtd_get_mac_binary bdinfo 0xde00)\n'
            '\t\tlan_mac=$(macaddr_add "$wan_mac" 1)\n'
            '\t\t;;\n'
            '\n' + m.group(1)
        ),
    ),
    # 11_fix_wifi_mac: add oray,x1_pro to the same handler group as Cudy TR3000
    (
        "target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac",
        r'^(\tcudy,m3000-v1\|\\)$',
        lambda m: '\toray,x1_pro|\\\n' + m.group(1),
    ),
    # 03_gpio_switches: no tabs in this file, match without leading \t
    (
        "target/linux/mediatek/filogic/base-files/etc/board.d/03_gpio_switches",
        r'^(cudy,tr3000-256mb-v1\|\\)$',
        lambda m: 'oray,x1_pro|\\\n' + m.group(1),
    ),
    # preinit: set preinit interface for X1 Pro
    (
        "target/linux/mediatek/base-files/lib/preinit/05_set_preinit_iface",
        r'^(\tcudy,m3000-v1\|\\)$',
        lambda m: '\toray,x1_pro|\\\n' + m.group(1),
    ),
]

for filepath, pattern, replacer in patches:
    with open(filepath) as f:
        content = f.read()
    new_content = re.sub(pattern, replacer, content, count=1, flags=re.MULTILINE)
    if new_content == content:
        print("  Warning: NO MATCH in: " + filepath)
    else:
        with open(filepath, 'w') as f:
            f.write(new_content)
        print("  Patched: " + filepath)

PYEOF

  echo "=== X1 Pro ubootmod support added ==="
fi
