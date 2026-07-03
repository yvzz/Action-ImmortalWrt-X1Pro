#!/bin/bash
#
# Combined DIY Part 1 Script
# Handles: custom packages + theme cloning + X1Pro device setup
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

# X1 Pro device support (only if DTS file exists in workspace)
if [ -f "$WORKSPACE/mt7981-oraybox_x1-pro.dts" ]; then
  echo "=== Adding Oray X1 Pro support ==="
  
  # Copy DTS file to files directory (will be copied to kernel source tree during build)
  mkdir -p target/linux/mediatek/files/arch/arm64/boot/dts/mediatek
  cp "$WORKSPACE/mt7981-oraybox_x1-pro.dts" target/linux/mediatek/files/arch/arm64/boot/dts/mediatek/mt7981_oray_x1_pro.dts

  # Add device definition to filogic.mk
  cat >> target/linux/mediatek/image/filogic.mk << 'EOF'

define Device/oray_x1_pro
  DEVICE_VENDOR := Oray
  DEVICE_MODEL := X1 Pro
  DEVICE_DTS := mt7981_oray_x1_pro
  DEVICE_PACKAGES := kmod-usb3 kmod-usb-net-rndis kmod-usb-net-cdc-ether
endef
TARGET_DEVICES += oray_x1_pro
EOF

  # Add board.d scripts for network and LED
  mkdir -p package/base-files/files/etc/board.d

  cat > package/base-files/files/etc/board.d/02_network << 'EOF'
#!/bin/sh
. /lib/functions/uci-defaults.sh
board_config_update
case "$(board_name)" in
oray,x1_pro)
	ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4" "wan"
	;;
esac
board_config_flush
exit 0
EOF
  chmod +x package/base-files/files/etc/board.d/02_network

  cat > package/base-files/files/etc/board.d/01_leds << 'EOF'
#!/bin/sh
. /lib/functions/uci-defaults.sh
board_config_update
case "$(board_name)" in
oray,x1_pro)
	ucidef_set_led_netdev "wan" "WAN" "blue:wan" "wan"
	;;
esac
board_config_flush
exit 0
EOF
  chmod +x package/base-files/files/etc/board.d/01_leds

  echo "=== X1 Pro support added ==="
fi
