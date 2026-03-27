#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# setup_dynatrace.sh
#
# Creates the SRG Guardian and Automation Workflow in your Dynatrace tenant.
# Idempotent — safe to run multiple times. Reuses existing resources if found.
#
# Prerequisites:
#   - Dynatrace OAuth2 client with the following scopes:
#       automation:workflows:read
#       automation:workflows:write
#       automation:workflows:run
#       srg:guardians:read
#       srg:guardians:write
#       security:findings:read
#
#   Create the OAuth client at:
#   https://fov31014.apps.dynatrace.com/ui/apps/dynatrace.classic.settings/settings/oauth-client-management
#
# Usage:
#   cp .env.example .env      # fill in DT_CLIENT_ID, DT_CLIENT_SECRET
#   chmod +x scripts/setup_dynatrace.sh
#   ./scripts/setup_dynatrace.sh
# ──────────────────────────────────────────────────────────────────────────────

set -e

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Load .env ─────────────────────────────────────────────────────────────────
if [ -f .env ]; then
  while IFS='=' read -r key value; do
    if [ -n "$key" ] && [[ ! "$key" =~ ^# ]]; then
      export "$key=$value"
    fi
  done < .env
fi

DT_TENANT_URL="${DT_TENANT_URL:-https://fov31014.apps.dynatrace.com}"
AUTH_URL="https://sso.dynatrace.com/sso/oauth2/token"
OAUTH_SCOPE="automation:workflows:read automation:workflows:write automation:workflows:run srg:guardians:read srg:guardians:write security:findings:read"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Dynatrace SRG Security Gate — Initial Setup               ║${NC}"
echo -e "${BLUE}║   Tenant: ${DT_TENANT_URL}  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Validate env vars ─────────────────────────────────────────────────────────
if [ -z "$DT_CLIENT_ID" ] || [ -z "$DT_CLIENT_SECRET" ]; then
  echo -e "${RED}❌  Missing required environment variables.${NC}"
  echo ""
  echo "  DT_CLIENT_ID     = ${DT_CLIENT_ID:-<not set>}"
  echo "  DT_CLIENT_SECRET = ${DT_CLIENT_SECRET:+<set>}${DT_CLIENT_SECRET:-<not set>}"
  echo ""
  echo "How to create an OAuth client:"
  echo "  1. Open ${DT_TENANT_URL}/ui/apps/dynatrace.classic.settings/settings/oauth-client-management"
  echo "  2. Click 'Create client'"
  echo "  3. Name: srg-security-gate"
  echo "  4. Scopes: $OAUTH_SCOPE"
  echo "  5. Copy Client ID and Secret into your .env file"
  echo ""
  exit 1
fi

# ── Authenticate ──────────────────────────────────────────────────────────────
echo -e "${YELLOW}🔐 Authenticating with Dynatrace OAuth2...${NC}"

AUTH_RESPONSE=$(curl -s -X POST "$AUTH_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${DT_CLIENT_ID}&client_secret=${DT_CLIENT_SECRET}&scope=${OAUTH_SCOPE// /%20}")

TOKEN=$(echo "$AUTH_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo -e "${RED}❌  Authentication failed.${NC}"
  echo "Response: $AUTH_RESPONSE"
  exit 1
fi

echo -e "${GREEN}✅ Authenticated${NC}"
echo ""

# ── Check / Create SRG Guardian ───────────────────────────────────────────────
GUARDIAN_NAME=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' dynatrace/guardian.json | head -1 | cut -d'"' -f4)
echo -e "${YELLOW}🛡️  Verificando Guardian existente: ${GUARDIAN_NAME}...${NC}"

GUARDIANS_LIST=$(curl -s "${DT_TENANT_URL}/platform/site-reliability-guardian/v1/guardians" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json")

# Procura um Guardian com o mesmo nome
GUARDIAN_ID=$(echo "$GUARDIANS_LIST" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for g in data.get('guardians', data if isinstance(data, list) else []):
        if g.get('name') == '$GUARDIAN_NAME':
            print(g['id'])
            break
except: pass
" 2>/dev/null)

if [ -n "$GUARDIAN_ID" ]; then
  echo -e "${GREEN}✅ Guardian já existe — ID: ${GUARDIAN_ID} (reutilizando)${NC}"
else
  echo -e "${YELLOW}   Não encontrado. Criando novo Guardian...${NC}"

  GUARDIAN_JSON=$(cat dynatrace/guardian.json)

  GUARDIAN_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
    -X POST "${DT_TENANT_URL}/platform/site-reliability-guardian/v1/guardians" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$GUARDIAN_JSON")

  HTTP_STATUS=$(echo "$GUARDIAN_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
  GUARDIAN_BODY=$(echo "$GUARDIAN_RESPONSE" | grep -v "HTTP_STATUS:")

  if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
    GUARDIAN_ID=$(echo "$GUARDIAN_BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo -e "${GREEN}✅ Guardian criado — ID: ${GUARDIAN_ID}${NC}"
  else
    echo -e "${RED}❌  Falha ao criar Guardian (HTTP $HTTP_STATUS)${NC}"
    echo "$GUARDIAN_BODY"
    exit 1
  fi
fi

# ── Check / Create Automation Workflow ────────────────────────────────────────
WORKFLOW_TITLE=$(grep -o '"title"[[:space:]]*:[[:space:]]*"[^"]*"' dynatrace/workflow.json | head -1 | cut -d'"' -f4)
echo ""
echo -e "${YELLOW}⚙️  Verificando Workflow existente: ${WORKFLOW_TITLE}...${NC}"

WORKFLOWS_LIST=$(curl -s "${DT_TENANT_URL}/platform/automation/v1/workflows" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json")

# Procura um Workflow com o mesmo título
WORKFLOW_ID=$(echo "$WORKFLOWS_LIST" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for w in data.get('results', data.get('workflows', data if isinstance(data, list) else [])):
        if w.get('title') == '$WORKFLOW_TITLE':
            print(w['id'])
            break
except: pass
" 2>/dev/null)

if [ -n "$WORKFLOW_ID" ]; then
  echo -e "${GREEN}✅ Workflow já existe — ID: ${WORKFLOW_ID} (reutilizando)${NC}"
else
  echo -e "${YELLOW}   Não encontrado. Criando novo Workflow...${NC}"

  # Injeta o ID do Guardian no template do workflow
  WORKFLOW_JSON=$(cat dynatrace/workflow.json | sed "s/GUARDIAN_ID_PLACEHOLDER/${GUARDIAN_ID}/g")

  WORKFLOW_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
    -X POST "${DT_TENANT_URL}/platform/automation/v1/workflows" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$WORKFLOW_JSON")

  HTTP_STATUS=$(echo "$WORKFLOW_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
  WORKFLOW_BODY=$(echo "$WORKFLOW_RESPONSE" | grep -v "HTTP_STATUS:")

  if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
    WORKFLOW_ID=$(echo "$WORKFLOW_BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo -e "${GREEN}✅ Workflow criado — ID: ${WORKFLOW_ID}${NC}"
  else
    echo -e "${RED}❌  Falha ao criar Workflow (HTTP $HTTP_STATUS)${NC}"
    echo "$WORKFLOW_BODY"
    exit 1
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✅  Setup concluído!                                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Adicione estes secrets no seu repositório GitHub:${NC}"
echo "  Settings → Secrets and variables → Actions → New repository secret"
echo ""
echo -e "  ${BLUE}DT_CLIENT_ID${NC}     = $DT_CLIENT_ID"
echo -e "  ${BLUE}DT_CLIENT_SECRET${NC} = <seu secret>"
echo -e "  ${BLUE}DT_TENANT_URL${NC}    = $DT_TENANT_URL"
echo -e "  ${BLUE}DT_WORKFLOW_ID${NC}   = ${WORKFLOW_ID}   ← este é o mais importante!"
echo -e "  ${BLUE}DT_GUARDIAN_ID${NC}   = ${GUARDIAN_ID}"
echo ""
echo -e "${BLUE}Guardian no Dynatrace:${NC}"
echo "  ${DT_TENANT_URL}/ui/apps/dynatrace.site.reliability.guardian"
echo ""
echo -e "${BLUE}Workflow no Dynatrace:${NC}"
echo "  ${DT_TENANT_URL}/ui/apps/dynatrace.automations"
echo ""
