#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/Users/kenny/clawd/zidong/Microsoft-Rewards-Script"
cd "$REPO_DIR"

# Randomize start within 16:15–17:00 window.
# launchd triggers at 16:15; we delay 0–2700 seconds (45 minutes).
delay=$(( RANDOM % 2701 ))
echo "[launchd] $(date '+%F %T') random delay ${delay}s (window 16:15–17:00)"
sleep "$delay"

echo "[launchd] $(date '+%F %T') starting rewards run"
REPO_DIR="$REPO_DIR" MODE=start_only bash ./scripts/run_with_notify.sh
