#!/usr/bin/env bash
set -euo pipefail

# Microsoft-Rewards-Script wrapper with notifications
# Optimized for multiple approval notifications and better error reporting

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${MODE:-start_only}"

# Auto-load repo .env if present
if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  source "${REPO_DIR}/.env"
  set +a
fi

START_EPOCH=$(date +%s)
TS="$(date '+%F %T')"
LOG_DIR="${REPO_DIR}/run-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run-$(date '+%F_%H%M%S').log"
LOG_BASENAME="$(basename "$LOG_FILE")"

send_telegram() {
  local title="$1"; shift
  local text="$1"; shift || true
  [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || return 0
  local payload
  payload="$(printf '%s\n%b' "$title" "$text")"
  curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"     -d "chat_id=${TG_CHAT_ID}"     --data-urlencode "text=${payload}"     -d "disable_web_page_preview=true"     >/dev/null || true
}

send_pushplus() {
  local title="$1"; shift
  local content="$1"; shift || true
  [[ -n "${PUSHPLUS_TOKEN:-}" ]] || return 0
  curl -sS -X POST "https://www.pushplus.plus/send"     -H 'Content-Type: application/json'     -d "{\"token\":\"${PUSHPLUS_TOKEN}\",\"title\":\"${title}\",\"content\":\"${content}\",\"template\":\"txt\"}"     >/dev/null || true
}

should_notify() {
  local policy="$1"; shift
  local event="$1"; shift
  case "$policy" in
    all|"" ) return 0 ;;
    none ) return 1 ;;
    approval_only ) [[ "$event" == "approval" ]] ;;
    end_only ) [[ "$event" == end_* ]] ;;
    alert_only ) [[ "$event" == "end_alert" ]] ;;
    * ) return 0 ;;
  esac
}

notify() {
  local event="$1"; shift
  local title="$1"; shift
  local body="$1"; shift || true

  local tg_policy="${NOTIFY_TG:-all}"
  local pp_policy="${NOTIFY_PUSHPLUS:-all}"

  if should_notify "$tg_policy" "$event"; then
    send_telegram "$title" "$body"
  fi
  if should_notify "$pp_policy" "$event"; then
    send_pushplus "$title" "$body"
  fi
}

notify start "[Rewards] 启动" "时间：${TS}\n模式：${MODE}\n日志：${LOG_BASENAME}"

: > "$LOG_FILE"

# Realtime watcher: allow multiple notifications
(
  tail -n 0 -F "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    if [[ "$line" == *"Please approve login and select number:"* ]]; then
      num="$(echo "$line" | sed -E 's/.*select number: ([0-9]+).*/\1/' )"
      [[ -n "$num" ]] || num="(unknown)"
      event_ts="$(date '+%F %T')"
      notify approval "[Rewards] 需要你确认 ${num}" "Authenticator 数字匹配：${num}\n当前时间：${event_ts}\n日志：${LOG_BASENAME}"
    fi
  done
) &
WATCHER_PID=$!

set +e
(
  cd "$REPO_DIR" || exit 2
  if [[ "$MODE" == "build_start" ]]; then
    npm run pre-build
    npm run build
    npm run start
  else
    npm run start
  fi
) 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

kill "$WATCHER_PID" >/dev/null 2>&1 || true

# Extract summary
SUMMARY_LINE="$(grep -E "Collected: \+" -n "$LOG_FILE" | tail -n 1 | sed 's/^.*Collected:/Collected:/')"
[[ -n "$SUMMARY_LINE" ]] || SUMMARY_LINE="(no Collected summary found)"

ALERTS=()
grep -qiE "Failed to get mobile access token" "$LOG_FILE" && ALERTS+=("mobile access token 获取失败")
grep -qiE "App access token not available" "$LOG_FILE" && ALERTS+=("App token 不可用")
grep -qiE "Timed out waiting for OAuth code|Passwordless authentication timeout|Login approval failed or timed out" "$LOG_FILE" && ALERTS+=("Authenticator 认证超时/未及时响应")
grep -qiE "UNCAUGHT-EXCEPTION|MAIN-ERROR|unhandledRejection" "$LOG_FILE" && ALERTS+=("脚本运行出现异常")
[[ $EXIT_CODE -ne 0 ]] && ALERTS+=("进程退出码：${EXIT_CODE}")

END_EPOCH=$(date +%s)
DURATION=$((END_EPOCH - START_EPOCH))
DUR_MIN=$((DURATION / 60))
DUR_SEC=$((DURATION % 60))

TOTAL_POINTS="$(echo "$SUMMARY_LINE" | sed -nE 's/.*Collected: \+([0-9]+).*/\1/p')"
MOBILE_POINTS="$(echo "$SUMMARY_LINE" | sed -nE 's/.*Mobile: \+([0-9]+).*/\1/p')"
DESKTOP_POINTS="$(echo "$SUMMARY_LINE" | sed -nE 's/.*Desktop: \+([0-9]+).*/\1/p')"

[[ -n "$TOTAL_POINTS" ]] || TOTAL_POINTS="?"
[[ -n "$MOBILE_POINTS" ]] || MOBILE_POINTS="?"
[[ -n "$DESKTOP_POINTS" ]] || DESKTOP_POINTS="?"

SCORE_LINE="得分：总 +${TOTAL_POINTS}（Mobile +${MOBILE_POINTS} / Desktop +${DESKTOP_POINTS}）"
TIME_LINE="用时：${DUR_MIN}m${DUR_SEC}s"
LOG_LINE="日志：${LOG_BASENAME}"

if [[ ${#ALERTS[@]} -gt 0 ]]; then
  notify end_alert "[Rewards] 需要关注 ⚠️" "时间：${TS}\n${SCORE_LINE}\n${TIME_LINE}\n\n异常：\n- $(printf '%s\n- ' "${ALERTS[@]}" | sed '$s/^- $//')\n\n${LOG_LINE}"
else
  STATUS_LINE="$( [[ "$TOTAL_POINTS" == "0" ]] && echo "状态：今日已刷完" || echo "状态：正常" )"
  notify end_ok "[Rewards] 已完成 ✅" "时间：${TS}\n${SCORE_LINE}\n${TIME_LINE}\n${STATUS_LINE}\n${LOG_LINE}"
fi

exit $EXIT_CODE
