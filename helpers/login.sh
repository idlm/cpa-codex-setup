#!/usr/bin/env bash
# CLIProxyAPI 凭据登录助手
# 注意: 必须在带 TTY 的真实终端中运行。CPA 在非 TTY 环境下不会打印授权 URL
#       与设备码 (后台重定向 / 管道 / screen -dm 都拿不到输出)。
set -euo pipefail

BIN="@CPA_BIN@"
CFG="@CPA_CFG@"
AUTH_DIR="@AUTH_DIR@"

usage() {
  cat <<EOF
用法: $(basename "$0") [provider]

  codex-device  ChatGPT/Codex 设备码登录 (默认, 无需 SSH 隧道, 推荐)
  codex         ChatGPT/Codex OAuth 回调登录 (需 ssh -L 1455:127.0.0.1:1455)
  claude        Claude OAuth 登录
  gemini        Antigravity (Gemini) OAuth 登录
  kimi          Kimi OAuth 登录
  xai           xAI OAuth 登录

凭据写入 $AUTH_DIR/*.json, 服务自动热加载, 无需重启。
可重复登录多个账号, CPA 会按 strategy 轮询。
EOF
}

case "${1:-codex-device}" in
  codex-device)   FLAG="-codex-device-login" ;;
  codex)          FLAG="-codex-login" ;;
  claude)         FLAG="-claude-login" ;;
  gemini)         FLAG="-antigravity-login" ;;
  kimi)           FLAG="-kimi-login" ;;
  xai)            FLAG="-xai-login" ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "未知 provider: $1" >&2; echo; usage; exit 1 ;;
esac

echo "启动登录流程: $FLAG"
exec "$BIN" --config "$CFG" "$FLAG" -no-browser
