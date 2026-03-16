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
OAUTH_SCOPE="storage:security.events:read"
DT_TENANT_URL="${DT_TENANT_URL:-https://fov31014.apps.dynatrace.com}"

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
[ -f /tmp/dynatrace_execution_id.txt ] && echo -e "  Workflow Execution: $(cat /tmp/dynatrace_execution_id.txt)"
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

TOKEN=$(echo "$AUTH_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo -e "${RED}❌  Could not extract access token${NC}"
  exit 1
fi

echo -e "${GREEN}✅ Authenticated${NC}"
echo ""

# ── Aguarda o Guardian avaliar (workflow já foi disparado pelo trigger) ────────
GUARDIAN_WAIT=60
echo -e "${YELLOW}⏳ Aguardando ${GUARDIAN_WAIT}s para o Guardian completar a avaliação...${NC}"
sleep $GUARDIAN_WAIT
echo -e "${GREEN}✅ Janela de avaliação concluída${NC}"
echo ""

# ── Consulta DQL directa — storage:security.events:read ──────────────────────
# Evita o 403 do Automation API (não há scope para ler execuções de outro user)
echo -e "${YELLOW}🔍 Consultando security.events via DQL...${NC}"

# Usa python3 para construir e enviar o JSON (evita problemas de escaping bash)
QUERY_RESPONSE=$(python3 - "$TOKEN" "$DT_TENANT_URL" << 'PYEOF'
import sys, json, urllib.request

token = sys.argv[1]
tenant = sys.argv[2]
query = (
    'fetch security.events'
    ' | dedup {vulnerability.display_id, affected_entity.id}'
    ' | filter affected_entity.type == "SERVICE"'
    ' | filter vulnerability.resolution.status != "RESOLVED"'
    ' | filter vulnerability.parent.mute.status != "MUTED"'
    ' | filter vulnerability.mute.status != "MUTED"'
    ' | summarize'
    '     criticalCount = countDistinct(if(vulnerability.risk.level == "CRITICAL", vulnerability.display_id)),'
    '     highCount     = countDistinct(if(vulnerability.risk.level == "HIGH", vulnerability.display_id))'
)
body = json.dumps({'query': query, 'requestTimeoutMilliseconds': 30000}).encode()
req = urllib.request.Request(
    f'{tenant}/platform/storage/query/v1/query:execute',
    data=body,
    headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
)
try:
    with urllib.request.urlopen(req) as r:
        print(r.read().decode())
except urllib.error.HTTPError as e:
    print(json.dumps({'error': e.code, 'message': e.read().decode()}))
PYEOF
)

echo "  [debug] DQL response: $(echo \"$QUERY_RESPONSE\" | head -c 600)"
echo ""
# Verifica se a resposta é um erro (HTML ou JSON com error)
if echo "$QUERY_RESPONSE" | grep -qi "forbidden\|unauthorized\|error"; then
  echo -e "${RED}❌  DQL query falhou — não é possível verificar vulnerabilidades${NC}"
  echo -e "${RED}    Bloqueando deployment por precaução (fail-safe)${NC}"
  exit 1
fi
CRITICAL_COUNT=$(echo "$QUERY_RESPONSE" | python3 -c "
import sys,json
try:
  r=json.load(sys.stdin).get('result',{}).get('records',[])
  print(int(r[0].get('criticalCount',0) or 0) if r else 0)
except: print(0)
" 2>/dev/null)

HIGH_COUNT=$(echo "$QUERY_RESPONSE" | python3 -c "
import sys,json
try:
  r=json.load(sys.stdin).get('result',{}).get('records',[])
  print(int(r[0].get('highCount',0) or 0) if r else 0)
except: print(0)
" 2>/dev/null)

CRITICAL_COUNT=${CRITICAL_COUNT:-0}
HIGH_COUNT=${HIGH_COUNT:-0}

echo -e "  CVEs Críticos: ${CRITICAL_COUNT}"
echo -e "  CVEs High:     ${HIGH_COUNT}"
echo ""

if [ "$CRITICAL_COUNT" -gt 0 ] 2>/dev/null; then
  echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  ❌  SRG GATE — DEPLOYMENT BLOQUEADO                         ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "${RED}  🚨 Dynatrace AppSec detectou ${CRITICAL_COUNT} CVE(s) crítico(s)!${NC}"
  echo -e "  ${DT_TENANT_URL}/ui/apps/dynatrace.site.reliability.guardian"
  exit 1
fi

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅  SRG GATE — DEPLOYMENT APROVADO                          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "${GREEN}  Nenhuma vulnerabilidade crítica detectada.${NC}"
exit 0


# ── Poll for completion (via lista de execuções do workflow) ──────────────────
# Usamos GET /executions?workflowId=... em vez de GET /executions/{id}
# porque execuções criadas via API pertencem ao dono do workflow (UI user),
# e o service account só consegue listar via workflowId com scope :run.
echo -e "${YELLOW}⏳ Waiting for workflow to complete...${NC}"
echo -e "   Aguardando 15s para execução ser registrada na API..."
sleep 15

ELAPSED=15

while [ $ELAPSED -lt $MAX_WAIT_TIME ]; do
  LIST=$(curl -s "${DT_TENANT_URL}/platform/automation/v1/executions?workflowId=${DT_WORKFLOW_ID}&limit=5" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")

  STATE=$(echo "$LIST" | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
  items = data if isinstance(data, list) else data.get('executions', data.get('items', []))
  for e in items:
    if e.get('id') == '${EXECUTION_ID}':
      print(e.get('state', ''))
      break
except:
  pass
" 2>/dev/null || true)

  # fallback: se não achou por ID, pega o mais recente da lista
  if [ -z "$STATE" ]; then
    STATE=$(echo "$LIST" | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
  items = data if isinstance(data, list) else data.get('executions', data.get('items', []))
  if items:
    print(items[0].get('state', ''))
except:
  pass
" 2>/dev/null || true)
    [ -n "$STATE" ] && echo -e "   [info] usando execução mais recente do workflow"
  fi

  echo -e "   State: ${STATE:-UNKNOWN}  (${ELAPSED}s elapsed)"
  if [ -z "$STATE" ]; then
    echo -e "   [debug] list response: $(echo "$LIST" | head -c 400)"
  fi

  if [ "$STATE" = "RUNNING" ]; then
    sleep "$POLL_INTERVAL"
    ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
    continue
  fi

  if [ "$STATE" = "ERROR" ] || [ "$STATE" = "FAILED" ]; then
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║          ❌  WORKFLOW EXECUTION FAILED               ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}   Execution: ${DT_TENANT_URL}/ui/apps/dynatrace.automations/executions/${EXECUTION_ID}${NC}"
    exit 1
  fi

  if [ "$STATE" = "SUCCESS" ]; then
    break
  fi

  # Estado desconhecido — continua a aguardar
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

# Tenta o endpoint de tasks; se 403, usa o resultado já obtido da lista
TASKS=$(curl -s "${DT_TENANT_URL}/platform/automation/v1/executions/${EXECUTION_ID}/tasks" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json")

# Se tasks retornou erro, usa a lista de execuções (que inclui o resultado)
TASKS_ERR=$(echo "$TASKS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || true)
if [ -n "$TASKS_ERR" ]; then
  echo -e "   [info] /tasks endpoint inacessível — usando result da lista de execuções"
  TASKS=$(curl -s "${DT_TENANT_URL}/platform/automation/v1/executions?workflowId=${DT_WORKFLOW_ID}&limit=5" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json")
fi

echo "$TASKS" > /tmp/dynatrace_tasks_response.json

VALIDATION_STATUS=$(echo "$TASKS" | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)

  # Formato 1: dict de tasks {taskName: {state, result, ...}}
  if isinstance(data, dict) and not data.get('executions') and not data.get('error'):
    for t in data.values():
      if not isinstance(t, dict): continue
      r = t.get('result') or {}
      vs = r.get('validation_status') or r.get('validationStatus', '')
      if vs:
        pc = r.get('summary', {}).get('pass', 0)
        fc = r.get('summary', {}).get('fail', 0)
        wc = r.get('summary', {}).get('warning', 0)
        vi = r.get('validation_id', t.get('id', ''))
        print(vs, pc, fc, wc, vi)
        sys.exit(0)

  # Formato 2: lista de execuções [{id, state, tasks: {taskName: {result}}}]
  items = data if isinstance(data, list) else data.get('executions', data.get('items', []))
  for e in items:
    if not isinstance(e, dict): continue
    tasks = e.get('tasks') or {}
    for t in tasks.values():
      if not isinstance(t, dict): continue
      r = t.get('result') or {}
      vs = r.get('validation_status') or r.get('validationStatus', '')
      if vs:
        pc = r.get('summary', {}).get('pass', 0)
        fc = r.get('summary', {}).get('fail', 0)
        wc = r.get('summary', {}).get('warning', 0)
        vi = r.get('validation_id', '')
        print(vs, pc, fc, wc, vi)
        sys.exit(0)

except Exception as e:
  sys.stderr.write(str(e) + '\n')
" 2>/tmp/dt_py_err.txt)

read -r VALIDATION_STATUS PASS_COUNT FAIL_COUNT WARNING_COUNT VALIDATION_ID <<< "$VALIDATION_STATUS"

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
