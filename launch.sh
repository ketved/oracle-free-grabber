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

for i in $(seq 1 $RETRIES); do
    echo ""
    echo "══ Attempt ${i}/${RETRIES} — $(date '+%H:%M:%S UTC') ══"

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
        2>&1) && OK=true || OK=false

    if $OK; then
        echo "SUCCESS! Instance launched!"
        echo "$RESULT" | tail -20
        if [[ -n "$NTFY" ]]; then
            curl -s -H "Title: Oracle Instance Created!" -H "Priority: urgent" \
                -H "Tags: white_check_mark" -d "Instance created! Check OCI console for IP." \
                "https://ntfy.sh/${NTFY}" || true
        fi
        echo "success=true" >> "$GITHUB_OUTPUT"
        exit 0
    fi

    # Show error (first 3 lines for brevity)
    ERR=$(echo "$RESULT" | head -3)
    if echo "$RESULT" | grep -qi "out of capacity\|out of host capacity"; then
        echo "  Out of capacity"
    elif echo "$RESULT" | grep -qi "too many requests\|rate limit"; then
        echo "  Rate limited, extra wait"
        sleep 60
    elif echo "$RESULT" | grep -qi "limit exceeded\|quota"; then
        echo "  QUOTA REACHED - check OCI console"
        echo "$ERR"
        exit 1
    else
        echo "  Error: $ERR"
    fi

    if [[ $i -lt $RETRIES ]]; then
        sleep $WAIT_SECONDS
    fi
done

echo "All attempts exhausted."
echo "success=false" >> "$GITHUB_OUTPUT"
exit 0
