#!/bin/bash
# DIY Part 1: X1 Pro device setup
set -euo pipefail

WORKSPACE="$GITHUB_WORKSPACE"
OPENWRT="$WORKSPACE/openwrt"

echo "=== DIY Part 1: X1 Pro setup ==="

# 1. Copy DTS files
DTS_DIR="$OPENWRT/target/linux/mediatek/files/arch/arm64/boot/dts/mediatek/"
mkdir -p "$DTS_DIR"

for f in mt7981b-oray-x1pro-v1.dtsi mt7981b-oray-x1pro-v1.dts mt7981b-oray-x1pro-v1-ubootmod.dts; do
  if [ -f "$WORKSPACE/$f" ]; then
    cp "$WORKSPACE/$f" "$DTS_DIR"
    echo "  → $f"
  fi
done

# 2. Patch filogic.mk
if [ -f "$WORKSPACE/filogic.mk" ]; then
  cp "$WORKSPACE/filogic.mk" "$OPENWRT/target/linux/mediatek/filogic.mk"
  echo "  → filogic.mk patched"
fi

# 3. Install board.d network script (DSA)
BOARD_D="$OPENWRT/target/linux/mediatek/base-files/etc/board.d"
mkdir -p "$BOARD_D"

cat > "$BOARD_D/02_network" << 'EOF'
#!/bin/sh
# Oray X1 Pro network setup
. /lib/functions/uci-defaults.sh

board_config_update

ucidef_set_interface_loopback
ucidef_set_interfaces_lan_wan "eth1" "eth0"

board_config_flush
EOF
chmod +x "$BOARD_D/02_network"
echo "  → 02_network"

echo "=== DIY Part 1 done ==="
