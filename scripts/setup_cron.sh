#!/usr/bin/env bash

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CRON_SCHEDULE="0 2 * * *"
CRON_CMD="bash $PIPELINE_DIR/scripts/pipeline.sh >> $PIPELINE_DIR/logs/cron_\$(date +\\%Y\\%m\\%d).log 2>&1"
CRON_ENTRY="$CRON_SCHEDULE $CRON_CMD"

if crontab -l 2>/dev/null | grep -qF "$PIPELINE_DIR/scripts/pipeline.sh"; then
    echo "[INFO] Cron job already registered for pipeline.sh"
    exit 0
fi

(crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
echo "[INFO] Cron job registered: runs daily at 02:00"
echo "       Entry: $CRON_ENTRY"
crontab -l | grep "$PIPELINE_DIR"
