#!/bin/bash
# DIY Part 1: X1 Pro device setup
# 原则：最小化侵入，只 patch 不改写上游文件
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

# 3. Patch upstream 02_network — Python3 跨平台精确插入
NETWORK_FILE="$OPENWRT/target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
if [ -f "$NETWORK_FILE" ]; then
  python3 -c '
import sys
f = sys.argv[1]
with open(f) as fh:
    lines = fh.readlines()

out = []
for line in lines:
    out.append(line)
    # interface: 在 cudy,tr3000-v1-ubootmod|\ 后插入 oray
    if line.rstrip() == "\tcudy,tr3000-v1-ubootmod|\\":
        out.append("\toray,x1pro-v1|\\\n")
        out.append("\toray,x1pro-v1-ubootmod|\\\n")
    # MAC: 在 cudy,tr3000-v1) 后插入 X1 Pro (单 tab 缩进，与上游一致)
    if line.rstrip() == "\tcudy,tr3000-v1)":
        out.append("\toray,x1pro-v1|\\\n")
        out.append("\toray,x1pro-v1-ubootmod)\n")
        out.append("\t\twan_mac=$(mtd_get_mac_binary bdinfo 0xde00)\n")
        out.append("\t\tlan_mac=$(macaddr_add \"$wan_mac\" 1)\n")
        out.append("\t\t;;\n")

with open(f, "w") as fh:
    fh.writelines(out)
' "$NETWORK_FILE"
  echo "  → 02_network patched (X1 Pro interfaces + MAC)"
else
  echo "  ⚠ 02_network not found at $NETWORK_FILE"
fi

# 4. Patch upstream platform.sh — 添加 sysupgrade 支持
PLATFORM_FILE="$OPENWRT/target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
if [ -f "$PLATFORM_FILE" ]; then
  python3 -c '
import sys
f = sys.argv[1]
with open(f) as fh:
    content = fh.read()

# 在 fit_do_upgrade 列表中 cudy,wbr3000uax-v1-ubootmod|\ 后插入 oray,x1pro-v1-ubootmod|\
old = "\tcudy,wbr3000uax-v1-ubootmod|\\\n"
new = "\tcudy,wbr3000uax-v1-ubootmod|\\\n\toray,x1pro-v1-ubootmod|\\\n"
if old in content:
    content = content.replace(old, new, 1)
    with open(f, "w") as fh:
        fh.write(content)
    print("  → platform.sh patched (oray,x1pro-v1-ubootmod added to fit_do_upgrade)")
else:
    print("  ⚠ platform.sh: pattern not found, may already be patched")
' "$PLATFORM_FILE"
else
  echo "  ⚠ platform.sh not found at $PLATFORM_FILE"
fi

echo "=== DIY Part 1 done ==="
