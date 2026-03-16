#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# create_workflow.sh
#
# Cria o Automation Workflow no Dynatrace apontando para o Guardian já criado.
# Execute este script UMA VEZ após criar o Guardian pela UI.
#
# Uso:
#   export DT_CLIENT_ID=dt0s02.XXXX
#   export DT_CLIENT_SECRET=dt0s02.XXXX.XXXX
#   export DT_GUARDIAN_ID=afe12e80-e74a-3e67-8eae-ab0db7d3fda1   # seu Guardian
#   ./scripts/create_workflow.sh
#
# Ou com .env preenchido:
#   ./scripts/create_workflow.sh
# ──────────────────────────────────────────────────────────────────────────────

set -e

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
# Guardian criado pela UI em 16/03/2026
DT_GUARDIAN_ID="${DT_GUARDIAN_ID:-afe12e80-e74a-3e67-8eae-ab0db7d3fda1}"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Criar Automation Workflow — SRG Security Gate              ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Guardian ID: ${DT_GUARDIAN_ID}"
echo -e "  Tenant:      ${DT_TENANT_URL}"
echo ""

if [ -z "$DT_CLIENT_ID" ] || [ -z "$DT_CLIENT_SECRET" ]; then
  echo -e "${RED}❌  Faltam variáveis de ambiente.${NC}"
  echo "  DT_CLIENT_ID     = ${DT_CLIENT_ID:-<não definido>}"
  echo "  DT_CLIENT_SECRET = ${DT_CLIENT_SECRET:-<não definido>}"
  echo ""
  echo "Preencha o .env ou exporte as variáveis antes de rodar."
  exit 1
fi

# ── Autenticar ────────────────────────────────────────────────────────────────
echo -e "${YELLOW}🔐 Autenticando...${NC}"

AUTH_RESPONSE=$(curl -s -X POST "https://sso.dynatrace.com/sso/oauth2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${DT_CLIENT_ID}&client_secret=${DT_CLIENT_SECRET}&scope=automation:workflows:write%20automation:workflows:read")

TOKEN=$(echo "$AUTH_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo -e "${RED}❌  Autenticação falhou.${NC}"
  echo "Resposta: $AUTH_RESPONSE"
  exit 1
fi

echo -e "${GREEN}✅ Autenticado${NC}"
echo ""

# ── Criar Workflow ────────────────────────────────────────────────────────────
echo -e "${YELLOW}⚙️  Criando Automation Workflow...${NC}"

WORKFLOW_PAYLOAD=$(cat <<EOF
{
  "title": "SRG Security Validation — srg-vulnerable-app",
  "description": "Disparado pelo GitHub Actions após cada deploy. Avalia o Guardian e bloqueia CVEs.",
  "schemaVersion": 3,
  "trigger": {},
  "tasks": {
    "run_validation": {
      "name": "run_validation",
      "action": "dynatrace.site.reliability.guardian:validate-guardian-action",
      "active": true,
      "input": {
        "executableId": "${DT_GUARDIAN_ID}",
        "executionRequestParameters": {
          "timeframeStart": "now()-1h",
          "timeframeEnd": "now()"
        }
      },
      "position": { "x": 0, "y": 1 },
      "conditions": {
        "states": {},
        "custom": "",
        "else": "STOP"
      },
      "timeout": 300000
    }
  }
}
EOF
)

WORKFLOW_FULL=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  -X POST "${DT_TENANT_URL}/platform/automation/v1/workflows" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$WORKFLOW_PAYLOAD")

HTTP_STATUS=$(echo "$WORKFLOW_FULL" | grep "HTTP_STATUS:" | cut -d: -f2)
WORKFLOW_BODY=$(echo "$WORKFLOW_FULL" | grep -v "HTTP_STATUS:")

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
  WORKFLOW_ID=$(echo "$WORKFLOW_BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo -e "${GREEN}✅ Workflow criado!${NC}"
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║   ✅  Pronto! Adicione o secret abaixo no GitHub:            ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BLUE}DT_WORKFLOW_ID${NC} = ${WORKFLOW_ID}"
  echo ""
  echo -e "${BLUE}GitHub → Settings → Secrets and variables → Actions → New repository secret${NC}"
  echo "  Nome:  DT_WORKFLOW_ID"
  echo "  Valor: ${WORKFLOW_ID}"
  echo ""
  echo -e "${BLUE}Workflow no Dynatrace:${NC}"
  echo "  ${DT_TENANT_URL}/ui/apps/dynatrace.automations"
  echo ""

  # Salva no .env se existir
  if [ -f .env ]; then
    if grep -q "^DT_WORKFLOW_ID=" .env; then
      sed -i.bak "s/^DT_WORKFLOW_ID=.*/DT_WORKFLOW_ID=${WORKFLOW_ID}/" .env
    else
      echo "DT_WORKFLOW_ID=${WORKFLOW_ID}" >> .env
    fi
    echo -e "${GREEN}✅ DT_WORKFLOW_ID salvo no .env também${NC}"
  fi

else
  echo -e "${RED}❌  Falha ao criar Workflow (HTTP $HTTP_STATUS)${NC}"
  echo ""
  echo "Resposta da API:"
  echo "$WORKFLOW_BODY"
  echo ""
  echo -e "${YELLOW}Possíveis causas:${NC}"
  echo "  • Escopo automation:workflows:write não habilitado no OAuth client"
  echo "  • Guardian ID inválido: ${DT_GUARDIAN_ID}"
  exit 1
fi
