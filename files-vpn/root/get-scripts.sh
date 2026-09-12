#!/bin/sh
# ============================================================
# X1Pro VPN 脚本下载器
# 无参数: 下载 down-scripts.sh 引导脚本 (推荐)
# 带 *.sh 参数: 仅下载该文件到 /root/
# 用法:  sh /root/get-scripts.sh [xxx.sh]
# 仓库:  https://gitee.com/vvvv/wrt-x1-pro
# ============================================================

REPO="https://gitee.com/vvvv/wrt-x1-pro/raw/master"
DEST_DIR="/root"

# 参数处理: 带 *.sh 参数 → 仅下载该文件; 否则 → 下载引导脚本
if [ -n "$1" ] && echo "$1" | grep -q '\.sh$'; then
  FILES="$1"
  MODE="single"
else
  FILES="down-scripts.sh"
  MODE="bootstrap"
fi

log(){ echo "  $*"; }

fetch_one(){
  local name="$1"
  local url="$REPO/$name"
  local dest="$DEST_DIR/$name"
  local tmp="$dest.tmp"
  log "下载 $name ..."
  local i
  for i in 1 2 3; do
    if curl -fsSL --connect-timeout 15 -m 60 -o "$tmp" "$url" 2>/dev/null; then
      # 校验: 非空 + 首行是 shebang (有效 shell 脚本)
      if [ -s "$tmp" ] && head -1 "$tmp" 2>/dev/null | grep -q '^#!'; then
        mv "$tmp" "$dest"
        chmod +x "$dest"
        log "[ok] $name -> $dest ($(wc -c < "$dest") 字节)"
        return 0
      fi
    fi
    log "  [!] 第 $i 次下载失败/校验失败, 重试..."
    sleep 2
  done
  rm -f "$tmp"
  return 1
}

echo "=============================================="
echo " X1Pro 引导脚本下载"
echo "=============================================="

# 网络连通性预检
if ! curl -fsSL --connect-timeout 10 -m 15 -o /dev/null "https://gitee.com" 2>/dev/null; then
  echo "[ERROR] 无法连接 gitee.com, 请检查外网连通性"
  exit 1
fi

fail=0
for f in $FILES; do
  fetch_one "$f" || fail=$((fail + 1))
done

echo "=============================================="
if [ "$fail" -eq 0 ]; then
  if [ "$MODE" = "single" ]; then
    echo " 已下载: $DEST_DIR/$FILES"
  else
    echo " 引导脚本已下载: $DEST_DIR/down-scripts.sh"
    echo ""
    echo " 请执行以下命令获取操作脚本:"
    echo "   sh $DEST_DIR/down-scripts.sh 或 sh down-scripts.sh"
    echo ""
  fi
else
  echo " 下载失败, 请检查网络后重试: sh $DEST_DIR/get-scripts.sh"
fi
echo "=============================================="

exit "$fail"
