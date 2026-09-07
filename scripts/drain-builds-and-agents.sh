#!/usr/bin/env bash
# Pre-deploy drain: ensure NO TeamCity builds are running, then terminate/disable
# build agents so the server upgrade does not strand work or corrupt agent state.
#
# Patterns documented / supported:
#   A) TeamCity REST — poll running builds; optionally cancel; disable agents
#   B) AWS scale-in — set agent ECS service desiredCount=0 and/or ASG desired=0
#
# Required:
#   TEAMCITY_BASE_URL
# Optional auth (prefer token; never commit secrets — inject via SSM/Secrets Manager):
#   TEAMCITY_BEARER_TOKEN   Authorization: Bearer …
#   TEAMCITY_USER / TEAMCITY_PASSWORD   basic auth (discouraged)
# Drain behaviour:
#   DRAIN_TIMEOUT_SEC           default 1800
#   POLL_INTERVAL_SEC           default 20
#   CANCEL_RUNNING_BUILDS       default 0 (1 = POST cancel on each running build)
#   CANCEL_COMMENT              default "Pre-upgrade drain"
#   DISABLE_AGENTS_VIA_REST     default 1
#   AGENT_ECS_CLUSTER           if set with AGENT_ECS_SERVICE → scale service to 0
#   AGENT_ECS_SERVICE
#   AGENT_ASG_NAME              if set → autoscaling set-desired-capacity 0
#   SKIP_AGENT_SCALE_IN         default 0
#   ALLOW_EMPTY_AUTH            default 0 — set 1 only for open/guest REST in lab clones
#   CURL_CONNECT_TIMEOUT / CURL_MAX_TIME
set -euo pipefail

TEAMCITY_BASE_URL="${TEAMCITY_BASE_URL:?TEAMCITY_BASE_URL is required}"
DRAIN_TIMEOUT_SEC="${DRAIN_TIMEOUT_SEC:-1800}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-20}"
CANCEL_RUNNING_BUILDS="${CANCEL_RUNNING_BUILDS:-0}"
CANCEL_COMMENT="${CANCEL_COMMENT:-Pre-upgrade drain}"
DISABLE_AGENTS_VIA_REST="${DISABLE_AGENTS_VIA_REST:-1}"
AGENT_ECS_CLUSTER="${AGENT_ECS_CLUSTER:-}"
AGENT_ECS_SERVICE="${AGENT_ECS_SERVICE:-}"
AGENT_ASG_NAME="${AGENT_ASG_NAME:-}"
SKIP_AGENT_SCALE_IN="${SKIP_AGENT_SCALE_IN:-0}"
ALLOW_EMPTY_AUTH="${ALLOW_EMPTY_AUTH:-0}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
TEAMCITY_BEARER_TOKEN="${TEAMCITY_BEARER_TOKEN:-}"
TEAMCITY_USER="${TEAMCITY_USER:-}"
TEAMCITY_PASSWORD="${TEAMCITY_PASSWORD:-}"

BASE="${TEAMCITY_BASE_URL%/}"
START_TS="$(date +%s)"
DEADLINE=$((START_TS + DRAIN_TIMEOUT_SEC))

log() { printf '[%s] drain-builds-and-agents: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

auth_args() {
  if [[ -n "$TEAMCITY_BEARER_TOKEN" ]]; then
    printf '%s\n' -H "Authorization: Bearer ${TEAMCITY_BEARER_TOKEN}"
  elif [[ -n "$TEAMCITY_USER" ]]; then
    printf '%s\n' -u "${TEAMCITY_USER}:${TEAMCITY_PASSWORD}"
  elif [[ "$ALLOW_EMPTY_AUTH" == "1" ]]; then
    return 0
  else
    log "ERROR: set TEAMCITY_BEARER_TOKEN (or USER/PASSWORD), or ALLOW_EMPTY_AUTH=1 for lab only"
    return 1
  fi
}

tc_curl() {
  # shellcheck disable=SC2046
  curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    -H 'Accept: application/json' \
    $(auth_args) \
    "$@"
}

running_build_count() {
  local json count
  json="$(tc_curl "${BASE}/app/rest/builds?locator=running:true&fields=count,build(id,number,status,state,buildTypeId)" 2>/dev/null)" || return 1
  count="$(echo "$json" | jq -r '.count // (.build|length) // 0' 2>/dev/null || echo 0)"
  echo "$count"
  # stash ids for cancel
  echo "$json" | jq -r '.build[]?.id // empty' 2>/dev/null > /tmp/tc-running-build-ids.txt || true
}

cancel_running_builds() {
  local id
  [[ -f /tmp/tc-running-build-ids.txt ]] || return 0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    log "cancelling build id=${id}"
    # TeamCity REST: POST /app/rest/builds/id:<id> with comment, or use build cancel endpoint
    tc_curl -X POST \
      -H 'Content-Type: application/xml' \
      -d "<buildCancelRequest comment='${CANCEL_COMMENT}' readdIntoQueue='false' />" \
      "${BASE}/app/rest/builds/id:${id}" >/dev/null 2>&1 \
      || tc_curl -X POST \
           "${BASE}/app/rest/builds/id:${id}/cancel?comment=$(python3 -c "import urllib.parse;print(urllib.parse.quote('''${CANCEL_COMMENT}'''))" 2>/dev/null || echo Pre-upgrade)" \
           >/dev/null 2>&1 \
      || log "WARN: cancel may have failed for build ${id}"
  done < /tmp/tc-running-build-ids.txt
}

disable_agents_rest() {
  local json ids id
  log "disabling connected agents via REST"
  json="$(tc_curl "${BASE}/app/rest/agents?locator=connected:true&fields=agent(id,name,connected,enabled)" 2>/dev/null)" || {
    log "WARN: could not list agents via REST"
    return 0
  }
  echo "$json" | jq -r '.agent[]?.id // empty' 2>/dev/null > /tmp/tc-agent-ids.txt || true
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    log "disabling agent id=${id}"
    # PUT enabled=false
    tc_curl -X PUT -H 'Content-Type: text/plain' --data 'false' \
      "${BASE}/app/rest/agents/id:${id}/enabled" >/dev/null 2>&1 \
      || log "WARN: disable failed for agent ${id}"
  done < /tmp/tc-agent-ids.txt
}

scale_in_agent_compute() {
  if [[ "$SKIP_AGENT_SCALE_IN" == "1" ]]; then
    log "SKIP_AGENT_SCALE_IN=1 — not touching ECS/ASG"
    return 0
  fi
  if [[ -n "$AGENT_ECS_CLUSTER" && -n "$AGENT_ECS_SERVICE" ]]; then
    log "scaling agent ECS service ${AGENT_ECS_SERVICE} to desiredCount=0"
    local args=(ecs update-service --cluster "$AGENT_ECS_CLUSTER" --service "$AGENT_ECS_SERVICE" --desired-count 0)
    [[ -n "$AWS_REGION" ]] && args+=(--region "$AWS_REGION")
    aws "${args[@]}"
    aws ecs wait services-stable --cluster "$AGENT_ECS_CLUSTER" --services "$AGENT_ECS_SERVICE" ${AWS_REGION:+--region "$AWS_REGION"} 2>/dev/null \
      || log "WARN: wait services-stable timed out (agents may still be draining)"
  fi
  if [[ -n "$AGENT_ASG_NAME" ]]; then
    log "setting ASG ${AGENT_ASG_NAME} desired capacity to 0"
    local args=(autoscaling set-desired-capacity --auto-scaling-group-name "$AGENT_ASG_NAME" --desired-capacity 0)
    [[ -n "$AWS_REGION" ]] && args+=(--region "$AWS_REGION")
    aws "${args[@]}"
  fi
  if [[ -z "$AGENT_ECS_CLUSTER$AGENT_ECS_SERVICE$AGENT_ASG_NAME" ]]; then
    log "no AGENT_ECS_* / AGENT_ASG_NAME set — agent compute scale-in skipped (REST disable only if enabled)"
  fi
}

# --- main ---
log "base=${BASE} timeout=${DRAIN_TIMEOUT_SEC}s cancel_builds=${CANCEL_RUNNING_BUILDS}"

# Auth check early
auth_args >/dev/null

log "polling until running builds == 0"
while true; do
  NOW="$(date +%s)"
  if (( NOW > DEADLINE )); then
    log "ERROR: timed out after ${DRAIN_TIMEOUT_SEC}s with builds still running"
    exit 1
  fi
  COUNT="$(running_build_count || echo -1)"
  if [[ "$COUNT" == "-1" ]]; then
    log "WARN: could not query running builds (server down or auth?); retrying"
    sleep "$POLL_INTERVAL_SEC"
    continue
  fi
  log "running builds=${COUNT}"
  if [[ "$COUNT" == "0" ]]; then
    break
  fi
  if [[ "$CANCEL_RUNNING_BUILDS" == "1" ]]; then
    cancel_running_builds
  else
    log "waiting for builds to finish (set CANCEL_RUNNING_BUILDS=1 to force cancel)"
  fi
  sleep "$POLL_INTERVAL_SEC"
done

if [[ "$DISABLE_AGENTS_VIA_REST" == "1" ]]; then
  disable_agents_rest
fi

scale_in_agent_compute

log "SUCCESS: no running builds; agents disabled/scaled in as configured"
