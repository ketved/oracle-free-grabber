#!/bin/bash
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

RETRIES=200
WAIT_SECONDS=90

notify_success() {
    local ip="$1"
    local msg="Oracle Ampere A1 created! IP: ${ip}"
    echo "$msg"
    if [[ -n "$NTFY" ]]; then
        curl -s -H "Title: Oracle Instance Created!" -H "Priority: urgent" \
            -H "Tags: white_check_mark,rocket" -d "$msg" \
            "https://ntfy.sh/${NTFY}" || true
    fi
}

attempt_launch() {
    local attempt=$1
    echo ""
    echo "══ Attempt ${attempt}/${RETRIES} — $(date '+%H:%M:%S UTC') ══"

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
        --cli-read-timeout 120 \
        --cli-connect-timeout 30 \
        2>&1) && LAUNCH_OK=true || LAUNCH_OK=false

    if $LAUNCH_OK; then
        echo "SUCCESS!"
        IP=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin).get('data',{})
print(d.get('id','unknown'))
" 2>/dev/null || echo "check-console")
        echo "Instance: ${IP}"
        notify_success "$IP"
        echo "success=true" >> "$GITHUB_OUTPUT"
        return 0
    else
        # Extract just the error code/message
        ERR=$(echo "$RESULT" | grep -oi "out of capacity\|out of host capacity\|capacity constraint\|too many requests\|rate limit\|limit exceeded\|quota\|timed out\|InternalError\|ServiceError" | head -1 || true)

        case "$ERR" in
            *capacity*|*Capacity*)
                echo "  ↳ Out of capacity"
                return 1 ;;
            *"rate limit"*|*"too many"*)
                echo "  ↳ Rate limited, extra wait..."
                sleep 60
                return 1 ;;
            *"limit exceeded"*|*quota*)
                echo "  ✗ Account quota reached — check OCI console"
                echo "success=false" >> "$GITHUB_OUTPUT"
                exit 1 ;;
            *"timed out"*)
                echo "  ↳ Timeout (normal)"
                return 1 ;;
            *)
                echo "  ↳ Other error: $(echo "$RESULT" | grep -o '"message": "[^"]*"' | head -1)"
                return 1 ;;
        esac
    fi
}

echo "Oracle A1 Grabber | ap-mumbai-1 | ${SHAPE} ${OCPUS}CPU/${MEMORY_GB}GB"
echo "Verifying OCI CLI..."
oci iam region list --output table 2>/dev/null | head -5 && echo "OCI CLI OK" || {
    echo "ERROR: OCI config broken"; exit 1
}

for i in $(seq 1 $RETRIES); do
    if attempt_launch $i; then
        echo "Done! Disable this workflow now."
        exit 0
    fi
    if [[ $i -lt $RETRIES ]]; then
        sleep $WAIT_SECONDS
    fi
done

echo "All ${RETRIES} attempts exhausted. Next cron run will retry."
echo "success=false" >> "$GITHUB_OUTPUT"
exit 0
