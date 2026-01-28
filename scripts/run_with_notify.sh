#!/usr/bin/env bash
set -euo pipefail

# Microsoft-Rewards-Script wrapper with notifications
# Route A: no repo code changes. Uses env vars to send Telegram/pushplus notifications.
#
# Required:
#   REPO_DIR: path to Microsoft-Rewards-Script repo
# Optional (Telegram):
#   TG_BOT_TOKEN, TG_CHAT_ID
# Optional (pushplus):
#   PUSHPLUS_TOKEN
# Optional:
#   MODE=build_start (default) | start_only
#   NOTIFY_TG=all (default) | none | approval_only | end_only | alert_only
#   NOTIFY_PUSHPLUS=all (default) | none | approval_only | end_only | alert_only

REPO_DIR="${REPO_DIR:-/Users/kenny/clawd/zidong/Microsoft-Rewards-Script}"
MODE="${MODE:-build_start}"

# Auto-load repo .env if present
if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
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
  # Interpret \n in body as real newlines for human-readable Telegram messages
  payload="$(printf '%s\n%b' "$title" "$text")"
  curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${payload}" \
    -d "disable_web_page_preview=true" \
    >/dev/null || true
}

send_pushplus() {
  local title="$1"; shift
  local content="$1"; shift || true
  [[ -n "${PUSHPLUS_TOKEN:-}" ]] || return 0
  curl -sS -X POST "https://www.pushplus.plus/send" \
    -H 'Content-Type: application/json' \
    -d "{\"token\":\"${PUSHPLUS_TOKEN}\",\"title\":\"${title}\",\"content\":\"${content}\",\"template\":\"txt\"}" \
    >/dev/null || true
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

# Start notification
notify start "[Rewards] 启动" "时间：${TS}\n模式：${MODE}\n日志：${LOG_BASENAME}"

# Ensure log exists for tail -F
: > "$LOG_FILE"

# Realtime watcher: alert when Microsoft Authenticator number match is required
APPROVAL_NOTIFIED=0
(
  tail -n 0 -F "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    if [[ $APPROVAL_NOTIFIED -eq 0 && "$line" == *"Please approve login and select number:"* ]]; then
      num="$(echo "$line" | sed -E 's/.*select number: ([0-9]+).*/\1/' )"
      [[ -n "$num" ]] || num="(unknown)"
      notify approval "[Rewards] 需要你确认" "Authenticator 数字匹配：${num}\n场景：Desktop 登录\n日期：${TS}\n日志：${LOG_FILE}"
      APPROVAL_NOTIFIED=1
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

# Stop watcher
kill "$WATCHER_PID" >/dev/null 2>&1 || true

# Extract summary if present
SUMMARY_LINE="$(grep -E "Collected: \+" -n "$LOG_FILE" | tail -n 1 | sed 's/^.*Collected:/Collected:/')"
[[ -n "$SUMMARY_LINE" ]] || SUMMARY_LINE="(no Collected summary found)"

# Detect login/token issues (best-effort)
ALERTS=()

grep -qiE "Failed to get mobile access token" "$LOG_FILE" && ALERTS+=("mobile access token 获取失败（可能需要重新登录/2FA）")
grep -qiE "App access token not available" "$LOG_FILE" && ALERTS+=("App token 不可用（AppPromotions/CheckIn/ReadToEarn 会跳过）")
# generic login/page issues
grep -qiE "LOGIN|verifyBingSession|Login start" "$LOG_FILE" && :

grep -qiE "Timed out waiting for OAuth code" "$LOG_FILE" && ALERTS+=("OAuth code 等待超时（可能卡在 Authenticator 推送/登录页）")

grep -qiE "UNCAUGHT-EXCEPTION|MAIN-ERROR|unhandledRejection" "$LOG_FILE" && ALERTS+=("脚本运行出现异常（看日志末尾）")

if [[ $EXIT_CODE -ne 0 ]]; then
  ALERTS+=("进程退出码非 0：${EXIT_CODE}")
fi

# End notification (parse summary into human-friendly fields)
END_EPOCH=$(date +%s)
DURATION=$((END_EPOCH - START_EPOCH))
DUR_MIN=$((DURATION / 60))
DUR_SEC=$((DURATION % 60))

TOTAL_POINTS="$(echo "$SUMMARY_LINE" | sed -nE 's/.*Collected: \+([0-9]+).*/\1/p')"
MOBILE_POINTS="$(echo "$SUMMARY_LINE" | sed -nE 's/.*Mobile: \+([0-9]+).*/\1/p')"
DESKTOP_POINTS="$(echo "$SUMMARY_LINE" | sed -nE 's/.*Desktop: \+([0-9]+).*/\1/p')"
# (Optional) account email extraction; we intentionally do NOT include it in notifications
ACCOUNT_EMAIL="$(echo "$SUMMARY_LINE" | sed -nE 's/.*Desktop: \+[0-9]+ \| (.*)$/\1/p')"

[[ -n "$TOTAL_POINTS" ]] || TOTAL_POINTS="?"
[[ -n "$MOBILE_POINTS" ]] || MOBILE_POINTS="?"
[[ -n "$DESKTOP_POINTS" ]] || DESKTOP_POINTS="?"

SCORE_LINE="得分：总 +${TOTAL_POINTS}（Mobile +${MOBILE_POINTS} / Desktop +${DESKTOP_POINTS}）"
ACCOUNT_LINE=""
TIME_LINE="用时：${DUR_MIN}m${DUR_SEC}s"
LOG_LINE="日志：${LOG_BASENAME}"

if [[ ${#ALERTS[@]} -gt 0 ]]; then
  notify end_alert "[Rewards] 需要关注 ⚠️" "时间：${TS}\n${SCORE_LINE}\n${TIME_LINE}\n\n异常：\n- $(printf '%s\n- ' "${ALERTS[@]}" | sed '$s/^- $//')\n\n${LOG_LINE}"
else
  if [[ "$TOTAL_POINTS" == "0" ]]; then
    STATUS_LINE="状态：今日已刷完/无可做项"
  else
    STATUS_LINE="状态：正常"
  fi
  notify end_ok "[Rewards] 已完成 ✅" "时间：${TS}\n${SCORE_LINE}\n${TIME_LINE}\n${STATUS_LINE}\n${LOG_LINE}"
fi

exit $EXIT_CODE
