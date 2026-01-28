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

REPO_DIR="${REPO_DIR:-/Users/kenny/clawd/zidong/Microsoft-Rewards-Script}"
MODE="${MODE:-build_start}"

# Auto-load repo .env if present
if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${REPO_DIR}/.env"
  set +a
fi

TS="$(date '+%F %T')"
LOG_DIR="${REPO_DIR}/run-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run-$(date '+%F_%H%M%S').log"

send_telegram() {
  local title="$1"; shift
  local text="$1"; shift || true
  [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || return 0
  curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${title}\n${text}" \
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

notify() {
  local title="$1"; shift
  local body="$1"; shift || true
  send_telegram "$title" "$body"
  send_pushplus "$title" "$body"
}

notify "[Rewards] 开始运行" "${TS}\nmode=${MODE}\nlog=${LOG_FILE}"

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
) 2>&1 | tee "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

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

if [[ ${#ALERTS[@]} -gt 0 ]]; then
  notify "[Rewards] 需要关注" "${TS}\n${SUMMARY_LINE}\n\n问题：\n- $(printf '%s\n- ' "${ALERTS[@]}" | sed '$s/^- $//')\n\nlog=${LOG_FILE}"
else
  notify "[Rewards] 完成" "${TS}\n${SUMMARY_LINE}\nexit=${EXIT_CODE}\nlog=${LOG_FILE}"
fi

exit $EXIT_CODE
