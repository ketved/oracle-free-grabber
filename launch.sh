#!/bin/bash
# launch.sh — Attempt to grab an Oracle Free Tier Ampere A1 instance

set -euo pipefail

COMPARTMENT="${OCI_COMPARTMENT_OCID}"
SUBNET="${OCI_SUBNET_OCID}"
IMAGE="${OCI_IMAGE_OCID}"
AD="${OCI_AVAILABILITY_DOMAIN}"
SSH_KEY="${OCI_SSH_PUBLIC_KEY}"
NTFY="${NTFY_TOPIC:-}"

OCPUS=4
MEMORY_GB=24
DISPLAY_NAME="mf-system-ampere"
SHAPE="VM.Standard.A1.Flex"

RETRIES=300
WAIT_SECONDS=60

notify_success() {
    local ip="$1"
    local msg="Oracle Ampere A1 instance created! IP: ${ip}"
    echo "$msg"
    if [[ -n "$NTFY" ]]; then
        curl -s \
            -H "Title: Oracle Instance Created!" \
            -H "Priority: urgent" \
            -H "Tags: white_check_mark,rocket" \
            -d "$msg" \
            "https://ntfy.sh/${NTFY}" || true
    fi
}

attempt_launch() {
    local attempt=$1
    echo ""
    echo "══════════════════════════════════════════"
    echo "  Attempt ${attempt}/${RETRIES} — $(date '+%Y-%m-%d %H:%M:%S UTC')"
    echo "══════════════════════════════════════════"
    
    RESULT=$(oci compute instance launch \
        --compartment-id "$COMPARTMENT" \
        --availability-domain "$AD" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\": ${OCPUS}, \"memoryInGBs\": ${MEMORY_GB}}" \
        --image-id "$IMAGE" \
        --subnet-id "$SUBNET" \
        --display-name "$DISPLAY_NAME" \
        --assign-public-ip true \
        --metadata "{\"ssh_authorized_keys\": \"${SSH_KEY}\"}" \
        --wait-for-state RUNNING \
        --wait-interval-seconds 30 \
        --max-wait-seconds 600 \
        2>&1) && LAUNCH_OK=true || LAUNCH_OK=false
    
    if $LAUNCH_OK; then
        echo "SUCCESS! Instance is RUNNING."
        INSTANCE_ID=$(echo "$RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('data', {}).get('id', 'unknown'))
" 2>/dev/null || echo "unknown")
        
        if [[ "$INSTANCE_ID" != "unknown" ]]; then
            sleep 10
            IP=$(oci compute instance list-vnics \
                --instance-id "$INSTANCE_ID" \
                --query 'data[0]."public-ip"' \
                --raw-output 2>/dev/null || echo "check-console")
        else
            IP="check-console"
        fi
        
        echo "Instance ID: ${INSTANCE_ID}"
        echo "Public IP:   ${IP}"
        notify_success "$IP"
        echo "success=true" >> "$GITHUB_OUTPUT"
        return 0
    else
        if echo "$RESULT" | grep -qi "out of capacity\|out of host capacity\|capacity constraint"; then
            echo "  ↳ Out of capacity (expected). Will retry..."
            return 1
        elif echo "$RESULT" | grep -qi "too many requests\|rate limit"; then
            echo "  ↳ Rate limited. Backing off..."
            sleep 60
            return 1
        elif echo "$RESULT" | grep -qi "limit exceeded\|quota"; then
            echo "  ✗ Account limit reached. You may already have an instance."
            echo "success=false" >> "$GITHUB_OUTPUT"
            exit 1
        else
            echo "  ✗ Unexpected error:"
            echo "$RESULT" | head -20
            return 1
        fi
    fi
}

echo "╔══════════════════════════════════════════════╗"
echo "║  Oracle Free Tier Ampere A1 Grabber          ║"
echo "║  Region: ap-mumbai-1                         ║"
echo "║  Shape:  ${SHAPE} (${OCPUS} OCPU, ${MEMORY_GB}GB)  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Verifying OCI CLI config..."
oci iam region list --output table 2>/dev/null | head -5 && echo "OCI CLI OK" || {
    echo "ERROR: OCI CLI config is broken. Check secrets."
    exit 1
}

for i in $(seq 1 $RETRIES); do
    if attempt_launch $i; then
        echo ""
        echo "Done! Go disable this workflow now."
        exit 0
    fi
    
    if [[ $i -lt $RETRIES ]]; then
        echo "  Waiting ${WAIT_SECONDS}s before retry..."
        sleep $WAIT_SECONDS
    fi
done

echo ""
echo "All ${RETRIES} attempts failed (likely out of capacity)."
echo "Next run in ~10 minutes via cron."
echo "success=false" >> "$GITHUB_OUTPUT"
exit 0
