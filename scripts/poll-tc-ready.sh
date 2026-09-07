#!/usr/bin/env bash
# Poll TeamCity until either the Maintenance page is up OR /app/rest/server
# reports TARGET_TC_VERSION. Env-driven; no secrets.
#
# Required:
#   TEAMCITY_BASE_URL   e.g. https://teamcity.example.com
#   TARGET_TC_VERSION   e.g. 2025.07.3  (compared against JSON .version / .versionDisplayName)
# Optional:
#   POLL_INTERVAL_SEC   default 15
#   POLL_TIMEOUT_SEC    default 1800 (30 min) — short boot / maintenance detect window
#   ACCEPT_MAINTENANCE  default 1 — if 1, exit 0 when maintenance page detected
#   REQUIRE_VERSION     default 0 — if 1, only succeed when REST version matches (ignore maint)
#   CURL_CONNECT_TIMEOUT default 5
#   CURL_MAX_TIME        default 20
set -euo pipefail

TEAMCITY_BASE_URL="${TEAMCITY_BASE_URL:?TEAMCITY_BASE_URL is required}"
TARGET_TC_VERSION="${TARGET_TC_VERSION:?TARGET_TC_VERSION is required}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-15}"
POLL_TIMEOUT_SEC="${POLL_TIMEOUT_SEC:-1800}"
ACCEPT_MAINTENANCE="${ACCEPT_MAINTENANCE:-1}"
REQUIRE_VERSION="${REQUIRE_VERSION:-0}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-20}"

BASE="${TEAMCITY_BASE_URL%/}"
START_TS="$(date +%s)"
DEADLINE=$((START_TS + POLL_TIMEOUT_SEC))

log() { printf '[%s] poll-tc-ready: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

is_maintenance_html() {
  local body="$1"
  # JetBrains maintenance / upgrade gate heuristics (page title + copy)
  echo "$body" | grep -qiE \
    'maintenance|Super user authentication|confirm.*(upgrade|data)|TeamCity is starting|Data directory upgrade|Upgrade in progress' \
    && return 0
  return 1
}

rest_version() {
  local json
  if ! json="$(curl -fsS \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -H 'Accept: application/json' \
      "${BASE}/app/rest/server" 2>/dev/null)"; then
    return 1
  fi
  # Prefer versionDisplayName, fall back to version
  local v
  v="$(echo "$json" | jq -r '.versionDisplayName // .version // empty' 2>/dev/null || true)"
  if [[ -z "$v" ]]; then
    return 1
  fi
  echo "$v"
}

version_matches() {
  local observed="$1"
  # Exact match or observed starts with target / contains target as version token
  [[ "$observed" == "$TARGET_TC_VERSION" ]] && return 0
  [[ "$observed" == "${TARGET_TC_VERSION}"* ]] && return 0
  # Sometimes REST returns "2025.07.3 (build 12345)"
  [[ "$observed" == *"${TARGET_TC_VERSION}"* ]] && return 0
  return 1
}

log "base=${BASE} target=${TARGET_TC_VERSION} timeout=${POLL_TIMEOUT_SEC}s interval=${POLL_INTERVAL_SEC}s accept_maintenance=${ACCEPT_MAINTENANCE} require_version=${REQUIRE_VERSION}"

while true; do
  NOW="$(date +%s)"
  if (( NOW > DEADLINE )); then
    log "ERROR: timed out after ${POLL_TIMEOUT_SEC}s waiting for maintenance page or version ${TARGET_TC_VERSION}"
    exit 1
  fi

  # 1) Try REST server endpoint (works when TC is fully up)
  if OBSERVED="$(rest_version)"; then
    log "REST version observed=${OBSERVED}"
    if version_matches "$OBSERVED"; then
      log "SUCCESS: target version matched (${OBSERVED})"
      exit 0
    fi
    if [[ "$REQUIRE_VERSION" == "1" ]]; then
      log "version present but not target yet; continuing"
    fi
  else
    log "REST /app/rest/server not ready yet"
  fi

  # 2) Probe HTML root / maintenance for upgrade gate
  if [[ "$REQUIRE_VERSION" != "1" && "$ACCEPT_MAINTENANCE" == "1" ]]; then
    HTML=""
    HTML="$(curl -fsS \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -L "${BASE}/" 2>/dev/null || true)"
    # Also try known maintenance paths
    if [[ -z "$HTML" ]] || ! is_maintenance_html "$HTML"; then
      HTML="$(curl -fsS \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_MAX_TIME" \
        -L "${BASE}/mnt" 2>/dev/null || true)"
    fi
    if [[ -n "$HTML" ]] && is_maintenance_html "$HTML"; then
      log "SUCCESS: maintenance / upgrade page detected"
      exit 0
    fi
  fi

  REMAIN=$((DEADLINE - NOW))
  log "not ready; sleeping ${POLL_INTERVAL_SEC}s (${REMAIN}s left)"
  sleep "$POLL_INTERVAL_SEC"
done
