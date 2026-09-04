#!/usr/bin/env bash
# ==============================================================================
#  CLIProxyAPI (CPA) + Codex CLI 一键部署脚本
#  适用: Debian / Ubuntu 等 systemd 发行版, x86_64 或 aarch64, 需 root
#
#  完成的工作:
#    1. 下载并 sha256 校验 CLIProxyAPI 官方二进制, 安装到 $CPA_DIR
#    2. 生成随机 API key / 管理 key, 写最小化 config.yaml (默认仅绑回环地址)
#    3. 注册 systemd 服务并设置开机自启
#    4. 安装 login.sh 凭据登录助手 (支持 codex/claude/gemini/kimi/xai)
#    5. 可选: 安装 Codex CLI 并写好指向本机 CPA 的 ~/.codex/config.toml
#    6. 可选: 安装 bubblewrap (Codex 沙箱依赖)
#    7. 健康检查: 验证鉴权拒绝未授权请求, 放行携带 key 的请求
#
#  用法:
#    sudo ./install.sh                          # 全默认
#    sudo CPA_PORT=9000 ./install.sh            # 换端口
#    sudo SKIP_CODEX=1 ./install.sh             # 只装 CPA, 不动 Codex
#    sudo CPA_VERSION=v7.2.149 ./install.sh     # 锁定版本
#
#  幂等: 重复执行不会重新生成已有密钥, 不会删除已登录凭据;
#        改动 config.yaml / config.toml 前一律先备份。
#
#  卸载: sudo ./uninstall.sh
# ==============================================================================
set -euo pipefail

readonly REPO="router-for-me/CLIProxyAPI"

# ---- 可通过环境变量覆盖的配置 ------------------------------------------------
CPA_VERSION="${CPA_VERSION:-latest}"          # latest 或 vX.Y.Z
CPA_DIR="${CPA_DIR:-/opt/cliproxyapi}"        # 二进制与辅助脚本安装目录
CPA_HOST="${CPA_HOST:-127.0.0.1}"             # 监听地址, 留空字符串=所有网卡(危险)
CPA_PORT="${CPA_PORT:-8317}"                  # 监听端口
TARGET_HOME="${TARGET_HOME:-/root}"           # 服务运行用户的家目录
AUTH_DIR="${AUTH_DIR:-$TARGET_HOME/.cli-proxy-api}"
SERVICE_NAME="${SERVICE_NAME:-cliproxyapi}"
CODEX_HOME="${CODEX_HOME:-$TARGET_HOME/.codex}"
CODEX_VERSION="${CODEX_VERSION:-0.153.2}"     # 已验证可用的版本, 可设为 latest
CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
SKIP_CODEX="${SKIP_CODEX:-0}"
SKIP_BWRAP="${SKIP_BWRAP:-0}"

# ---- 输出 --------------------------------------------------------------------
info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# 临时目录统一在 EXIT 时清理。不要用 RETURN trap —— 它是全局生效的,
# 会在后续每个函数返回时重复触发, 并在 set -u 下因局部变量失效而报错。
CPA_TMP=""
cleanup() { [ -n "${CPA_TMP:-}" ] && rm -rf "$CPA_TMP"; return 0; }
trap cleanup EXIT

# ---- 1. 前置检查 -------------------------------------------------------------
preflight() {
  [ "$(id -u)" -eq 0 ] || die "需要 root 权限, 请用 sudo 执行"
  command -v systemctl >/dev/null || die "未检测到 systemd, 本脚本不适用"

  local missing=()
  for c in curl tar sha256sum openssl; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    info "安装缺失依赖: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl tar coreutils openssl \
      || die "依赖安装失败, 请手动安装: ${missing[*]}"
  fi

  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) die "不支持的架构: $(uname -m) (仅支持 x86_64 / aarch64)" ;;
  esac

  if [ "$CPA_HOST" != "127.0.0.1" ] && [ "$CPA_HOST" != "localhost" ]; then
    warn "CPA_HOST=$CPA_HOST 会把服务暴露到该地址可达的网络。"
    warn "api-keys 鉴权虽已启用, 仍请确保防火墙只放行可信来源。"
  fi
  ok "环境检查通过 (arch=$ARCH)"
}

# ---- 2. 解析版本号 -----------------------------------------------------------
resolve_version() {
  if [ "$CPA_VERSION" = "latest" ]; then
    info "查询 $REPO 最新 release ..."
    # 注意: 必须先完整取回再解析。curl 直接管到 grep -m1 会因 SIGPIPE 报错 23,
    #       在 pipefail 下会误判为失败。
    local json
    json="$(curl -fsSL --retry 3 "https://api.github.com/repos/$REPO/releases/latest")" \
      || die "查询 GitHub API 失败, 请显式指定 CPA_VERSION=vX.Y.Z"
    CPA_VERSION="$(printf '%s' "$json" | grep '"tag_name"' | head -1 | cut -d'"' -f4)"
    [ -n "$CPA_VERSION" ] || die "无法解析最新版本号, 请显式指定 CPA_VERSION=vX.Y.Z"
  fi
  VER_NUM="${CPA_VERSION#v}"                       # tag 带 v, 文件名不带
  TARBALL="CLIProxyAPI_${VER_NUM}_linux_${ARCH}.tar.gz"
  BASE_URL="https://github.com/$REPO/releases/download/$CPA_VERSION"
  ok "目标版本: $CPA_VERSION ($TARBALL)"
}

# ---- 3. 下载 / 校验 / 安装二进制 ---------------------------------------------
install_binary() {
  CPA_TMP="$(mktemp -d)"
  local tmp="$CPA_TMP"

  info "下载 $TARBALL ..."
  curl -fL --retry 3 --progress-bar -o "$tmp/$TARBALL" "$BASE_URL/$TARBALL" \
    || die "下载失败: $BASE_URL/$TARBALL"
  curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$BASE_URL/checksums.txt" \
    || die "下载 checksums.txt 失败"

  info "校验 sha256 ..."
  ( cd "$tmp" && grep " $TARBALL\$" checksums.txt | sha256sum -c - ) \
    || die "sha256 校验失败, 文件可能损坏或被篡改, 已中止"
  ok "校验通过"

  tar -xzf "$tmp/$TARBALL" -C "$tmp"
  [ -f "$tmp/cli-proxy-api" ] || die "压缩包内未找到 cli-proxy-api"

  install -d -m 0755 "$CPA_DIR"
  # 服务在运行时无法直接覆盖二进制, 先停服
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "停止运行中的 $SERVICE_NAME 以替换二进制"
    systemctl stop "$SERVICE_NAME"
  fi
  install -m 0755 "$tmp/cli-proxy-api" "$CPA_DIR/cli-proxy-api"
  if [ -f "$tmp/config.example.yaml" ]; then
    install -m 0644 "$tmp/config.example.yaml" "$CPA_DIR/config.example.yaml"
  fi
  local ver; ver="$("$CPA_DIR/cli-proxy-api" --help 2>&1 | head -1 || true)"
  ok "已安装: $CPA_DIR/cli-proxy-api ($ver)"
}

# ---- 4. 密钥与配置文件 -------------------------------------------------------
setup_config() {
  install -d -m 0700 "$AUTH_DIR"

  # 密钥幂等: 已存在则复用, 避免重跑脚本导致下游客户端配置失效
  if [ -s "$AUTH_DIR/.apikey.txt" ]; then
    API_KEY="$(cat "$AUTH_DIR/.apikey.txt")"
    info "复用已有 API key"
  else
    API_KEY="sk-cpa-$(openssl rand -hex 20)"
    printf '%s\n' "$API_KEY" > "$AUTH_DIR/.apikey.txt"
    ok "已生成 API key"
  fi
  if [ -s "$AUTH_DIR/.mgmtkey.txt" ]; then
    MGMT_KEY="$(cat "$AUTH_DIR/.mgmtkey.txt")"
  else
    MGMT_KEY="mgmt-$(openssl rand -hex 16)"
    printf '%s\n' "$MGMT_KEY" > "$AUTH_DIR/.mgmtkey.txt"
  fi
  chmod 0600 "$AUTH_DIR/.apikey.txt" "$AUTH_DIR/.mgmtkey.txt"

  # config.yaml 不覆盖已有文件, 避免抹掉手工调整过的 provider / strategy
  if [ -f "$AUTH_DIR/config.yaml" ]; then
    warn "已存在 $AUTH_DIR/config.yaml, 跳过写入 (如需重置: 删除该文件后重跑)"
  else
    cat > "$AUTH_DIR/config.yaml" <<EOF
# CLIProxyAPI 配置 — 由 install.sh 生成
# 完整字段参考: $CPA_DIR/config.example.yaml

host: "$CPA_HOST"
port: $CPA_PORT

# OAuth / API key 凭据目录, 服务通过 file watcher 热加载
auth-dir: "$AUTH_DIR"

# 下游客户端调用本服务时必须携带的密钥
api-keys:
  - "$API_KEY"

# 管理 API: 仅 localhost 可访问; 明文 secret-key 会在首次启动时被 bcrypt 回写
remote-management:
  allow-remote: false
  secret-key: "$MGMT_KEY"

debug: false

# ---- 凭据自动切换 ----------------------------------------------------------
# 这些字段一旦省略, 生效值是 Go 零值 (0 / false), 而不是 config.example.yaml
# 注释里写的推荐值 —— 省略就等于把自动切换关掉。所以这里显式写全。

# 首轮之外的额外重试轮数。对 403/408/429/500/502/503/504 生效, 每轮换用池中
# 其他凭据 —— 这是"自动切换"的主开关, 为 0 时不会切换。
request-retry: 3
max-retry-credentials: 0      # 每轮最多试几个凭据, 0 = 不限
max-retry-interval: 30        # 命中冷却时的最长等待秒数
save-cooldown-status: true    # 冷却状态持久化, 重启不会把限流中的号立刻放回池子

quota-exceeded:
  switch-project: true        # 配额耗尽时自动切到另一个可用凭据
  switch-preview-model: true  # 自动降级到 preview 模型

routing:
  strategy: "round-robin"     # round-robin | weighted-round-robin | fill-first
  session-affinity: false     # true = 同会话固定同一凭据(省 cache, 分散度下降)
EOF
    chmod 0600 "$AUTH_DIR/config.yaml"
    ok "已写入 $AUTH_DIR/config.yaml (监听 ${CPA_HOST:-0.0.0.0}:$CPA_PORT)"
  fi
}

# ---- 5. 凭据登录助手 ---------------------------------------------------------
install_login_helper() {
  cat > "$CPA_DIR/login.sh" <<'EOF_LOGIN'
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
EOF_LOGIN

  sed -i \
    -e "s#@CPA_BIN@#$CPA_DIR/cli-proxy-api#" \
    -e "s#@CPA_CFG@#$AUTH_DIR/config.yaml#" \
    -e "s#@AUTH_DIR@#$AUTH_DIR#" \
    "$CPA_DIR/login.sh"
  chmod 0755 "$CPA_DIR/login.sh"
  bash -n "$CPA_DIR/login.sh" || die "生成的 login.sh 语法错误"
  ok "已安装登录助手: $CPA_DIR/login.sh"
}

# ---- 5b. 凭据池状态查看器 ----------------------------------------------------
install_status_helper() {
  cat > "$CPA_DIR/status.sh" <<'EOF_STATUS'
#!/usr/bin/env bash
# CPA 凭据池状态 —— 看清自动切换在拿什么号、谁被限流了
set -euo pipefail

AUTH_DIR="@AUTH_DIR@"
ENDPOINT="@ENDPOINT@"

command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }
[ -s "$AUTH_DIR/.mgmtkey.txt" ] || { echo "未找到管理密钥: $AUTH_DIR/.mgmtkey.txt" >&2; exit 1; }
MG="$(cat "$AUTH_DIR/.mgmtkey.txt")"

fetch() { curl -fsS -m 15 -H "Authorization: Bearer $MG" "$ENDPOINT/v0/management/$1"; }

PY_CFG=$(cat <<'PY'
import json, sys
d = json.load(sys.stdin)
q = d.get("quota-exceeded") or {}
r = d.get("routing") or {}
rows = [
    ("request-retry",         d.get("request-retry"),          "额外重试轮数, 0 = 不会换凭据重试"),
    ("max-retry-credentials", d.get("max-retry-credentials"),  "每轮最多试几个凭据, 0 = 不限"),
    ("max-retry-interval",    d.get("max-retry-interval"),     "命中冷却时的最长等待秒数"),
    ("save-cooldown-status",  d.get("save-cooldown-status"),   "冷却状态是否持久化"),
    ("quota switch-project",  q.get("switch-project"),         "配额耗尽是否自动换凭据"),
    ("routing strategy",      r.get("strategy") or "(未设置)", "多凭据选择策略"),
    ("session-affinity",      bool(r.get("session-affinity")), "同会话是否固定同一凭据"),
]
for k, v, note in rows:
    print("  {:22} {:14} {}".format(k, str(v), note))
if not d.get("request-retry"):
    print("\n  [!] request-retry 为 0 —— 自动切换实际上是关闭的")
PY
)

PY_POOL=$(cat <<'PY'
import json, sys

def secs(v):
    try:
        v = int(v)
    except (TypeError, ValueError):
        return "-"
    if v <= 0:
        return "ready"
    h, m = divmod(v // 60, 60)
    return "{}h{:02d}m".format(h, m) if h else "{}m".format(m)

d = json.load(sys.stdin)
files = d.get("files") or []
if not files:
    print("  空 —— 先跑 login.sh 登录账号")
    raise SystemExit(0)

fmt = "  {:<30} {:<7} {:<6} {:<5} {:<7} {:<5} {:<4} {:<5} {}"
hdr = fmt.format("ACCOUNT", "PROV", "PLAN", "5H", "RESET", "7D", "OK", "FAIL", "STATE")
print(hdr)
print("  " + "-" * (len(hdr) - 2))

for f in files:
    acct = (f.get("email") or f.get("account") or f.get("label") or f.get("id") or "?")[:30]
    plan = (f.get("id_token") or {}).get("plan_type") or f.get("account_type") or "-"
    sig = (f.get("quota") or {}).get("signals") or {}
    if not sig:
        for mq in (f.get("model_quotas") or {}).values():
            sig = mq.get("signals") or {}
            if sig:
                break
    pri = sig.get("X-Codex-Primary-Used-Percent")
    sec = sig.get("X-Codex-Secondary-Used-Percent")
    state = f.get("status") or "-"
    if f.get("disabled"):
        state = "disabled"
    elif f.get("unavailable"):
        state = "unavailable"
    print(fmt.format(
        acct, f.get("provider") or "-", plan,
        (pri + "%") if pri else "-",
        secs(sig.get("X-Codex-Primary-Reset-After-Seconds")),
        (sec + "%") if sec else "-",
        str(f.get("success", 0)), str(f.get("failed", 0)), state,
    ))
    if f.get("status_message"):
        print("      └─ {}".format(f["status_message"]))

print("\n  共 {} 个凭据".format(len(files)))
print("  5H/7D = 主(5小时)/次(7天)配额窗口已用百分比; 空值表示尚未从上游响应学到信号")
PY
)

echo "=== 自动切换配置 ==="
fetch config | python3 -c "$PY_CFG"
echo
echo "=== 凭据池 ==="
fetch auth-files | python3 -c "$PY_POOL"
EOF_STATUS
  local probe="$CPA_HOST"
  [ -z "$probe" ] && probe="127.0.0.1"
  sed -i \
    -e "s#@AUTH_DIR@#$AUTH_DIR#" \
    -e "s#@ENDPOINT@#http://$probe:$CPA_PORT#" \
    "$CPA_DIR/status.sh"
  chmod 0755 "$CPA_DIR/status.sh"
  bash -n "$CPA_DIR/status.sh" || die "生成的 status.sh 语法错误"
  ok "已安装状态查看器: $CPA_DIR/status.sh"
}

# ---- 6. systemd 服务 ---------------------------------------------------------
install_service() {
  cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=CLIProxyAPI (CPA) - OpenAI/Gemini/Claude/Codex compatible API proxy
Documentation=https://help.router-for.me/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=$TARGET_HOME
WorkingDirectory=$CPA_DIR
ExecStart=$CPA_DIR/cli-proxy-api --config $AUTH_DIR/config.yaml
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl restart "$SERVICE_NAME"
  ok "systemd 服务已启用并启动: $SERVICE_NAME"
}

# ---- 7. 健康检查 -------------------------------------------------------------
health_check() {
  local probe_host="$CPA_HOST"
  [ -z "$probe_host" ] && probe_host="127.0.0.1"
  local url="http://$probe_host:$CPA_PORT"

  info "等待服务就绪 ..."
  local i code
  for i in $(seq 1 20); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$url/v1/models" || true)"
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then break; fi
    sleep 1
  done

  local unauth auth
  unauth="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url/v1/models" || true)"
  auth="$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
    -H "Authorization: Bearer $API_KEY" "$url/v1/models" || true)"

  [ "$unauth" = "401" ] || die "鉴权异常: 未携带 key 时返回 $unauth (期望 401)。检查 journalctl -u $SERVICE_NAME"
  [ "$auth" = "200" ]   || die "携带 key 访问失败: HTTP $auth (期望 200)。检查 journalctl -u $SERVICE_NAME"
  ok "健康检查通过 (未授权 401 / 已授权 200)"
}

# ---- 8. Codex CLI ------------------------------------------------------------
install_codex() {
  if ! command -v npm >/dev/null; then
    warn "未检测到 npm, 跳过 Codex CLI 安装。装好 Node.js (>=18) 后重跑本脚本即可。"
    return 0
  fi

  local want="$CODEX_VERSION" cur=""
  cur="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [ "$want" != "latest" ] && [ "$cur" = "$want" ]; then
    info "Codex CLI 已是 $cur, 跳过安装"
  else
    info "安装 Codex CLI @openai/codex@$want (当前: ${cur:-未安装}) ..."
    npm install -g "@openai/codex@$want" >/dev/null 2>&1 \
      || die "Codex CLI 安装失败, 请手动执行: npm install -g @openai/codex@$want"
    local cver; cver="$(codex --version 2>&1 | head -1 || true)"
    ok "Codex CLI: $cver"
  fi

  install -d -m 0700 "$CODEX_HOME"
  local cfg="$CODEX_HOME/config.toml"
  if [ -f "$cfg" ]; then
    local bak="$cfg.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$cfg" "$bak"
    warn "已备份原 config.toml -> $bak"
    warn "脚本会写入新配置; 原有的自定义 provider / projects 段需要你手工合并回去。"
  fi

  local base_host="$CPA_HOST"
  [ -z "$base_host" ] && base_host="127.0.0.1"
  cat > "$cfg" <<EOF
# Codex CLI 配置 — 由 install.sh 生成
# provider "cliproxyapi" 指向本机 CLIProxyAPI, systemd 单元: $SERVICE_NAME

model_provider = "cliproxyapi"
model = "$CODEX_MODEL"
model_reasoning_effort = "xhigh"
plan_mode_reasoning_effort = "xhigh"

[model_providers.cliproxyapi]
name = "OpenAI"
base_url = "http://$base_host:$CPA_PORT/v1"
wire_api = "responses"
experimental_bearer_token = "$API_KEY"
requires_openai_auth = true
EOF
  chmod 0600 "$cfg"
  ok "已写入 $cfg (model=$CODEX_MODEL)"
}

# ---- 9. bubblewrap (Codex 沙箱依赖, 可选) ------------------------------------
install_bwrap() {
  if command -v bwrap >/dev/null; then
    info "bubblewrap 已存在: $(bwrap --version 2>&1)"
    return 0
  fi
  if ! command -v apt-get >/dev/null; then
    warn "非 apt 系发行版, 请自行安装 bubblewrap"
    return 0
  fi
  info "安装 bubblewrap ..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bubblewrap; then
    ok "bubblewrap: $(bwrap --version 2>&1)"
  else
    warn "bubblewrap 安装失败, Codex 会回退到内置副本, 不影响使用"
  fi
}

# ---- 10. 总结 ----------------------------------------------------------------
summary() {
  local base_host="$CPA_HOST"
  [ -z "$base_host" ] && base_host="127.0.0.1"
  cat <<EOF

$(printf '=%.0s' {1..78})
 部署完成
$(printf '=%.0s' {1..78})

  服务        : $SERVICE_NAME  ($(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null) / $(systemctl is-active "$SERVICE_NAME" 2>/dev/null))
  端点        : http://$base_host:$CPA_PORT
  二进制      : $CPA_DIR/cli-proxy-api
  配置        : $AUTH_DIR/config.yaml
  API key     : $AUTH_DIR/.apikey.txt
  管理 key    : $AUTH_DIR/.mgmtkey.txt

  下一步 — 登录上游账号 (必须在真实终端执行, 需要浏览器授权):

      $CPA_DIR/login.sh

  浏览器打开提示的 URL 并输入设备码即可。凭据落到 $AUTH_DIR/*.json,
  服务自动热加载。之后验证可用模型:

      curl -s -H "Authorization: Bearer \$(cat $AUTH_DIR/.apikey.txt)" \\
        http://$base_host:$CPA_PORT/v1/models

  然后直接使用:

      codex                      # 交互式
      codex exec "你的任务"      # 非交互

  凭据池状态 (谁在限流、配额还剩多少、自动切换是否真的开着):

      $CPA_DIR/status.sh

  提醒: 自动切换需要池里有 2 个以上凭据才有意义 —— 只登一个号时,
        限流了也无处可切。多跑几次 login.sh 登录不同账号。

  运维:  journalctl -u $SERVICE_NAME -f
         systemctl restart $SERVICE_NAME

$(printf '=%.0s' {1..78})
EOF
}

# ---- main --------------------------------------------------------------------
main() {
  preflight
  resolve_version
  install_binary
  setup_config
  install_login_helper
  install_status_helper
  install_service
  health_check
  [ "$SKIP_CODEX" = "1" ] || install_codex
  [ "$SKIP_BWRAP" = "1" ] || install_bwrap
  summary
}

main "$@"

