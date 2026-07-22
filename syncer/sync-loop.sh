#!/bin/sh
# Continuous notification-safe sync loop. Interval via SYNC_INTERVAL (sec, default 120).
: "${SYNC_INTERVAL:=120}"
echo "sync-loop: interval ${SYNC_INTERVAL}s"
while true; do
  echo "[$(date -u +%FT%TZ)] sync"
  python /app/sync.py 2>&1 || echo "  sync failed, will retry next tick"
  sleep "$SYNC_INTERVAL"
done
