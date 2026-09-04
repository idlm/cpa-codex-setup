#!/usr/bin/env bash
# ==============================================================================
#  CLIProxyAPI (CPA) 卸载脚本
#
#  默认行为: 停止并移除 systemd 服务 + 删除安装目录, 但【保留】凭据目录,
#            这样重装后已登录的账号无需重新授权。
#
#  用法:
#    sudo ./uninstall.sh            # 保留凭据与密钥
#    sudo ./uninstall.sh --purge    # 同时删除凭据目录 (不可恢复)
#    sudo ./uninstall.sh -y         # 跳过确认
# ==============================================================================
set -euo pipefail

CPA_DIR="${CPA_DIR:-/opt/cliproxyapi}"
TARGET_HOME="${TARGET_HOME:-/root}"
AUTH_DIR_SET=0
[ -n "${AUTH_DIR:-}" ] && AUTH_DIR_SET=1
AUTH_DIR="${AUTH_DIR:-$TARGET_HOME/.cli-proxy-api}"
SERVICE_NAME="${SERVICE_NAME:-cliproxyapi}"
PURGE=0; ASSUME_YES=0

usage() {
  cat <<'EOF'
CLIProxyAPI (CPA) 卸载

用法: sudo ./uninstall.sh [选项]

  --purge          同时删除凭据目录 (不可恢复)
  -y, --yes        跳过确认
  --dir PATH       安装目录 (默认 /opt/cliproxyapi)
  --home PATH      服务用户家目录 (默认 /root)
  --auth-dir PATH  配置与凭据目录
  --service NAME   systemd 单元名 (默认 cliproxyapi)
  -h, --help       显示本帮助

装的时候用了 --dir/--home/--service, 卸载时要传一样的值。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)    PURGE=1; shift ;;
    -y|--yes)   ASSUME_YES=1; shift ;;
    --dir)      CPA_DIR="$2"; shift 2 ;;
    --home)     TARGET_HOME="$2"; shift 2 ;;
    --auth-dir) AUTH_DIR="$2"; AUTH_DIR_SET=1; shift 2 ;;
    --service)  SERVICE_NAME="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; echo; usage; exit 1 ;;
  esac
done
[ "$AUTH_DIR_SET" = "1" ] || AUTH_DIR="$TARGET_HOME/.cli-proxy-api"

[ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; exit 1; }

echo "将执行以下操作:"
echo "  - 停止并禁用服务 $SERVICE_NAME, 删除 /etc/systemd/system/$SERVICE_NAME.service"
echo "  - 删除目录 $CPA_DIR"
if [ "$PURGE" = "1" ]; then
  echo "  - 删除凭据目录 $AUTH_DIR (含所有已登录账号与密钥, 不可恢复)"
else
  echo "  - 保留凭据目录 $AUTH_DIR"
fi
echo "  - 不会改动 ~/.codex/config.toml, 也不会卸载 Codex CLI / bubblewrap"
echo

if [ "$ASSUME_YES" != "1" ]; then
  read -rp "确认继续? [y/N] " ans
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "已取消"; exit 0 ;; esac
fi

if systemctl list-unit-files 2>/dev/null | grep -q "^$SERVICE_NAME.service"; then
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$SERVICE_NAME.service"
  systemctl daemon-reload
  echo "[✓] 服务已移除"
fi

rm -rf "$CPA_DIR"
echo "[✓] 已删除 $CPA_DIR"

if [ "$PURGE" = "1" ]; then
  rm -rf "$AUTH_DIR"
  echo "[✓] 已删除凭据目录 $AUTH_DIR"
else
  echo "[i] 凭据保留在 $AUTH_DIR"
fi

echo
echo "卸载完成。若要同时清理 Codex 侧配置:"
echo "  ls $TARGET_HOME/.codex/config.toml.bak.*   # 找回安装前的备份"
echo "  npm uninstall -g @openai/codex             # 卸载 Codex CLI"
