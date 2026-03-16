#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# check_validation.sh
#
# Step 2 of 2 — Polls the Dynatrace Automation execution started by
# trigger_validation.sh and reads the SRG Guardian validation result.
#
# Exit codes:
#   0  →  Validation PASSED  (no blocking vulnerabilities)
#   1  →  Validation FAILED  (critical/high vulnerabilities detected → block!)
#
# Required env vars:
#   DT_CLIENT_ID      OAuth2 client ID
#   DT_CLIENT_SECRET  OAuth2 client secret
#   DT_TENANT_URL     e.g. https://fov31014.apps.dynatrace.com
#
# Optional:
#   MAX_WAIT_TIME     seconds before timeout (default: 300)
#   POLL_INTERVAL     polling interval in seconds (default: 15)
# ──────────────────────────────────────────────────────────────────────────────

set +e

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
AUTH_URL="https://sso.dynatrace.com/sso/oauth2/token"
OAUTH_SCOPE="automation:workflows:read"
DT_TENANT_URL="${DT_TENANT_URL:-https://fov31014.apps.dynatrace.com}"
MAX_WAIT_TIME="${MAX_WAIT_TIME:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

# ── Validate required vars ────────────────────────────────────────────────────
if [ -z "$DT_CLIENT_ID" ] || [ -z "$DT_CLIENT_SECRET" ]; then
  echo -e "${RED}❌  Missing required environment variables${NC}"
  echo "Required: DT_CLIENT_ID, DT_CLIENT_SECRET"
  exit 1
fi

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Dynatrace Site Reliability Guardian — Security Validation   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Timeout:       ${MAX_WAIT_TIME}s ($(( MAX_WAIT_TIME / 60 )) min)"
echo -e "  Poll interval: ${POLL_INTERVAL}s"
echo ""

# ── Authenticate ──────────────────────────────────────────────────────────────
echo -e "${YELLOW}🔐 Authenticating...${NC}"

AUTH_FULL=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "$AUTH_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${DT_CLIENT_ID}&client_secret=${DT_CLIENT_SECRET}&scope=${OAUTH_SCOPE}")

AUTH_STATUS=$(echo "$AUTH_FULL" | grep "HTTP_STATUS:" | cut -d: -f2)
AUTH_BODY=$(echo "$AUTH_FULL" | grep -v "HTTP_STATUS:")

if [ "$AUTH_STATUS" -lt 200 ] || [ "$AUTH_STATUS" -ge 300 ]; then
  echo -e "${RED}❌  Authentication failed (HTTP $AUTH_STATUS)${NC}"
  exit 1
fi

TOKEN=$(echo "$AUTH_BODY" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo -e "${RED}❌  Could not extract access token${NC}"
  exit 1
fi

echo -e "${GREEN}✅ Authenticated${NC}"
echo ""

# ── Load execution ID ─────────────────────────────────────────────────────────
if [ ! -f /tmp/dynatrace_execution_id.txt ]; then
  echo -e "${RED}❌  No execution ID found at /tmp/dynatrace_execution_id.txt${NC}"
  echo "    Make sure trigger_validation.sh ran successfully first."
  exit 1
fi

EXECUTION_ID=$(cat /tmp/dynatrace_execution_id.txt)
echo -e "${BLUE}📋 Monitoring execution: ${EXECUTION_ID}${NC}"
echo ""

# ── Poll for completion ───────────────────────────────────────────────────────
echo -e "${YELLOW}⏳ Waiting for workflow to complete...${NC}"

ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT_TIME ]; do
  DETAIL=$(curl -s "${DT_TENANT_URL}/platform/automation/v1/executions/${EXECUTION_ID}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")

  STATE=$(echo "$DETAIL" | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)

  echo -e "   State: ${STATE}  (${ELAPSED}s elapsed)"

  if [ "$STATE" = "RUNNING" ]; then
    sleep "$POLL_INTERVAL"
    ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
    continue
  fi

  if [ "$STATE" = "ERROR" ] || [ "$STATE" = "FAILED" ]; then
    STATE_INFO=$(echo "$DETAIL" | grep -o '"stateInfo":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║          ❌  WORKFLOW EXECUTION FAILED               ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "${RED}   Error: ${STATE_INFO}${NC}"
    echo -e "${YELLOW}   Execution: ${DT_TENANT_URL}/ui/apps/dynatrace.automations/executions/${EXECUTION_ID}${NC}"
    exit 1
  fi

  if [ "$STATE" = "SUCCESS" ]; then
    break
  fi

  # Unknown state — keep waiting
  sleep "$POLL_INTERVAL"
  ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
done

if [ $ELAPSED -ge $MAX_WAIT_TIME ]; then
  echo -e "${RED}❌  Timeout reached after ${MAX_WAIT_TIME}s — treating as failure${NC}"
  exit 1
fi

# ── Read Guardian validation result from tasks ────────────────────────────────
echo ""
echo -e "${YELLOW}🔍 Reading Guardian validation result from workflow tasks...${NC}"

TASKS=$(curl -s "${DT_TENANT_URL}/platform/automation/v1/executions/${EXECUTION_ID}/tasks" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json")

echo "$TASKS" > /tmp/dynatrace_tasks_response.json

# validation_status can appear with or without a space after the colon
VALIDATION_STATUS=$(echo "$TASKS" | grep -o '"validation_status"[: ]*"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')
PASS_COUNT=$(echo "$TASKS"    | grep -o '"pass"[: ]*[0-9]*'    | head -1 | grep -o '[0-9]*$')
FAIL_COUNT=$(echo "$TASKS"    | grep -o '"fail"[: ]*[0-9]*'    | head -1 | grep -o '[0-9]*$')
WARNING_COUNT=$(echo "$TASKS" | grep -o '"warning"[: ]*[0-9]*' | head -1 | grep -o '[0-9]*$')
VALIDATION_ID=$(echo "$TASKS" | grep -o '"validation_id"[: ]*"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')

if [ -z "$VALIDATION_STATUS" ]; then
  echo -e "${RED}❌  Could not extract validation_status from tasks response.${NC}"
  echo "    Tasks JSON saved to /tmp/dynatrace_tasks_response.json"
  exit 1
fi

# ── Evaluate result ───────────────────────────────────────────────────────────
case "$VALIDATION_STATUS" in
  pass)
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅  SRG VALIDATION PASSED — Deployment is safe to proceed  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}  Objectives:  ${PASS_COUNT} passed  |  ${FAIL_COUNT:-0} failed  |  ${WARNING_COUNT:-0} warnings${NC}"
    echo -e "${BLUE}  Guardian:    ${DT_TENANT_URL}/ui/apps/dynatrace.site.reliability.guardian${NC}"
    echo -e "${BLUE}  Validation:  ${VALIDATION_ID}${NC}"
    exit 0
    ;;
  warning)
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠️   SRG VALIDATION WARNING — Review recommended            ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}  Objectives:  ${PASS_COUNT} passed  |  ${WARNING_COUNT} warnings${NC}"
    echo -e "${BLUE}  Guardian:    ${DT_TENANT_URL}/ui/apps/dynatrace.site.reliability.guardian${NC}"
    # Warnings do not fail the pipeline — only errors do
    exit 0
    ;;
  fail|error)
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ❌  SRG VALIDATION FAILED — DEPLOYMENT BLOCKED              ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${RED}  ⛔  Dynatrace Application Security detected vulnerabilities!${NC}"
    echo -e "${RED}  Objectives:  ${PASS_COUNT:-0} passed  |  ${FAIL_COUNT} failed  |  ${WARNING_COUNT:-0} warnings${NC}"
    echo ""
    echo -e "${YELLOW}  Review vulnerabilities:${NC}"
    echo "    ${DT_TENANT_URL}/ui/apps/dynatrace.classic.security.overview"
    echo ""
    echo -e "${YELLOW}  Guardian dashboard:${NC}"
    echo "    ${DT_TENANT_URL}/ui/apps/dynatrace.site.reliability.guardian"
    echo ""
    echo -e "${YELLOW}  Validation ID: ${VALIDATION_ID}${NC}"
    echo ""
    echo -e "${RED}  To fix: upgrade the vulnerable packages listed in app/package.json${NC}"
    echo -e "${RED}  See README.md → 'Fixing the vulnerabilities'${NC}"
    exit 1
    ;;
  *)
    echo -e "${RED}❌  Unknown validation status: '${VALIDATION_STATUS}'${NC}"
    echo "    Raw tasks JSON saved to /tmp/dynatrace_tasks_response.json"
    exit 1
    ;;
esac
