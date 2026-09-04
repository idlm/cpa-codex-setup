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
        acct,
        f.get("provider") or "-",
        plan,
        (pri + "%") if pri else "-",
        secs(sig.get("X-Codex-Primary-Reset-After-Seconds")),
        (sec + "%") if sec else "-",
        str(f.get("success", 0)),
        str(f.get("failed", 0)),
        state,
    ))
    if f.get("status_message"):
        print("      └─ {}".format(f["status_message"]))

print("\n  共 {} 个凭据".format(len(files)))
print("  5H/7D = 主(5小时)/次(7天)配额窗口已用百分比; 空值表示重启后尚未从上游响应学到信号")
PY
)

echo "=== 自动切换配置 ==="
fetch config | python3 -c "$PY_CFG"
echo
echo "=== 凭据池 ==="
fetch auth-files | python3 -c "$PY_POOL"
