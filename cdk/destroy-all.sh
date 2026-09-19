#!/bin/bash
# CDK Destroy Script for AgentCore Chat Application
# This script destroys all CDK stacks in reverse dependency order.
#
# Usage: ./destroy-all.sh [options]
#   --region <region>    AWS region (default: us-east-1)
#   --profile <profile>  AWS CLI profile to use
#   --yes                Auto-confirm all prompts (DANGEROUS)
#   --dry-run            Show what would be destroyed without destroying
#   -h, --help           Show this help message

# Note: We don't use 'set -e' because we want to continue cleanup even if some operations fail

# Disable AWS CLI pager
export AWS_PAGER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE=""
AUTO_YES=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: ./destroy-all.sh [options]"
            echo ""
            echo "Options:"
            echo "  --region <region>    AWS region (default: us-east-1)"
            echo "  --profile <profile>  AWS CLI profile to use"
            echo "  --yes                Auto-confirm all prompts (DANGEROUS)"
            echo "  --dry-run            Show what would be destroyed without destroying"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║     AgentCore Chat Application - CDK DESTROY               ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Set AWS profile if provided
if [ -n "$AWS_PROFILE" ]; then
    export AWS_PROFILE
    echo -e "${YELLOW}Using AWS Profile: $AWS_PROFILE${NC}"
fi

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
if [ "$AWS_ACCOUNT_ID" = "unknown" ]; then
    echo -e "${RED}Error: Could not get AWS account ID. Check your AWS credentials.${NC}"
    exit 1
fi

# Export environment variables for CDK
export AWS_REGION
export CDK_DEFAULT_REGION="$AWS_REGION"
export CDK_DEFAULT_ACCOUNT="$AWS_ACCOUNT_ID"

echo -e "${YELLOW}Configuration:${NC}"
echo "  AWS Account: $AWS_ACCOUNT_ID"
echo "  AWS Region: $AWS_REGION"
echo "  Dry Run: $DRY_RUN"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}DRY RUN MODE - No resources will be destroyed${NC}"
    echo ""
fi

# Confirmation prompt
if [ "$AUTO_YES" != true ] && [ "$DRY_RUN" != true ]; then
    echo -e "${RED}WARNING: This will permanently delete all CDK-managed resources!${NC}"
    echo ""
    echo -e "${YELLOW}The following stacks will be destroyed:${NC}"
    cd "$SCRIPT_DIR"
    npx cdk list 2>/dev/null || echo "  (Unable to list stacks)"
    echo ""
    echo -e "${YELLOW}Are you sure you want to continue? (type 'yes' to confirm)${NC}"
    read -r CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Destroy cancelled."
        exit 0
    fi
fi

# Change to CDK directory
cd "$SCRIPT_DIR"

APP_NAME="${APP_NAME:-htmx-chatapp}"
APP_NAME_UNDERSCORE="${APP_NAME//-/_}"

is_app_owned() {
    case "$1" in
        *"$APP_NAME"*|*"$APP_NAME_UNDERSCORE"*) return 0 ;;
        *) return 1 ;;
    esac
}


# ============================================================================
# STEP 0: Clean up CloudWatch Logs Deliveries (must be deleted before sources)
# ============================================================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 0: Clean up CloudWatch Logs Deliveries${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Deleting deliveries before sources to avoid dependency errors...${NC}"

# Only this app's deliveries are touched. These APIs are account-wide, so an
# unfiltered sweep would delete log deliveries belonging to unrelated
# workloads in the same region.
if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}[DRY RUN] Would delete CloudWatch Logs deliveries owned by ${APP_NAME}${NC}"
else
    # Deliveries: match on the source name, since the delivery id carries no app name.
    DELETED_ANY=false
    while read -r DELIVERY_ID SOURCE_NAME; do
        [ -z "$DELIVERY_ID" ] && continue
        if is_app_owned "$SOURCE_NAME"; then
            echo -e "${YELLOW}Deleting delivery: $DELIVERY_ID ($SOURCE_NAME)${NC}"
            aws logs delete-delivery --id "$DELIVERY_ID" --region "$AWS_REGION" 2>/dev/null || true
            DELETED_ANY=true
        else
            echo -e "${CYAN}Skipping delivery not owned by ${APP_NAME}: $DELIVERY_ID ($SOURCE_NAME)${NC}"
        fi
    done <<EOF
$(aws logs describe-deliveries --region "$AWS_REGION" --query 'deliveries[].[id,deliverySourceName]' --output text 2>/dev/null || echo "")
EOF
    [ "$DELETED_ANY" = true ] && echo -e "${GREEN}Deliveries deleted${NC}" || echo -e "${GREEN}No app-owned deliveries found to delete${NC}"

    for SOURCE_NAME in $(aws logs describe-delivery-sources --region "$AWS_REGION" --query 'deliverySources[].name' --output text 2>/dev/null || echo ""); do
        [ -z "$SOURCE_NAME" ] && continue
        if is_app_owned "$SOURCE_NAME"; then
            echo -e "${YELLOW}Deleting delivery source: $SOURCE_NAME${NC}"
            aws logs delete-delivery-source --name "$SOURCE_NAME" --region "$AWS_REGION" 2>/dev/null || true
        fi
    done

    for DEST_NAME in $(aws logs describe-delivery-destinations --region "$AWS_REGION" --query 'deliveryDestinations[].name' --output text 2>/dev/null || echo ""); do
        [ -z "$DEST_NAME" ] && continue
        if is_app_owned "$DEST_NAME"; then
            echo -e "${YELLOW}Deleting delivery destination: $DEST_NAME${NC}"
            aws logs delete-delivery-destination --name "$DEST_NAME" --region "$AWS_REGION" 2>/dev/null || true
        fi
    done
fi

echo ""

# ============================================================================
# STEP 1: Destroy all CDK stacks
# ============================================================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 1: Destroy all CDK stacks${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Stacks are deleted one at a time, newest dependency first:
#   ChatApp -> Agent -> Bedrock -> Foundation
#
# This uses the CloudFormation API directly rather than `cdk destroy --all`
# for three reasons seen in practice:
#   1. `cdk destroy` reported success in the wrong region when AWS_REGION was
#      unset, because it falls back to the profile default while the AWS CLI
#      calls here use --region.
#   2. After one stack failed to delete, cdk kept the process alive for over an
#      hour on a stalled API call without touching the remaining stacks.
#   3. A failure has to be visible: the script used to print "Destroy
#      Complete!" with stacks still standing.
STACKS=(
    "${APP_NAME}-chatapp"
    "${APP_NAME}-agent"
    "${APP_NAME}-bedrock"
    "${APP_NAME}-foundation"
)

FAILED_STACKS=()
RETAINED_RESOURCES=()

# How long to wait for a single stack delete before giving up (seconds).
STACK_DELETE_TIMEOUT="${STACK_DELETE_TIMEOUT:-1800}"
STACK_POLL_INTERVAL=15

stack_exists() {
    aws cloudformation describe-stacks --stack-name "$1" --region "$AWS_REGION" >/dev/null 2>&1
}

stack_status() {
    aws cloudformation describe-stacks --stack-name "$1" --region "$AWS_REGION" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null
}

# Logical ids of resources that just failed to delete, one per line.
failed_resource_ids() {
    aws cloudformation describe-stack-resources \
        --stack-name "$1" \
        --region "$AWS_REGION" \
        --query "StackResources[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" \
        --output text 2>/dev/null | tr '\t' '\n'
}

# Polls until the stack is gone, reaches DELETE_FAILED, or the timeout expires.
# `aws cloudformation wait stack-delete-complete` is deliberately not used: it
# polls for up to an hour even when the stack is sitting in a state it will
# never leave (e.g. a delete rejected for termination protection), which is how
# this script used to appear hung.
#   0 = deleted, 1 = DELETE_FAILED, 2 = timed out or unexpected state
wait_for_stack_delete() {
    local stack="$1"
    local waited=0
    local status

    while [ "$waited" -lt "$STACK_DELETE_TIMEOUT" ]; do
        if ! stack_exists "$stack"; then
            return 0
        fi
        status=$(stack_status "$stack")
        case "$status" in
            DELETE_IN_PROGRESS) ;;
            DELETE_FAILED) return 1 ;;
            DELETE_COMPLETE) return 0 ;;
            *)
                echo -e "${RED}$stack is in state $status, not being deleted${NC}"
                return 2
                ;;
        esac
        sleep "$STACK_POLL_INTERVAL"
        waited=$((waited + STACK_POLL_INTERVAL))
    done

    echo -e "${RED}Timed out after ${STACK_DELETE_TIMEOUT}s waiting for $stack to delete${NC}"
    return 2
}

# Deletes one stack, waiting for the result. A DELETE_FAILED stack is retried
# with the offending resources retained, which is what unblocks Lambda@Edge
# functions: AWS refuses to delete their replicas until CloudFront has removed
# them (hours later), so they cannot be deleted inline. Retained resources are
# reported at the end instead of being silently orphaned.
delete_stack_with_retries() {
    local stack="$1"
    local attempt
    local retain=()
    local delete_err
    local wait_rc
    local newly_failed

    for attempt in 1 2 3; do
        if [ ${#retain[@]} -eq 0 ]; then
            delete_err=$(aws cloudformation delete-stack --stack-name "$stack" --region "$AWS_REGION" 2>&1)
        else
            echo -e "${YELLOW}Retrying delete of $stack, retaining: ${retain[*]}${NC}"
            delete_err=$(aws cloudformation delete-stack --stack-name "$stack" --region "$AWS_REGION" \
                --retain-resources "${retain[@]}" 2>&1)
        fi

        # A rejected DeleteStack call (termination protection, missing
        # permissions, ...) never produces stack events, so surface it directly
        # instead of polling for a delete that was never started.
        if [ -n "$delete_err" ]; then
            echo -e "${RED}DeleteStack was rejected for $stack:${NC}"
            echo "$delete_err" | head -3 | sed 's/^/  /'
            return 1
        fi

        wait_for_stack_delete "$stack"
        wait_rc=$?

        if [ "$wait_rc" -eq 0 ]; then
            if [ ${#retain[@]} -gt 0 ]; then
                for r in "${retain[@]}"; do
                    RETAINED_RESOURCES+=("$stack/$r")
                done
            fi
            return 0
        fi

        # Timed out or an unexpected state: no point retrying.
        if [ "$wait_rc" -eq 2 ]; then
            return 1
        fi

        # DELETE_FAILED: collect what blocked it and retry retaining those.
        newly_failed=$(failed_resource_ids "$stack")
        if [ -z "$newly_failed" ]; then
            return 1
        fi
        echo -e "${YELLOW}$stack delete failed on:${NC}"
        aws cloudformation describe-stack-events --stack-name "$stack" --region "$AWS_REGION" \
            --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
            --output text 2>/dev/null | head -5
        while read -r rid; do
            [ -z "$rid" ] && continue
            case " ${retain[*]} " in
                *" $rid "*) ;;
                *) retain+=("$rid") ;;
            esac
        done <<EOF
$newly_failed
EOF
    done

    return 1
}

if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}[DRY RUN] Would delete these stacks in order, waiting for each:${NC}"
    for STACK in "${STACKS[@]}"; do
        if stack_exists "$STACK"; then
            echo "  - $STACK"
        else
            echo "  - $STACK (not deployed, would skip)"
        fi
    done
else
    echo -e "${YELLOW}Destroying stacks (this may take 10-15 minutes)...${NC}"
    echo ""

    for STACK in "${STACKS[@]}"; do
        if ! stack_exists "$STACK"; then
            echo -e "${GREEN}$STACK does not exist, skipping${NC}"
            continue
        fi
        echo -e "${YELLOW}Deleting $STACK...${NC}"
        if delete_stack_with_retries "$STACK"; then
            echo -e "${GREEN}$STACK deleted${NC}"
        else
            echo -e "${RED}$STACK could not be deleted${NC}"
            FAILED_STACKS+=("$STACK")
        fi
    done

    if [ ${#FAILED_STACKS[@]} -eq 0 ]; then
        echo -e "${GREEN}All CDK stacks destroyed${NC}"
    fi
fi

# ============================================================================
# STEP 2: Clean up any remaining resources
# ============================================================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 2: Clean up remaining resources${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Note: ECR repositories are now managed by CDK and deleted automatically

# Delete the ECS Express Gateway service.
# CloudFormation deletion of AWS::ECS::ExpressGatewayService does not always
# remove the underlying service, and a leftover service blocks a future
# redeploy with: "Resource of type 'AWS::ECS::ExpressGatewayService' ...
# already exists." So delete it explicitly here.
echo -e "${YELLOW}Cleaning up ECS Express Gateway service...${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}[DRY RUN] Would delete ECS Express Gateway service '${APP_NAME}-express' if present${NC}"
else
    EXPRESS_SVC_ARN=$(aws ecs list-services \
        --cluster default \
        --region "$AWS_REGION" \
        --query "serviceArns[?contains(@, '${APP_NAME}-express')]" \
        --output text 2>/dev/null | head -1 || echo "")
    if [ -n "$EXPRESS_SVC_ARN" ] && [ "$EXPRESS_SVC_ARN" != "None" ]; then
        aws ecs delete-express-gateway-service \
            --service-arn "$EXPRESS_SVC_ARN" \
            --region "$AWS_REGION" >/dev/null 2>&1 \
            && echo -e "${GREEN}Deleted ECS Express Gateway service: ${EXPRESS_SVC_ARN}${NC}" \
            || echo -e "${YELLOW}Could not delete express service (may already be gone): ${EXPRESS_SVC_ARN}${NC}"
    else
        echo -e "${GREEN}No ECS Express Gateway service found to delete${NC}"
    fi
fi

# Clean up CloudWatch log groups left behind by deleted stacks.
# CDK-declared log groups and Lambda-auto-created log groups can survive a
# stack delete; if they have fixed names they then block a future deploy's
# change set (e.g. /aws/lambda/${APP_NAME}-ecs-build-waiter-provider). All
# stacks are already destroyed at this point, so prefix-based bulk deletion
# of app-owned groups is safe.
echo -e "${YELLOW}Cleaning up CloudWatch log groups...${NC}"

LOG_GROUP_PREFIXES=(
    "/aws/lambda/${APP_NAME}"
    "/ecs/${APP_NAME}"
    "/aws/vendedlogs/bedrock-agentcore"
    "/aws/bedrock-agentcore/runtimes"
)

for PREFIX in "${LOG_GROUP_PREFIXES[@]}"; do
    if [ "$DRY_RUN" = true ]; then
        echo -e "${CYAN}[DRY RUN] Would delete log groups with prefix: $PREFIX${NC}"
        continue
    fi
    LOG_GROUP_NAMES=$(aws logs describe-log-groups \
        --log-group-name-prefix "$PREFIX" \
        --region "$AWS_REGION" \
        --query 'logGroups[].logGroupName' \
        --output text 2>/dev/null || echo "")
    for LOG_GROUP in $LOG_GROUP_NAMES; do
        [ -z "$LOG_GROUP" ] && continue
        # The bedrock-agentcore prefixes are shared by every agent in the
        # account, so only delete groups carrying this app's name.
        if ! is_app_owned "$LOG_GROUP"; then
            echo -e "${CYAN}Skipping log group not owned by ${APP_NAME}: $LOG_GROUP${NC}"
            continue
        fi
        aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" 2>/dev/null \
            && echo -e "${GREEN}Deleted log group: $LOG_GROUP${NC}" || true
    done
done

# Clean up CDK outputs file
if [ -f "cdk-outputs.json" ]; then
    if [ "$DRY_RUN" = true ]; then
        echo -e "${CYAN}[DRY RUN] Would delete cdk-outputs.json${NC}"
    else
        rm -f cdk-outputs.json
        echo -e "${GREEN}Deleted cdk-outputs.json${NC}"
    fi
fi

# ============================================================================
# COMPLETE
# ============================================================================
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}This was a DRY RUN - no resources were actually destroyed.${NC}"
    echo -e "${CYAN}Run without --dry-run to perform actual cleanup.${NC}"
    exit 0
fi

# Re-read the live state rather than trusting the steps above.
REMAINING=$(aws cloudformation list-stacks \
    --region "$AWS_REGION" \
    --query "StackSummaries[?starts_with(StackName, '${APP_NAME}-') && StackStatus != 'DELETE_COMPLETE'].StackName" \
    --output text 2>/dev/null | tr '\t' '\n' | sort -u | grep -v '^$' || true)

if [ -n "$REMAINING" ] || [ ${#FAILED_STACKS[@]} -gt 0 ]; then
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║           CDK Destroy INCOMPLETE                           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Stacks still present in $AWS_REGION:${NC}"
    echo "$REMAINING" | sed 's/^/  - /'
    echo ""
    echo -e "${YELLOW}Inspect one with:${NC}"
    echo "  aws cloudformation describe-stack-events --region $AWS_REGION --stack-name <stack> \\"
    echo "    --query \"StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]\""
    echo ""
    echo -e "${YELLOW}Then re-run this script; deletion is resumable.${NC}"
    exit 1
fi

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           CDK Destroy Complete!                            ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Summary of destroyed resources:${NC}"
echo "  - ChatApp (ECS Express Mode, ECR, CodeBuild, S3 source bucket)"
echo "  - Agent (ECR, CodeBuild, CfnRuntime, Observability)"
echo "  - Bedrock (Guardrail, Knowledge Base, Memory)"
echo "  - Foundation (Cognito, DynamoDB, IAM roles, Secrets)"
echo "  - CloudWatch log groups and log deliveries owned by ${APP_NAME}"
echo ""

if [ ${#RETAINED_RESOURCES[@]} -gt 0 ]; then
    echo -e "${YELLOW}Retained (AWS would not delete them yet, typically Lambda@Edge${NC}"
    echo -e "${YELLOW}replicas that CloudFront releases after a few hours):${NC}"
    for R in "${RETAINED_RESOURCES[@]}"; do
        echo "  - $R"
    done
    echo ""
    echo -e "${YELLOW}They cost nothing while idle. Delete them later with:${NC}"
    echo "  aws lambda list-functions --region $AWS_REGION \\"
    echo "    --query \"Functions[?starts_with(FunctionName,'${APP_NAME}')].FunctionName\""
    echo ""
fi

echo -e "${YELLOW}Note: Some resources may take a few minutes to fully delete.${NC}"
echo ""
echo -e "${YELLOW}To redeploy, run:${NC}"
echo "  ./deploy-all.sh --region $AWS_REGION"
