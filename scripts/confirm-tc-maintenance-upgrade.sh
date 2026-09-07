#!/usr/bin/env bash
# Confirm TeamCity major-upgrade Maintenance Mode via the UI form.
# JetBrains facts encoded here:
#   - Docker/ECS cannot use TeamCity "Automatic Update"
#   - On a major jump the new container starts in Maintenance Mode
#   - Confirm requires the Super user / maintenance authentication token
#     printed in teamcity-server.log
#   - There is NO official REST API to confirm — autonomy = read token from
#     logs (CloudWatch / optional ECS Exec / EFS path) + HTTP POST the form
#   - Same privilege class as host/log access (which ECS + CloudWatch give
#     the upgrade role)
#
# Required:
#   TEAMCITY_BASE_URL
# Optional:
#   LOG_GROUP                 CloudWatch log group for the TC server container
#   LOG_STREAM_PREFIX         optional filter for FilterLogEvents
#   LOG_LOOKBACK_MINUTES      default 120
#   TC_SERVER_LOG_PATH        optional local/EFS path to teamcity-server.log
#   ECS_CLUSTER / ECS_TASK_ARN / ECS_CONTAINER  optional ECS Exec fallback
#   POLL_INTERVAL_SEC         default 15
#   MAINTENANCE_WAIT_SEC      default 1800 — wait for maintenance page before token fetch
#   CURL_CONNECT_TIMEOUT / CURL_MAX_TIME
#   SKIP_IF_ALREADY_READY     default 1 — exit 0 if REST already reports TARGET_TC_VERSION
#   TARGET_TC_VERSION         used with SKIP_IF_ALREADY_READY
set -euo pipefail

TEAMCITY_BASE_URL="${TEAMCITY_BASE_URL:?TEAMCITY_BASE_URL is required}"
LOG_GROUP="${LOG_GROUP:-}"
LOG_STREAM_PREFIX="${LOG_STREAM_PREFIX:-}"
LOG_LOOKBACK_MINUTES="${LOG_LOOKBACK_MINUTES:-120}"
TC_SERVER_LOG_PATH="${TC_SERVER_LOG_PATH:-}"
ECS_CLUSTER="${ECS_CLUSTER:-}"
ECS_TASK_ARN="${ECS_TASK_ARN:-}"
ECS_CONTAINER="${ECS_CONTAINER:-teamcity-server}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-15}"
MAINTENANCE_WAIT_SEC="${MAINTENANCE_WAIT_SEC:-1800}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
SKIP_IF_ALREADY_READY="${SKIP_IF_ALREADY_READY:-1}"
TARGET_TC_VERSION="${TARGET_TC_VERSION:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

BASE="${TEAMCITY_BASE_URL%/}"
START_TS="$(date +%s)"
DEADLINE=$((START_TS + MAINTENANCE_WAIT_SEC))

log() { printf '[%s] confirm-tc-maintenance: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

curl_get() {
  curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -L "$@"
}

is_maintenance_html() {
  echo "$1" | grep -qiE \
    'maintenance|Super user authentication|confirm.*(upgrade|data)|Data directory upgrade|Upgrade in progress|authenticationToken|superuser'
}

rest_version() {
  local json v
  json="$(curl_get -H 'Accept: application/json' "${BASE}/app/rest/server" 2>/dev/null)" || return 1
  v="$(echo "$json" | jq -r '.versionDisplayName // .version // empty' 2>/dev/null || true)"
  [[ -n "$v" ]] || return 1
  echo "$v"
}

version_matches() {
  local observed="$1"
  [[ -z "$TARGET_TC_VERSION" ]] && return 1
  [[ "$observed" == "$TARGET_TC_VERSION" || "$observed" == "${TARGET_TC_VERSION}"* || "$observed" == *"${TARGET_TC_VERSION}"* ]]
}

fetch_maintenance_html() {
  local html=""
  for path in "/" "/mnt" "/maintainance" "/maintenance"; do
    html="$(curl_get "${BASE}${path}" 2>/dev/null || true)"
    if [[ -n "$html" ]] && is_maintenance_html "$html"; then
      echo "$html"
      return 0
    fi
  done
  return 1
}

extract_token_from_text() {
  # Common JetBrains log lines:
  #   Super user authentication token: XXXX-XXXX-XXXX-XXXX
  #   Super user authentication token: <token>
  #   "authentication token" ...
  local text="$1"
  local token=""
  token="$(echo "$text" | grep -oiE 'Super user authentication token[: ]+[A-Za-z0-9._-]{8,}' \
    | sed -E 's/.*[Tt]oken[: ]+//' | tr -d '[:space:]' | tail -n1 || true)"
  if [[ -z "$token" ]]; then
    token="$(echo "$text" | grep -oiE 'authentication token[: ]+[A-Za-z0-9._-]{8,}' \
      | sed -E 's/.*[Tt]oken[: ]+//' | tr -d '[:space:]' | tail -n1 || true)"
  fi
  if [[ -z "$token" ]]; then
    # UUID-ish tokens sometimes logged alone after the label on next line
    token="$(echo "$text" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
      | tail -n1 || true)"
  fi
  [[ -n "$token" ]] || return 1
  echo "$token"
}

fetch_token_cloudwatch() {
  [[ -n "$LOG_GROUP" ]] || return 1
  command -v aws >/dev/null || return 1
  local start_ms end_ms raw
  end_ms=$(($(date +%s) * 1000))
  start_ms=$((end_ms - LOG_LOOKBACK_MINUTES * 60 * 1000))
  log "filter-log-events group=${LOG_GROUP} lookback=${LOG_LOOKBACK_MINUTES}m"
  local args=(
    logs filter-log-events
    --log-group-name "$LOG_GROUP"
    --start-time "$start_ms"
    --end-time "$end_ms"
    --filter-pattern "Super user authentication token"
    --output json
  )
  if [[ -n "$AWS_REGION" ]]; then
    args+=(--region "$AWS_REGION")
  fi
  if [[ -n "$LOG_STREAM_PREFIX" ]]; then
    args+=(--log-stream-name-prefix "$LOG_STREAM_PREFIX")
  fi
  raw="$(aws "${args[@]}" 2>/dev/null || true)"
  if [[ -z "$raw" || "$raw" == "null" ]]; then
    # Broader pattern
    args=(
      logs filter-log-events
      --log-group-name "$LOG_GROUP"
      --start-time "$start_ms"
      --end-time "$end_ms"
      --filter-pattern "authentication token"
      --output json
    )
    [[ -n "$AWS_REGION" ]] && args+=(--region "$AWS_REGION")
    [[ -n "$LOG_STREAM_PREFIX" ]] && args+=(--log-stream-name-prefix "$LOG_STREAM_PREFIX")
    raw="$(aws "${args[@]}" 2>/dev/null || true)"
  fi
  local messages
  messages="$(echo "$raw" | jq -r '.events[]?.message // empty' 2>/dev/null || true)"
  [[ -n "$messages" ]] || return 1
  extract_token_from_text "$messages"
}

fetch_token_logfile() {
  [[ -n "$TC_SERVER_LOG_PATH" && -r "$TC_SERVER_LOG_PATH" ]] || return 1
  log "reading token from log file ${TC_SERVER_LOG_PATH}"
  # Prefer last matching lines
  local chunk
  chunk="$(grep -iE 'Super user authentication token|authentication token' "$TC_SERVER_LOG_PATH" | tail -n 20 || true)"
  [[ -n "$chunk" ]] || chunk="$(tail -n 500 "$TC_SERVER_LOG_PATH" || true)"
  extract_token_from_text "$chunk"
}

fetch_token_ecs_exec() {
  [[ -n "$ECS_CLUSTER" && -n "$ECS_TASK_ARN" ]] || return 1
  command -v aws >/dev/null || return 1
  log "ECS Exec fallback cluster=${ECS_CLUSTER} task=${ECS_TASK_ARN} container=${ECS_CONTAINER}"
  # Non-interactive: run a one-shot command if execute-command is enabled
  local out
  out="$(aws ecs execute-command \
    --cluster "$ECS_CLUSTER" \
    --task "$ECS_TASK_ARN" \
    --container "$ECS_CONTAINER" \
    --interactive \
    --command "grep -iE 'Super user authentication token|authentication token' /opt/teamcity/logs/teamcity-server.log | tail -n 5" \
    2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  extract_token_from_text "$out"
}

# Parse maintenance HTML: find token input name + upgrade form action.
# Form field names vary by TC version — resilient parse; fail clearly if unknown.
parse_and_post_confirm() {
  local html="$1"
  local token="$2"
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$html" >"$tmp"

  # Find likely token input: name containing token / authentication / superuser
  local input_name=""
  input_name="$(grep -oiE '<input[^>]+>' "$tmp" | grep -iE 'token|authentication|superuser|password' \
    | grep -oiE 'name="[^"]+"' | head -n1 | sed -E 's/name="([^"]+)"/\1/' || true)"
  if [[ -z "$input_name" ]]; then
    # Fallback common JetBrains names observed across versions
    for candidate in authenticationToken superuserToken token authToken password; do
      if grep -qiE "name=[\"']${candidate}[\"']" "$tmp"; then
        input_name="$candidate"
        break
      fi
    done
  fi

  # Form action URL
  local form_action=""
  form_action="$(grep -oiE '<form[^>]+>' "$tmp" | head -n1 | grep -oiE 'action="[^"]*"' \
    | sed -E 's/action="([^"]*)"/\1/' || true)"
  if [[ -z "$form_action" || "$form_action" == "#" ]]; then
    form_action="/"
  fi
  case "$form_action" in
    http*|HTTP*) ;;
    /*) form_action="${BASE}${form_action}" ;;
    *) form_action="${BASE}/${form_action}" ;;
  esac

  # Upgrade submit control: button/input name+value for upgrade / confirm
  local submit_name="" submit_value=""
  local submit_line=""
  submit_line="$(grep -oiE '<(input|button)[^>]+>' "$tmp" | grep -iE 'upgrade|confirm|submit' | head -n1 || true)"
  if [[ -n "$submit_line" ]]; then
    submit_name="$(echo "$submit_line" | grep -oiE 'name="[^"]+"' | head -n1 | sed -E 's/name="([^"]+)"/\1/' || true)"
    submit_value="$(echo "$submit_line" | grep -oiE 'value="[^"]+"' | head -n1 | sed -E 's/value="([^"]+)"/\1/' || true)"
  fi
  # Hidden inputs (csrf etc.) — collect name=value pairs excluding token field
  local -a extra_fields=()
  while IFS= read -r line; do
    local n v
    n="$(echo "$line" | grep -oiE 'name="[^"]+"' | head -n1 | sed -E 's/name="([^"]+)"/\1/' || true)"
    v="$(echo "$line" | grep -oiE 'value="[^"]*"' | head -n1 | sed -E 's/value="([^"]*)"/\1/' || true)"
    [[ -n "$n" ]] || continue
    [[ "$n" == "$input_name" ]] && continue
    extra_fields+=(--data-urlencode "${n}=${v}")
  done < <(grep -oiE '<input[^>]*type="hidden"[^>]*>' "$tmp" || true)

  rm -f "$tmp"

  if [[ -z "$input_name" ]]; then
    log "ERROR: could not discover maintenance form token input name from HTML."
    log "HINT: capture the maintenance page once against your TC version and map field names."
    log "      Re-run with a saved HTML dump or extend parsing for your build."
    return 2
  fi

  log "POSTing confirm to ${form_action} (token field=${input_name})"
  local -a curl_args=(
    -sS -L
    --connect-timeout "$CURL_CONNECT_TIMEOUT"
    --max-time "$CURL_MAX_TIME"
    -X POST
    --data-urlencode "${input_name}=${token}"
  )
  if [[ -n "$submit_name" ]]; then
    curl_args+=(--data-urlencode "${submit_name}=${submit_value:-Upgrade}")
  else
    # Common action field fallbacks
    curl_args+=(--data-urlencode "upgrade=Upgrade")
  fi
  curl_args+=("${extra_fields[@]}")
  curl_args+=("$form_action")

  local resp_code
  resp_code="$(curl "${curl_args[@]}" -o /tmp/tc-maint-post-body.txt -w '%{http_code}' || true)"
  log "POST HTTP status=${resp_code}"
  if [[ "$resp_code" =~ ^2|^3 ]]; then
    log "confirm submitted successfully (HTTP ${resp_code})"
    return 0
  fi
  log "ERROR: confirm POST failed (HTTP ${resp_code}). Body (first 500 chars):"
  head -c 500 /tmp/tc-maint-post-body.txt 2>/dev/null || true
  echo
  return 1
}

# --- main ---
log "base=${BASE}"

if [[ "$SKIP_IF_ALREADY_READY" == "1" && -n "$TARGET_TC_VERSION" ]]; then
  if OBSERVED="$(rest_version 2>/dev/null || true)"; then
    if version_matches "$OBSERVED"; then
      log "already at target version (${OBSERVED}) — skip confirm"
      exit 0
    fi
  fi
fi

log "waiting up to ${MAINTENANCE_WAIT_SEC}s for maintenance page"
MAINT_HTML=""
while true; do
  NOW="$(date +%s)"
  if (( NOW > DEADLINE )); then
    # If we somehow became ready without maintenance, treat as success
    if [[ -n "$TARGET_TC_VERSION" ]] && OBSERVED="$(rest_version 2>/dev/null || true)"; then
      if version_matches "$OBSERVED"; then
        log "reached target without maintenance page — skip confirm"
        exit 0
      fi
    fi
    log "ERROR: timed out waiting for maintenance page"
    exit 1
  fi
  if MAINT_HTML="$(fetch_maintenance_html)"; then
    log "maintenance page detected"
    break
  fi
  # Ready path mid-wait
  if [[ "$SKIP_IF_ALREADY_READY" == "1" && -n "$TARGET_TC_VERSION" ]]; then
    if OBSERVED="$(rest_version 2>/dev/null || true)"; then
      if version_matches "$OBSERVED"; then
        log "already at target version (${OBSERVED}) — skip confirm"
        exit 0
      fi
    fi
  fi
  sleep "$POLL_INTERVAL_SEC"
done

TOKEN=""
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if TOKEN="$(fetch_token_cloudwatch 2>/dev/null || true)"; then
    [[ -n "$TOKEN" ]] && break
  fi
  if TOKEN="$(fetch_token_logfile 2>/dev/null || true)"; then
    [[ -n "$TOKEN" ]] && break
  fi
  if TOKEN="$(fetch_token_ecs_exec 2>/dev/null || true)"; then
    [[ -n "$TOKEN" ]] && break
  fi
  log "token not found yet (attempt ${attempt}/10); sleeping ${POLL_INTERVAL_SEC}s"
  sleep "$POLL_INTERVAL_SEC"
  # Refresh HTML in case form changed
  MAINT_HTML="$(fetch_maintenance_html || echo "$MAINT_HTML")"
done

if [[ -z "$TOKEN" ]]; then
  log "ERROR: could not extract Super user / maintenance authentication token."
  log "Checked: CloudWatch LOG_GROUP=${LOG_GROUP:-<unset>}, TC_SERVER_LOG_PATH=${TC_SERVER_LOG_PATH:-<unset>}, ECS Exec=${ECS_CLUSTER:-<unset>}"
  log "Ensure server logs are shipped to CloudWatch and filter-log-events is permitted."
  exit 1
fi

# Never print the full token
TOKEN_LEN="${#TOKEN}"
log "token acquired (length=${TOKEN_LEN}); submitting confirm form"
parse_and_post_confirm "$MAINT_HTML" "$TOKEN"
log "done — follow with wait-db-upgrade.sh / poll-tc-ready.sh"
