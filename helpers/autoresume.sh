#!/usr/bin/env bash
# ==============================================================================
#  CPA 限流自动续跑 (autoresume)
#
#  用途: 所有凭据的配额窗口都用满时, 精确等到最早的重置时刻, 然后自动续跑,
#        循环直到任务完成。这是"遵守限流并在窗口重置后继续", 不是绕过限流。
#
#  两种模式:
#    run   在本进程里循环跑 codex exec, 撞 429 就等, 重置后 resume 续接会话
#    watch 监控一个已存在的 screen 会话(交互式 codex TUI), 撞限流就等,
#          重置后用 screen stuff 把继续指令打进去
#
#  等待时长来自 CPA 管理 API 的真实配额信号(X-Codex-Primary/Secondary-Reset-At),
#  不是猜的固定值, 也不靠解析人类可读文本。
# ==============================================================================
set -uo pipefail

AUTH_DIR="@AUTH_DIR@"
ENDPOINT="@ENDPOINT@"
LOG="$AUTH_DIR/autoresume.log"

SESSION="cpa-codex"        # -s 覆盖
MAX_ROUNDS=24              # -m 覆盖; 每轮通常对应一个 5 小时窗口
POLL=60                    # watch 模式抓屏间隔(秒)
BUFFER=45                  # 重置时刻之后再多等几秒, 防止边界抖动
FALLBACK_WAIT=300          # 拿不到配额信号时的保守重试间隔
SIGNAL_LAG=90              # -l 覆盖; 上游已 429 但 CPA 配额信号还没更新时的冷静期
WORKDIR=""                 # -C 覆盖
LOGSRC=""                  # -f 覆盖; watch 模式改从 screen 日志文件读取

command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }
[ -s "$AUTH_DIR/.mgmtkey.txt" ] || { echo "未找到管理密钥: $AUTH_DIR/.mgmtkey.txt" >&2; exit 1; }
MG="$(cat "$AUTH_DIR/.mgmtkey.txt")"

say() { printf '[%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

PY_NEXT=$(cat <<'PY'
import json, sys, time

def num(sig, k):
    try:
        return int(float(sig.get(k, 0)))
    except (TypeError, ValueError):
        return 0

d = json.load(sys.stdin)
files = d.get("files") or []
best = None
for f in files:
    if f.get("disabled"):
        continue
    sig = (f.get("quota") or {}).get("signals") or {}
    if not sig:
        for mq in (f.get("model_quotas") or {}).values():
            sig = mq.get("signals") or {}
            if sig:
                break
    avail = 0
    if sig:
        if num(sig, "X-Codex-Primary-Used-Percent") >= 100:
            avail = max(avail, num(sig, "X-Codex-Primary-Reset-At"))
        if num(sig, "X-Codex-Secondary-Used-Percent") >= 100:
            avail = max(avail, num(sig, "X-Codex-Secondary-Reset-At"))
    if best is None or avail < best:
        best = avail
print(best if best is not None else -1)
PY
)

# 输出: -1 池中无凭据 | 0 现在就有可用凭据 | >0 最早可用的 Unix 时间戳
next_reset() {
  local json
  json="$(curl -fsS -m 15 -H "Authorization: Bearer $MG" \
    "$ENDPOINT/v0/management/auth-files" 2>/dev/null)" || { echo 0; return; }
  printf '%s' "$json" | python3 -c "$PY_NEXT" 2>/dev/null || echo 0
}

fmt_dur() {
  local s=$1 h m
  [ "$s" -lt 0 ] && s=0
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"; else printf '%dm%02ds' "$m" "$((s % 60))"; fi
}

# 等到有凭据可用。返回 0 表示可以继续, 1 表示池子空了。
wait_for_quota() {
  local ts now wait
  while :; do
    ts="$(next_reset)"
    case "$ts" in
      -1) say "凭据池为空 —— 先跑 login.sh 登录账号"; return 1 ;;
      0)  return 0 ;;
    esac
    now="$(date +%s)"
    wait=$((ts - now + BUFFER))
    if [ "$wait" -le 0 ]; then
      say "重置时刻已过, 立即重试"
      return 0
    fi
    say "全部凭据限流中 → 等待 $(fmt_dur $wait) 至 $(date -d "@$((ts + BUFFER))" '+%m-%d %H:%M:%S')"
    # 分段睡眠, 期间若有凭据提前恢复(例如你中途登了新号)就提早返回
    local slept=0 step
    while [ "$slept" -lt "$wait" ]; do
      step=$((wait - slept)); [ "$step" -gt 120 ] && step=120
      sleep "$step"; slept=$((slept + step))
      [ "$(next_reset)" = "0" ] && { say "检测到可用凭据, 提前恢复"; return 0; }
    done
    return 0
  done
}

is_limited() {   # $1=日志文件 $2=退出码
  [ "$2" -eq 0 ] && return 1
  grep -qiE '429 Too Many Requests|exceeded retry limit|usage_limit_reached|usage limit|rate.?limit' "$1"
}

# 上游已经返回 429, 但 CPA 的配额信号是从响应头里学的, 可能还没刷到 100%。
# 这时 next_reset 会返回 0(看起来可用), 若直接重试就会快速空转烧掉轮数。
# 所以先强制冷静一段时间, 给信号一点时间落地。
cool_down_if_signal_lags() {
  if [ "$(next_reset)" = "0" ]; then
    say "上游已限流但 CPA 配额信号尚未更新, 先冷静 ${SIGNAL_LAG}s 再查"
    sleep "$SIGNAL_LAG"
  fi
}

# ---- run 模式 ----------------------------------------------------------------
mode_run() {
  local prompt="$1" round=0 out rc first=1
  out="$(mktemp)"; trap 'rm -f "$out"' RETURN
  [ -n "$WORKDIR" ] && cd "$WORKDIR"

  say "=== run 模式启动 | 工作目录 $(pwd) | 上限 $MAX_ROUNDS 轮 ==="
  while [ "$round" -lt "$MAX_ROUNDS" ]; do
    round=$((round + 1))
    wait_for_quota || return 1

    if [ "$first" = "1" ]; then
      say "第 $round 轮: 新建会话"
      codex exec --skip-git-repo-check "$prompt" >"$out" 2>&1; rc=$?
    else
      say "第 $round 轮: resume 续接上一会话"
      codex exec resume --last --skip-git-repo-check "继续未完成的工作" >"$out" 2>&1; rc=$?
    fi

    tail -c 2000 "$out" >>"$LOG"
    if [ "$rc" -eq 0 ]; then
      say "第 $round 轮正常结束 (exit 0) —— 任务完成"
      tail -5 "$out"
      return 0
    fi
    if is_limited "$out" "$rc"; then
      first=0
      say "第 $round 轮撞到限流 (exit $rc), 转入等待"
      cool_down_if_signal_lags
      continue
    fi
    say "第 $round 轮以 exit $rc 失败, 且不是限流 —— 停止, 详见 $LOG"
    tail -15 "$out"
    return "$rc"
  done
  say "达到 $MAX_ROUNDS 轮上限, 停止"
  return 2
}

# ---- watch 模式 --------------------------------------------------------------
# 监控一个已存在的 screen 会话里的交互式 codex TUI。
screen_alive() { screen -ls 2>/dev/null | grep -qE "[0-9]+\.${SESSION}[[:space:]]"; }

grab() {   # 取当前可见输出到 stdout (统一滤掉 NUL, 否则命令替换会刷警告)
  if [ -n "$LOGSRC" ]; then
    [ -f "$LOGSRC" ] && tail -c 8000 "$LOGSRC" 2>/dev/null | tr -d '\000'
    return 0
  fi
  local hc; hc="$(mktemp)"
  screen -S "$SESSION" -X hardcopy "$hc" >/dev/null 2>&1 || { rm -f "$hc"; return 1; }
  sleep 0.3
  tr -d '\000' < "$hc" 2>/dev/null; rm -f "$hc"
}

# hardcopy 只能看到"当前屏幕"。交互式 TUI 会不断重绘, 限流提示可能已经被
# 后续界面覆盖 —— 这是 watch 模式的固有局限, 用 -f 读 screen 的累积日志可以
# 绕开(日志里的历史不会被重绘冲掉)。这里只做一层兜底: 如果连一屏字符都读不到,
# 说明抓取通道本身有问题, 直接报错而不是空转到轮数耗尽。
verify_readable() {
  local probe stripped
  probe="$(grab || true)"
  stripped="$(printf '%s' "$probe" | tr -d '[:space:]')"
  [ "${#stripped}" -ge 16 ] && return 0

  warn "读不到会话输出 (有效字符 ${#stripped} 个)。"
  if [ -n "$LOGSRC" ]; then
    warn "日志文件 $LOGSRC 为空或不存在 —— 确认 screen 启动时带了 -L -Logfile。"
  else
    warn "screen -X hardcopy 抓不到这个会话的内容。改用日志方式:"
    warn "  screen -dmS $SESSION -L -Logfile /tmp/$SESSION.log codex"
    warn "  $0 watch -s $SESSION -f /tmp/$SESSION.log"
  fi
  warn "已中止, 以免空转白等。run 模式不依赖屏幕抓取, 是更可靠的选择。"
  return 1
}

mode_watch() {
  command -v screen >/dev/null || { say "未安装 screen"; return 1; }
  screen_alive || { say "screen 会话 '$SESSION' 不存在。先建: screen -S $SESSION"; return 1; }
  verify_readable || return 1

  local round=0 screen_txt
  say "=== watch 模式启动 | 会话 $SESSION | 轮询 ${POLL}s | 上限 $MAX_ROUNDS 轮${LOGSRC:+ | 读日志 $LOGSRC} ==="
  while [ "$round" -lt "$MAX_ROUNDS" ]; do
    if ! screen_alive; then say "会话 $SESSION 已消失, 退出"; return 0; fi
    screen_txt="$(grab || true)"

    if printf '%s' "$screen_txt" | grep -qiE "hit your usage limit|usage limit|Try again later|429 Too Many Requests|exceeded retry limit"; then
      round=$((round + 1))
      say "第 $round 次检测到限流提示, 转入等待"
      cool_down_if_signal_lags
      wait_for_quota || return 1
      say "配额已恢复, 向会话发送继续指令"
      screen -S "$SESSION" -X stuff "继续未完成的工作$(printf '\r')" >/dev/null 2>&1 \
        || say "stuff 失败, 会话可能已退出"
      sleep 15
    else
      sleep "$POLL"
    fi
  done
  say "达到 $MAX_ROUNDS 轮上限, 停止"
  return 2
}

usage() {
  cat <<'EOF'
用法:
  autoresume.sh run   [选项] "<任务描述>"    在本进程循环跑 codex exec, 限流则等待续跑
  autoresume.sh watch [选项]                 监控已有 screen 会话里的交互式 codex

选项:
  -s SESSION   screen 会话名 (watch 模式, 默认 cpa-codex)
  -m N         最大轮数 (默认 24; 每轮通常对应一个 5 小时窗口)
  -C DIR       run 模式的工作目录
  -p SEC       watch 模式抓屏间隔 (默认 60)
  -f FILE      watch 模式改从 screen 日志文件读取 (交互式 TUI 必需, 见下)
  -l SEC       撞到 429 但 CPA 配额信号还没更新时的冷静期 (默认 90)

典型用法 —— 把 run 模式本身放进 screen, 断线也不影响:
  screen -dmS cpa-run -L -Logfile @AUTH_DIR@/run.log \
    @CPA_DIR@/autoresume.sh run -C /path/to/repo "把测试全部跑通并修掉失败项"
  screen -r cpa-run          # 随时回来看
  tail -f @AUTH_DIR@/autoresume.log

已经手动开着 TUI 的场景:
  # hardcopy 只看得到"当前屏幕", 而 TUI 会不断重绘 —— 限流提示可能在脚本
  # 下一次抓屏前就被覆盖掉。开 screen 日志读累积输出更稳:
  screen -dmS cpa-codex -L -Logfile /tmp/cpa.log codex
  @CPA_DIR@/autoresume.sh watch -s cpa-codex -f /tmp/cpa.log

  # 不带 -f 也能跑(直接抓屏), 但漏检风险更高:
  @CPA_DIR@/autoresume.sh watch -s cpa-codex

  要确定性就用 run 模式 —— 它按退出码判断, 不依赖屏幕抓取。

等待时长取自 CPA 管理 API 的真实重置时间戳; 若 7 天窗口也满了会自动等更久的那个。
EOF
}

MODE="${1:-}"; shift 2>/dev/null || true
while getopts "s:m:C:p:l:f:h" o; do
  case "$o" in
    s) SESSION="$OPTARG" ;;
    m) MAX_ROUNDS="$OPTARG" ;;
    C) WORKDIR="$OPTARG" ;;
    p) POLL="$OPTARG" ;;
    l) SIGNAL_LAG="$OPTARG" ;;
    f) LOGSRC="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

case "$MODE" in
  run)   [ $# -ge 1 ] || { echo "run 模式需要任务描述" >&2; usage; exit 1; }; mode_run "$*" ;;
  watch) mode_watch ;;
  ""|-h|--help|help) usage ;;
  *) echo "未知模式: $MODE" >&2; usage; exit 1 ;;
esac
