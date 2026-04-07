#!/bin/bash
#
# Nextcloud AWS Deployment Script
# Automates the deployment of Nextcloud on AWS using CloudFormation
#

set -e  # Exit on error
set -u  # Exit on undefined variable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CFN_TEMPLATE="${SCRIPT_DIR}/../cloudformation/nextcloud-ha-serverless.yaml"

# Default values
STACK_NAME="nextcloud-production"
REGION="us-east-1"
CONFIG_FILE="${SCRIPT_DIR}/../config/deployment-config.env"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed. Please install it first."
        log_info "Visit: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        log_warning "jq is not installed. Some features may not work properly."
        log_info "Install with: sudo apt-get install jq (Ubuntu) or brew install jq (Mac)"
    fi

    # Check CloudFormation template exists
    if [ ! -f "$CFN_TEMPLATE" ]; then
        log_error "CloudFormation template not found: $CFN_TEMPLATE"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

validate_template() {
    log_info "Validating CloudFormation template..."

    if aws cloudformation validate-template \
        --template-body file://"$CFN_TEMPLATE" \
        --region "$REGION" &> /dev/null; then
        log_success "Template validation passed"
    else
        log_error "Template validation failed"
        exit 1
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_info "Loading configuration from $CONFIG_FILE"
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    else
        log_warning "Configuration file not found: $CONFIG_FILE"
        log_info "Using default/interactive configuration"
    fi
}

prompt_for_parameters() {
    log_info "Configuring deployment parameters..."

    # Stack Name
    read -p "Stack Name [$STACK_NAME]: " input
    STACK_NAME="${input:-$STACK_NAME}"

    # Region
    read -p "AWS Region [$REGION]: " input
    REGION="${input:-$REGION}"

    # VPC ID
    if [ -z "${VPC_ID:-}" ]; then
        read -p "VPC ID: " VPC_ID
    fi

    # Subnets
    if [ -z "${PRIVATE_SUBNET_IDS:-}" ]; then
        read -p "Private Subnet IDs (comma-separated, at least 2): " PRIVATE_SUBNET_IDS
    fi

    if [ -z "${PUBLIC_SUBNET_IDS:-}" ]; then
        read -p "Public Subnet IDs (comma-separated, at least 2): " PUBLIC_SUBNET_IDS
    fi

    # Database Password
    if [ -z "${DB_PASSWORD:-}" ]; then
        while true; do
            read -s -p "Database Password (min 16 chars): " DB_PASSWORD
            echo
            read -s -p "Confirm Database Password: " DB_PASSWORD_CONFIRM
            echo
            if [ "$DB_PASSWORD" = "$DB_PASSWORD_CONFIRM" ] && [ ${#DB_PASSWORD} -ge 16 ]; then
                break
            else
                log_error "Passwords don't match or too short. Try again."
            fi
        done
    fi

    # Admin Password
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
        while true; do
            read -s -p "Nextcloud Admin Password (min 8 chars): " ADMIN_PASSWORD
            echo
            read -s -p "Confirm Admin Password: " ADMIN_PASSWORD_CONFIRM
            echo
            if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ] && [ ${#ADMIN_PASSWORD} -ge 8 ]; then
                break
            else
                log_error "Passwords don't match or too short. Try again."
            fi
        done
    fi

    # Optional: Domain and Certificate
    read -p "Custom Domain (optional, press Enter to skip): " DOMAIN_NAME
    if [ -n "$DOMAIN_NAME" ]; then
        read -p "ACM Certificate ARN: " CERTIFICATE_ARN
    fi

    # Scaling parameters
    read -p "Minimum Tasks [2]: " MIN_TASKS
    MIN_TASKS="${MIN_TASKS:-2}"

    read -p "Maximum Tasks [10]: " MAX_TASKS
    MAX_TASKS="${MAX_TASKS:-10}"

    read -p "Task CPU (256/512/1024/2048) [1024]: " TASK_CPU
    TASK_CPU="${TASK_CPU:-1024}"

    read -p "Task Memory MB (512-8192) [2048]: " TASK_MEMORY
    TASK_MEMORY="${TASK_MEMORY:-2048}"

    # Database scaling
    read -p "Aurora Min ACU (0.5-8) [0.5]: " DB_MIN_CAPACITY
    DB_MIN_CAPACITY="${DB_MIN_CAPACITY:-0.5}"

    read -p "Aurora Max ACU (1-128) [16]: " DB_MAX_CAPACITY
    DB_MAX_CAPACITY="${DB_MAX_CAPACITY:-16}"
}

build_parameters() {
    PARAMETERS=(
        "ParameterKey=VpcId,ParameterValue=$VPC_ID"
        "ParameterKey=PrivateSubnetIds,ParameterValue=\"$PRIVATE_SUBNET_IDS\""
        "ParameterKey=PublicSubnetIds,ParameterValue=\"$PUBLIC_SUBNET_IDS\""
        "ParameterKey=DBPassword,ParameterValue=$DB_PASSWORD"
        "ParameterKey=NextcloudAdminPassword,ParameterValue=$ADMIN_PASSWORD"
        "ParameterKey=MinTasks,ParameterValue=$MIN_TASKS"
        "ParameterKey=MaxTasks,ParameterValue=$MAX_TASKS"
        "ParameterKey=TaskCpu,ParameterValue=$TASK_CPU"
        "ParameterKey=TaskMemory,ParameterValue=$TASK_MEMORY"
        "ParameterKey=DBMinCapacity,ParameterValue=$DB_MIN_CAPACITY"
        "ParameterKey=DBMaxCapacity,ParameterValue=$DB_MAX_CAPACITY"
    )

    if [ -n "${DOMAIN_NAME:-}" ]; then
        PARAMETERS+=("ParameterKey=DomainName,ParameterValue=$DOMAIN_NAME")
        PARAMETERS+=("ParameterKey=CertificateArn,ParameterValue=$CERTIFICATE_ARN")
    fi
}

estimate_cost() {
    log_info "Estimating monthly cost..."

    if command -v python3 &> /dev/null; then
        # Call cost calculator if available
        COST_CALCULATOR="${SCRIPT_DIR}/cost-calculator.py"
        if [ -f "$COST_CALCULATOR" ]; then
            echo ""
            python3 "$COST_CALCULATOR" medium
            echo ""
        fi
    fi
}

deploy_stack() {
    log_info "Deploying CloudFormation stack: $STACK_NAME"
    log_info "Region: $REGION"

    # Check if stack exists
    if aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" &> /dev/null; then

        log_warning "Stack $STACK_NAME already exists"
        read -p "Do you want to update it? (y/n): " answer
        if [ "$answer" != "y" ]; then
            log_info "Deployment cancelled"
            exit 0
        fi

        OPERATION="update-stack"
        log_info "Updating existing stack..."
    else
        OPERATION="create-stack"
        log_info "Creating new stack..."
    fi

    # Build parameters string
    PARAM_STRING=""
    for param in "${PARAMETERS[@]}"; do
        PARAM_STRING="$PARAM_STRING $param"
    done

    # Deploy
    if [ "$OPERATION" = "create-stack" ]; then
        aws cloudformation create-stack \
            --stack-name "$STACK_NAME" \
            --template-body file://"$CFN_TEMPLATE" \
            --parameters $PARAM_STRING \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION" \
            --tags \
                Key=Project,Value=Nextcloud \
                Key=ManagedBy,Value=CloudFormation \
                Key=Environment,Value=Production

        log_success "Stack creation initiated"
    else
        aws cloudformation update-stack \
            --stack-name "$STACK_NAME" \
            --template-body file://"$CFN_TEMPLATE" \
            --parameters $PARAM_STRING \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION" \
            --tags \
                Key=Project,Value=Nextcloud \
                Key=ManagedBy,Value=CloudFormation \
                Key=Environment,Value=Production || {
            if [ $? -eq 254 ]; then
                log_warning "No updates to be performed"
                return
            else
                log_error "Stack update failed"
                exit 1
            fi
        }

        log_success "Stack update initiated"
    fi
}

wait_for_stack() {
    log_info "Waiting for stack to complete (this may take 15-20 minutes)..."

    if [ "$OPERATION" = "create-stack" ]; then
        WAIT_CMD="stack-create-complete"
    else
        WAIT_CMD="stack-update-complete"
    fi

    if aws cloudformation wait "$WAIT_CMD" \
        --stack-name "$STACK_NAME" \
        --region "$REGION"; then
        log_success "Stack deployment completed successfully!"
    else
        log_error "Stack deployment failed"
        log_info "Check CloudFormation console for details"
        exit 1
    fi
}

display_outputs() {
    log_info "Retrieving stack outputs..."

    OUTPUTS=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs' \
        --output json)

    echo ""
    echo "========================================================================"
    echo "  Deployment Complete!"
    echo "========================================================================"
    echo ""

    if command -v jq &> /dev/null; then
        echo "$OUTPUTS" | jq -r '.[] | "\(.OutputKey): \(.OutputValue)"'
    else
        echo "$OUTPUTS"
    fi

    echo ""
    echo "========================================================================"
    echo ""

    # Extract important values
    ALB_DNS=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="LoadBalancerDNS") | .OutputValue')
    NEXTCLOUD_URL=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="LoadBalancerURL") | .OutputValue')

    log_success "Nextcloud URL: $NEXTCLOUD_URL"
    echo ""
    log_info "Next Steps:"
    echo "  1. Access Nextcloud at: $NEXTCLOUD_URL"
    echo "  2. Wait 5-10 minutes for initial setup to complete"
    echo "  3. Login with username: admin"
    echo "  4. Password is stored in AWS Secrets Manager"
    echo ""

    if [ -n "${DOMAIN_NAME:-}" ]; then
        log_info "DNS Configuration:"
        echo "  Point your domain '$DOMAIN_NAME' to:"
        echo "  CNAME: $ALB_DNS"
        echo ""
    fi
}

cleanup_on_failure() {
    log_error "Deployment failed!"
    log_info "To view error details:"
    echo "  aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $REGION"
    echo ""
    log_info "To delete the failed stack:"
    echo "  aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION"
}

main() {
    echo "========================================================================"
    echo "  Nextcloud AWS Deployment Script"
    echo "========================================================================"
    echo ""

    # Check prerequisites
    check_prerequisites

    # Validate template
    validate_template

    # Load config if exists
    load_config

    # Get parameters
    prompt_for_parameters

    # Build parameters
    build_parameters

    # Estimate cost
    estimate_cost

    # Confirm deployment
    echo ""
    log_warning "Ready to deploy!"
    echo "  Stack Name: $STACK_NAME"
    echo "  Region: $REGION"
    echo "  Min Tasks: $MIN_TASKS"
    echo "  Max Tasks: $MAX_TASKS"
    echo ""
    read -p "Proceed with deployment? (y/n): " answer
    if [ "$answer" != "y" ]; then
        log_info "Deployment cancelled"
        exit 0
    fi

    # Deploy
    deploy_stack

    # Wait for completion
    wait_for_stack

    # Display outputs
    display_outputs

    log_success "Deployment completed successfully!"
}

# Trap errors
trap cleanup_on_failure ERR

# Run main
main "$@"
