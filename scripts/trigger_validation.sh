#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# trigger_validation.sh
#
# Step 1 of 2 — Triggers the Dynatrace Automation Workflow that runs the
# SRG Guardian validation. Saves the execution ID for check_validation.sh.
#
# Required env vars:
#   DT_CLIENT_ID      OAuth2 client ID
#   DT_CLIENT_SECRET  OAuth2 client secret
#   DT_TENANT_URL     e.g. https://fov31014.apps.dynatrace.com
#   DT_WORKFLOW_ID    Automation Workflow ID (from setup_dynatrace.sh)
#
# Optional:
#   SERVICE_NAME      defaults to "srg-vulnerable-app"
#   BUILD_VERSION     defaults to "unknown"
#   GIT_COMMIT        short commit SHA
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
OAUTH_SCOPE="automation:workflows:run"
DT_TENANT_URL="${DT_TENANT_URL:-https://fov31014.apps.dynatrace.com}"
SERVICE_NAME="${SERVICE_NAME:-srg-vulnerable-app}"
BUILD_VERSION="${BUILD_VERSION:-unknown}"
GIT_COMMIT="${GIT_COMMIT:-unknown}"

# ── Validate required vars ────────────────────────────────────────────────────
if [ -z "$DT_CLIENT_ID" ] || [ -z "$DT_CLIENT_SECRET" ] || [ -z "$DT_WORKFLOW_ID" ]; then
  echo -e "${RED}❌  Missing required environment variables${NC}"
  echo "Required: DT_CLIENT_ID, DT_CLIENT_SECRET, DT_WORKFLOW_ID"
  exit 1
fi

echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Dynatrace SRG — Trigger Validation                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Service:  ${SERVICE_NAME}"
echo -e "  Build:    ${BUILD_VERSION}"
echo -e "  Commit:   ${GIT_COMMIT}"
echo -e "  Workflow: ${DT_WORKFLOW_ID}"
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
  echo "Response: $AUTH_BODY"
  exit 1
fi

TOKEN=$(echo "$AUTH_BODY" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo -e "${RED}❌  Could not extract access token${NC}"
  exit 1
fi

echo -e "${GREEN}✅ Authenticated${NC}"
echo ""

# ── Trigger Workflow ─────────────────────────────────────────────────────────
echo -e "${YELLOW}🚀 Triggering SRG validation workflow...${NC}"

PAYLOAD=$(cat <<EOF
{
  "params": {
    "service":        "${SERVICE_NAME}",
    "build_version":  "${BUILD_VERSION}",
    "git_commit":     "${GIT_COMMIT}",
    "triggered_by":   "github_actions",
    "timeframe": {
      "from": "now()-1h",
      "to": "now()"
    }
  }
}
EOF
)

WORKFLOW_URL="${DT_TENANT_URL}/platform/automation/v1/workflows/${DT_WORKFLOW_ID}/run"

TRIGGER_FULL=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "$WORKFLOW_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

HTTP_STATUS=$(echo "$TRIGGER_FULL" | grep "HTTP_STATUS:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$TRIGGER_FULL" | grep -v "HTTP_STATUS:")

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
  echo -e "[debug] trigger raw response: $(echo \"$RESPONSE_BODY\" | head -c 500)"
  EXECUTION_ID=$(echo "$RESPONSE_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('executionId',''))" 2>/dev/null || echo "")
  echo -e "${GREEN}✅ Workflow triggered — Execution ID: ${EXECUTION_ID}${NC}"
  echo "$EXECUTION_ID" > /tmp/dynatrace_execution_id.txt
  echo ""
  echo -e "${BLUE}Monitor at:${NC}"
  echo "  ${DT_TENANT_URL}/ui/apps/dynatrace.automations/workflows/${DT_WORKFLOW_ID}"
  exit 0
else
  echo -e "${RED}❌  Failed to trigger workflow (HTTP $HTTP_STATUS)${NC}"
  echo "Response: $RESPONSE_BODY"
  exit 1
fi
