#!/usr/bin/env bash
# After maintenance confirm, wait for DB/data conversion to finish.
# Success = maintenance page gone AND /app/rest/server version == TARGET_TC_VERSION.
# Conversion can take a long time — default timeout 90 minutes (override 60–120+).
#
# Required:
#   TEAMCITY_BASE_URL
#   TARGET_TC_VERSION
# Optional:
#   POLL_INTERVAL_SEC   default 30
#   POLL_TIMEOUT_SEC    default 5400 (90 min)
#   CURL_CONNECT_TIMEOUT / CURL_MAX_TIME
set -euo pipefail

TEAMCITY_BASE_URL="${TEAMCITY_BASE_URL:?TEAMCITY_BASE_URL is required}"
TARGET_TC_VERSION="${TARGET_TC_VERSION:?TARGET_TC_VERSION is required}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-30}"
POLL_TIMEOUT_SEC="${POLL_TIMEOUT_SEC:-5400}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"

BASE="${TEAMCITY_BASE_URL%/}"
START_TS="$(date +%s)"
DEADLINE=$((START_TS + POLL_TIMEOUT_SEC))

log() { printf '[%s] wait-db-upgrade: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

is_maintenance_html() {
  echo "$1" | grep -qiE \
    'maintenance|Super user authentication|confirm.*(upgrade|data)|Data directory upgrade|Upgrade in progress'
}

maintenance_present() {
  local html=""
  for path in "/" "/mnt" "/maintenance"; do
    html="$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -L "${BASE}${path}" 2>/dev/null || true)"
    if [[ -n "$html" ]] && is_maintenance_html "$html"; then
      return 0
    fi
  done
  return 1
}

rest_version() {
  local json v
  json="$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    -H 'Accept: application/json' "${BASE}/app/rest/server" 2>/dev/null)" || return 1
  v="$(echo "$json" | jq -r '.versionDisplayName // .version // empty' 2>/dev/null || true)"
  [[ -n "$v" ]] || return 1
  echo "$v"
}

version_matches() {
  local observed="$1"
  [[ "$observed" == "$TARGET_TC_VERSION" || "$observed" == "${TARGET_TC_VERSION}"* || "$observed" == *"${TARGET_TC_VERSION}"* ]]
}

log "base=${BASE} target=${TARGET_TC_VERSION} timeout=${POLL_TIMEOUT_SEC}s (~$((POLL_TIMEOUT_SEC / 60)) min)"

while true; do
  NOW="$(date +%s)"
  if (( NOW > DEADLINE )); then
    log "ERROR: timed out after ${POLL_TIMEOUT_SEC}s waiting for DB conversion + target version"
    log "NOTE: downgrade after conversion is not possible without RDS/EFS restore from pre-upgrade snapshot"
    exit 1
  fi

  MAINT=0
  if maintenance_present; then
    MAINT=1
    log "maintenance page still present (conversion in progress?)"
  fi

  OBSERVED=""
  if OBSERVED="$(rest_version 2>/dev/null || true)"; then
    log "REST version observed=${OBSERVED}"
  else
    log "REST /app/rest/server not available yet"
  fi

  if [[ "$MAINT" -eq 0 && -n "$OBSERVED" ]] && version_matches "$OBSERVED"; then
    ELAPSED=$((NOW - START_TS))
    log "SUCCESS: maintenance gone and version matches (${OBSERVED}) after ${ELAPSED}s"
    exit 0
  fi

  REMAIN=$((DEADLINE - NOW))
  log "waiting; sleep ${POLL_INTERVAL_SEC}s (${REMAIN}s left)"
  sleep "$POLL_INTERVAL_SEC"
done
