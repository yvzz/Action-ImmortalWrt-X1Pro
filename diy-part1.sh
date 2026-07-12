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
git clone --depth=1 https://github.com/timsaya/luci-app-bandix  "$OPENWRT/package/luci-app-bandix"
git clone --depth=1 https://github.com/timsaya/openwrt-bandix  "$OPENWRT/package/openwrt-bandix"
echo "  → aurora packages cloned"

# 1b. Fix bandix Makefile: zoneinfo-all 不存在于 feeds/packages，替换为实际存在的包
BANDIX_MK="$OPENWRT/package/openwrt-bandix/openwrt-bandix/Makefile"
if [ -f "$BANDIX_MK" ]; then
  if grep -q 'zoneinfo-all' "$BANDIX_MK"; then
    echo "  → bandix Makefile: zoneinfo-all kept (local metapackage will provide it)"
  fi
fi

# 1c. 创建 zoneinfo-all 本地 metapackage（bandix 依赖它）
mkdir -p "$OPENWRT/package/zoneinfo-all"
cat > "$OPENWRT/package/zoneinfo-all/Makefile" << 'MAKEFILE_EOF'
include $(TOPDIR)/rules.mk

PKG_NAME:=zoneinfo-all
PKG_VERSION:=1
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/zoneinfo-all
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=All timezones (metapackage)
  DEPENDS:= \
	+zoneinfo-core \
	+zoneinfo-simple \
	+zoneinfo-africa \
	+zoneinfo-america \
	+zoneinfo-poles \
	+zoneinfo-asia \
	+zoneinfo-atlantic \
	+zoneinfo-australia-nz \
	+zoneinfo-pacific \
	+zoneinfo-europe \
	+zoneinfo-indian
  PKGARCH:=all
endef

define Package/zoneinfo-all/description
  Meta-package that depends on all available zoneinfo sets
endef

define Build/Configure
endef
define Build/Compile
endef

define Package/zoneinfo-all/install
	$(INSTALL_DIR) $(1)
endef

$(eval $(call BuildPackage,zoneinfo-all))
MAKEFILE_EOF
echo "  → zoneinfo-all metapackage created"

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

# 6. Patch 02_network — MAC 设置修复（幂等）
#    内核 DSA 驱动通过 nvmem 读取 eth0/eth1 MAC 失败（返回全 FF），
#    导致 eth0/eth1 显示全 FF。直接读 bdinfo 覆盖（wan_mac/lan_mac 是 local 变量不可见）。
#    使用独立 Python 脚本文件代替 heredoc 内联，避免 tab/backslash 转义歧义。
if [ -f "$NETWORK_FILE" ]; then
  if ! grep -q "X1 Pro MAC fix" "$NETWORK_FILE"; then
    python3 "$WORKSPACE/_x1pro_macfix.py" "$NETWORK_FILE"
    echo "  → 02_network MAC fix patched"
  else
    echo "  → 02_network MAC fix already present (skipping)"
  fi
fi

echo "=== DIY Part 1 done ==="
