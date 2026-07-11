#!/bin/bash
# DIY Part 1: X1 Pro device setup
# 原则：最小化侵入，只 patch 不改写上游文件
# 幂等设计：重复运行不会重复追加条目
# 参考 TR3000：第三方包直接 clone 到 package/，不用 feeds
set -euo pipefail

WORKSPACE="$GITHUB_WORKSPACE"
OPENWRT="$WORKSPACE/openwrt"

echo "=== DIY Part 1: X1 Pro setup ==="

# 1. Clone third-party packages into package/ (参照 TR3000)
#    直接 clone 避免 feeds 分支/index 问题
mkdir -p "$OPENWRT/package"

git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora "$OPENWRT/package/luci-theme-aurora"
git clone --depth=1 https://github.com/eamonxg/luci-app-aurora-config "$OPENWRT/package/luci-app-aurora-config"
git clone --depth=1 https://github.com/timsaya/luci-app-bandix "$OPENWRT/package/luci-app-bandix"
git clone --depth=1 https://github.com/timsaya/openwrt-bandix "$OPENWRT/package/openwrt-bandix"
echo "  → Third-party packages cloned"

# 2. Copy DTS files
DTS_DIR="$OPENWRT/target/linux/mediatek/files/arch/arm64/boot/dts/mediatek/"
mkdir -p "$DTS_DIR"

for f in mt7981b-oray-x1pro-v1.dtsi mt7981b-oray-x1pro-v1.dts mt7981b-oray-x1pro-v1-ubootmod.dts; do
  if [ -f "$WORKSPACE/$f" ]; then
    cp "$WORKSPACE/$f" "$DTS_DIR"
    echo "  → $f"
  fi
done

# 3. Patch filogic.mk
if [ -f "$WORKSPACE/filogic.mk" ]; then
  cp "$WORKSPACE/filogic.mk" "$OPENWRT/target/linux/mediatek/filogic.mk"
  echo "  → filogic.mk patched"
fi

# 4. Patch upstream 02_network — X1 Pro 接口定义（幂等）
#    X1 Pro: eth1=LAN, eth0=WAN（与 TR3000 相同）
NETWORK_FILE="$OPENWRT/target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
if [ -f "$NETWORK_FILE" ]; then
  if ! grep -q "oray,x1pro-v1|\\\\" "$NETWORK_FILE"; then
    python3 -c '
import sys
f = sys.argv[1]
with open(f) as fh:
    content = fh.read()
old = "\tcudy,tr3000-v1-ubootmod|\\\n"
new = old + "\toray,x1pro-v1|\\\n\toray,x1pro-v1-ubootmod|\\\n"
content = content.replace(old, new, 1)
with open(f, "w") as fh:
    fh.write(content)
' "$NETWORK_FILE"
    echo "  → 02_network patched (X1 Pro interfaces added)"
  else
    echo "  → 02_network already has X1 Pro entries (skipping)"
  fi
else
  echo "  ⚠ 02_network not found at $NETWORK_FILE"
fi

# 5. Patch platform.sh — sysupgrade 支持（幂等）
PLATFORM_FILE="$OPENWRT/target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
if [ -f "$PLATFORM_FILE" ]; then
  if ! grep -q "oray,x1pro-v1-ubootmod|\\\\" "$PLATFORM_FILE"; then
    python3 -c '
import sys
f = sys.argv[1]
with open(f) as fh:
    content = fh.read()
old = "\tcudy,wbr3000uax-v1-ubootmod|\\\n"
new = old + "\toray,x1pro-v1-ubootmod|\\\n"
content = content.replace(old, new, 1)
with open(f, "w") as fh:
    fh.write(content)
' "$PLATFORM_FILE"
    echo "  → platform.sh patched"
  else
    echo "  → platform.sh already has X1 Pro entry (skipping)"
  fi
fi

echo "=== DIY Part 1 done ==="
