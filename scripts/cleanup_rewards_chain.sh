#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/home/xykshun/Microsoft-Rewards-Script"
SELF_PID="$$"
PARENT_PID="${PPID:-0}"
DRY_RUN="${DRY_RUN:-0}"

collect_pids() {
  ps -eo pid=,args= | while read -r pid cmdline; do
    [[ -n "${pid:-}" ]] || continue
    if [[ "$cmdline" == *"$REPO_DIR"*"run-logs/run-"* ]] || [[ "$cmdline" =~ run_with_notify\.sh|dist/index\.js ]]; then
      echo "$pid"
    fi
  done
}

mapfile -t PIDS < <(collect_pids | sort -u)
if [[ ${#PIDS[@]} -eq 0 ]]; then
  echo "[cleanup] no rewards-related process found"
  exit 0
fi

echo "[cleanup] TERM => ${PIDS[*]}"
for p in "${PIDS[@]}"; do
  [[ "$p" == "$SELF_PID" || "$p" == "$PARENT_PID" ]] && continue
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[cleanup] DRY_RUN kill $p"
  else
    kill "$p" 2>/dev/null || true
  fi
done

sleep 3

mapfile -t LEFT < <(collect_pids | sort -u)
if [[ ${#LEFT[@]} -gt 0 ]]; then
  echo "[cleanup] KILL => ${LEFT[*]}"
  for p in "${LEFT[@]}"; do
    [[ "$p" == "$SELF_PID" || "$p" == "$PARENT_PID" ]] && continue
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[cleanup] DRY_RUN kill -9 $p"
    else
      kill -9 "$p" 2>/dev/null || true
    fi
  done
fi

echo "[cleanup] done"
