#!/bin/bash
# Check Dynatrace Guardian Validation Result
# Monitors a specific execution and checks Guardian validation status from tasks

set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AUTH_URL="https://sso.dynatrace.com/sso/oauth2/token"
SCOPE="automation:workflows:read"
DT_TENANT_URL="${DT_TENANT_URL:-https://fov31014.apps.dynatrace.com}"
MAX_WAIT_TIME="${MAX_WAIT_TIME:-300}"  # 5 minutes max wait (configurable)
POLL_INTERVAL="${POLL_INTERVAL:-15}"    # Check every 15 seconds
FAIL_ON_TIMEOUT="${FAIL_ON_TIMEOUT:-true}"  # Fail pipeline if timeout (recommended)

# Validate required environment variables
if [ -z "$DT_CLIENT_ID" ] || [ -z "$DT_CLIENT_SECRET" ] || [ -z "$DT_TENANT_URL" ]; then
    echo -e "${RED}Error: Missing required environment variables${NC}"
    echo "Required: DT_CLIENT_ID, DT_CLIENT_SECRET, DT_TENANT_URL"
    exit 1
fi

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Dynatrace Site Reliability Guardian - Validation     ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}⏱️  Timeout: ${MAX_WAIT_TIME}s ($(($MAX_WAIT_TIME / 60)) minutes)${NC}"
echo -e "${BLUE}🔄 Poll interval: ${POLL_INTERVAL}s${NC}"
echo ""

echo -e "${YELLOW}🔐 Authenticating with Dynatrace...${NC}"

# Step 1: Obtain OAuth2 token
AUTH_FULL_RESPONSE=$(curl -s -w "\nHTTP_STATUS_CODE:%{http_code}" -X POST "$AUTH_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=$DT_CLIENT_ID&client_secret=$DT_CLIENT_SECRET&scope=$SCOPE")

AUTH_HTTP_STATUS=$(echo "$AUTH_FULL_RESPONSE" | grep "HTTP_STATUS_CODE:" | cut -d: -f2)
AUTH_RESPONSE_BODY=$(echo "$AUTH_FULL_RESPONSE" | grep -v "HTTP_STATUS_CODE:")

if [ -z "$AUTH_HTTP_STATUS" ] || [ "$AUTH_HTTP_STATUS" = "000" ]; then
    echo -e "${RED}❌ Failed to connect to OAuth endpoint${NC}"
    exit 1
fi

if [ "$AUTH_HTTP_STATUS" -lt 200 ] || [ "$AUTH_HTTP_STATUS" -ge 300 ]; then
    echo -e "${RED}❌ Authentication failed (HTTP $AUTH_HTTP_STATUS)${NC}"
    exit 1
fi

TOKEN=$(echo "$AUTH_RESPONSE_BODY" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo -e "${RED}❌ Failed to obtain authentication token${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Authentication successful${NC}"
echo ""

# Step 2: Get execution ID from previous step
if [ -f /tmp/dynatrace_execution_id.txt ]; then
    EXECUTION_ID=$(cat /tmp/dynatrace_execution_id.txt)
    echo -e "${BLUE}📋 Monitoring execution: $EXECUTION_ID${NC}"
else
    echo -e "${RED}❌ No execution ID found${NC}"
    echo -e "${RED}   Make sure trigger_dynatrace_validation.sh ran successfully${NC}"
    exit 1
fi

echo -e "${YELLOW}🔍 Waiting for workflow to complete...${NC}"
echo ""

ELAPSED_TIME=0

while [ $ELAPSED_TIME -lt $MAX_WAIT_TIME ]; do
    # Get execution details
    DETAIL_URL="$DT_TENANT_URL/platform/automation/v1/executions/$EXECUTION_ID"
    DETAIL_RESPONSE=$(curl -s -X GET "$DETAIL_URL" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/json" 2>/dev/null)
    
    # Extract workflow state
    WORKFLOW_STATE=$(echo "$DETAIL_RESPONSE" | grep -o '"state":"[^"]*"' 2>/dev/null | head -1 | cut -d'"' -f4)
    
    echo -e "${YELLOW}   Workflow State: $WORKFLOW_STATE (${ELAPSED_TIME}s elapsed)${NC}"
    
    # If workflow is still running, wait
    if [ "$WORKFLOW_STATE" = "RUNNING" ]; then
        sleep $POLL_INTERVAL
        ELAPSED_TIME=$((ELAPSED_TIME + POLL_INTERVAL))
        continue
    fi
    
    # If workflow failed with error, pipeline fails
    if [ "$WORKFLOW_STATE" = "ERROR" ] || [ "$WORKFLOW_STATE" = "FAILED" ]; then
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║             ❌ WORKFLOW EXECUTION FAILED               ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${RED}⚠️  The Guardian validation workflow failed to execute${NC}"
        STATE_INFO=$(echo "$DETAIL_RESPONSE" | grep -o '"stateInfo":"[^"]*"' 2>/dev/null | head -1 | cut -d'"' -f4)
        if [ -n "$STATE_INFO" ] && [ "$STATE_INFO" != "null" ]; then
            echo -e "${RED}    Error: $STATE_INFO${NC}"
        fi
        echo ""
        echo -e "${YELLOW}📋 Execution ID: ${EXECUTION_ID}${NC}"
        exit 1
    fi
    
    # Workflow completed successfully - now check Guardian validation result from tasks
    if [ "$WORKFLOW_STATE" = "SUCCESS" ]; then
        echo ""
        echo -e "${YELLOW}🔍 Getting workflow tasks to check Guardian validation result...${NC}"
        
        TASKS_URL="$DT_TENANT_URL/platform/automation/v1/executions/$EXECUTION_ID/tasks"
        TASKS_RESPONSE=$(curl -s -X GET "$TASKS_URL" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/json" 2>/dev/null)
        
        # Save response for debugging
        echo "$TASKS_RESPONSE" > /tmp/dynatrace_tasks_response.json
        
        # Extract validation_status from run_validation.result.validation_status
        # Note: JSON has space after colon like "validation_status": "pass"
        VALIDATION_STATUS=$(echo "$TASKS_RESPONSE" | grep -o '"validation_status": "[^"]*"' 2>/dev/null | head -1 | cut -d'"' -f4)
        
        if [ -z "$VALIDATION_STATUS" ]; then
            echo -e "${RED}⚠️  Could not find validation_status in workflow tasks${NC}"
            echo -e "${RED}   The workflow may not have a Guardian validation task${NC}"
            echo -e "${RED}   Tasks response saved to /tmp/dynatrace_tasks_response.json${NC}"
            exit 1
        fi
        
        echo -e "${BLUE}   Guardian Validation Status: $VALIDATION_STATUS${NC}"
        
        # Extract validation details from run_validation.result (also with spaces)
        VALIDATION_ID=$(echo "$TASKS_RESPONSE" | grep -o '"validation_id": "[^"]*"' 2>/dev/null | head -1 | cut -d'"' -f4)
        PASS_COUNT=$(echo "$TASKS_RESPONSE" | grep -o '"pass": [0-9]*' 2>/dev/null | head -1 | awk '{print $2}')
        FAIL_COUNT=$(echo "$TASKS_RESPONSE" | grep -o '"fail": [0-9]*' 2>/dev/null | head -1 | awk '{print $2}')
        WARNING_COUNT=$(echo "$TASKS_RESPONSE" | grep -o '"warning": [0-9]*' 2>/dev/null | head -1 | awk '{print $2}')
        
        # Check Guardian validation result
        if [ "$VALIDATION_STATUS" = "pass" ]; then
            echo ""
            echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║                    ✅ VALIDATION PASSED                ║${NC}"
            echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${GREEN}🎉 All Site Reliability Guardian objectives were met!${NC}"
            echo -e "${GREEN}   Guardian validation status: '$VALIDATION_STATUS'${NC}"
            echo -e "${GREEN}   Objectives: ${PASS_COUNT} passed, ${FAIL_COUNT} failed${NC}"
            echo ""
            echo -e "${BLUE}📊 View Guardian Dashboard:${NC}"
            echo "   ${DT_TENANT_URL}/ui/apps/dynatrace.site.reliability.guardian"
            echo ""
            echo -e "${BLUE}📋 Validation ID: ${VALIDATION_ID}${NC}"
            echo -e "${BLUE}📋 Execution ID: ${EXECUTION_ID}${NC}"
            echo ""
            exit 0
        elif [ "$VALIDATION_STATUS" = "fail" ] || [ "$VALIDATION_STATUS" = "error" ]; then
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║                    ❌ VALIDATION FAILED                ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${RED}⚠️  Site Reliability Guardian detected issues!${NC}"
            echo -e "${RED}    Guardian validation status: '$VALIDATION_STATUS'${NC}"
            echo -e "${RED}    Objectives: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${WARNING_COUNT} warnings${NC}"
            echo ""
            echo -e "${YELLOW}📊 View Guardian Dashboard for details:${NC}"
            echo "   ${DT_TENANT_URL}/ui/apps/dynatrace.site.reliability.guardian"
            echo ""
            echo -e "${YELLOW}📋 Validation ID: ${VALIDATION_ID}${NC}"
            echo -e "${YELLOW}📋 Execution ID: ${EXECUTION_ID}${NC}"
            echo ""
            echo -e "${YELLOW}🔍 Check: Errors, Latency, Saturation, or User Type validation${NC}"
            exit 1
        elif [ "$VALIDATION_STATUS" = "warning" ]; then
            echo ""
            echo -e "${YELLOW}╔════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║                  ⚠️  VALIDATION WARNING                ║${NC}"
            echo -e "${YELLOW}╚════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}⚠️  Validation passed but with warnings${NC}"
            echo -e "${YELLOW}   Guardian validation status: '$VALIDATION_STATUS'${NC}"
            echo -e "${YELLOW}   Objectives: ${PASS_COUNT} passed, ${WARNING_COUNT} warnings${NC}"
            echo ""
            echo -e "${BLUE}📊 View Guardian Dashboard for details:${NC}"
            echo "   ${DT_TENANT_URL}/ui/apps/dynatrace.site.reliability.guardian"
            echo ""
            echo -e "${BLUE}📋 Validation ID: ${VALIDATION_ID}${NC}"
            echo -e "${BLUE}📋 Execution ID: ${EXECUTION_ID}${NC}"
            echo ""
            # Warnings don't fail the pipeline
            exit 0
        fi
    fi
done

# Timeout reached - validation didn't complete in time
echo ""
echo -e "${YELLOW}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║                    ⏱️  VALIDATION TIMEOUT              ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}⚠️  Could not determine validation result within ${MAX_WAIT_TIME}s ($(($MAX_WAIT_TIME / 60)) minutes)${NC}"
echo -e "${YELLOW}   The validation may still be running in Dynatrace.${NC}"
echo ""
echo -e "${YELLOW}📊 Check manually: $DT_TENANT_URL/ui/apps/dynatrace.site.reliability.guardian${NC}"
echo ""

# Decide whether to fail or continue on timeout
if [ "$FAIL_ON_TIMEOUT" = "true" ]; then
    echo -e "${RED}❌ Pipeline FAILED due to timeout${NC}"
    echo -e "${RED}   Validation did not complete within ${MAX_WAIT_TIME}s${NC}"
    exit 1
else
    echo -e "${YELLOW}⚠️  Pipeline continues despite timeout (FAIL_ON_TIMEOUT=false)${NC}"
    echo -e "${YELLOW}   This is not recommended - validation status unknown${NC}"
    exit 0
fi
