#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Banner
echo "=========================================="
echo "  Microservices Platform Deployment"
echo "=========================================="
echo ""

# Step 1: Verify Prerequisites
print_info "Step 1: Verifying prerequisites..."

REQUIRED_COMMANDS=("terraform" "aws" "kubectl" "helm" "git")
MISSING_COMMANDS=()

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command_exists "$cmd"; then
        MISSING_COMMANDS+=("$cmd")
    fi
done

if [ ${#MISSING_COMMANDS[@]} -ne 0 ]; then
    print_error "Missing required commands: ${MISSING_COMMANDS[*]}"
    print_info "Please install the missing commands and try again."
    exit 1
fi

print_info "All prerequisites satisfied ✓"
echo ""

# Step 2: Get AWS Account ID
print_info "Step 2: Getting AWS account information..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="us-east-1"

if [ -z "$AWS_ACCOUNT_ID" ]; then
    print_error "Failed to get AWS account ID. Please check your AWS credentials."
    exit 1
fi

print_info "AWS Account ID: $AWS_ACCOUNT_ID"
print_info "AWS Region: $AWS_REGION"
echo ""

# Step 3: Create S3 bucket for Terraform state
print_info "Step 3: Creating S3 bucket for Terraform state..."
BUCKET_NAME="microservices-terraform-state-${AWS_ACCOUNT_ID}"

if aws s3 ls "s3://${BUCKET_NAME}" 2>&1 | grep -q 'NoSuchBucket'; then
    aws s3api create-bucket \
        --bucket "${BUCKET_NAME}" \
        --region "${AWS_REGION}"
    
    aws s3api put-bucket-versioning \
        --bucket "${BUCKET_NAME}" \
        --versioning-configuration Status=Enabled
    
    print_info "S3 bucket created: ${BUCKET_NAME} ✓"
else
    print_info "S3 bucket already exists: ${BUCKET_NAME} ✓"
fi
echo ""

# Step 4: Create DynamoDB table for state locking
print_info "Step 4: Creating DynamoDB table for state locking..."

if aws dynamodb describe-table --table-name terraform-state-lock --region "${AWS_REGION}" 2>&1 | grep -q 'ResourceNotFoundException'; then
    aws dynamodb create-table \
        --table-name terraform-state-lock \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "${AWS_REGION}"
    
    print_info "DynamoDB table created: terraform-state-lock ✓"
else
    print_info "DynamoDB table already exists: terraform-state-lock ✓"
fi
echo ""

# Step 5: Update Terraform backend configuration
print_info "Step 5: Updating Terraform backend configuration..."
cd terraform/environments/prod

# Update the backend configuration with actual account ID
sed -i.bak "s/YOUR_ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" main.tf
rm -f main.tf.bak

print_info "Backend configuration updated ✓"
echo ""

# Step 6: Initialize Terraform
print_info "Step 6: Initializing Terraform..."
terraform init

print_info "Terraform initialized ✓"
echo ""

# Step 7: Validate Terraform configuration
print_info "Step 7: Validating Terraform configuration..."
terraform validate

print_info "Terraform configuration valid ✓"
echo ""

# Step 8: Plan Terraform deployment
print_info "Step 8: Planning Terraform deployment..."
terraform plan -out=tfplan

print_info "Terraform plan created ✓"
echo ""

# Step 9: Ask for confirmation
print_warning "Step 9: Ready to deploy infrastructure"
echo ""
echo "This will create:"
echo "  - VPC with public/private subnets across 3 AZs"
echo "  - NAT Gateways (3)"
echo "  - EKS Cluster with managed node group"
echo "  - RDS PostgreSQL database"
echo "  - ElastiCache Redis cluster"
echo "  - S3 buckets and CloudFront distribution"
echo "  - ECR repositories for 5 microservices"
echo ""
print_warning "This will incur AWS costs. Estimated: ~\$150-200/month"
echo ""
read -p "Do you want to proceed? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    print_info "Deployment cancelled by user."
    exit 0
fi
echo ""

# Step 10: Apply Terraform
print_info "Step 10: Applying Terraform configuration..."
print_warning "This will take approximately 15-20 minutes..."
terraform apply tfplan

print_info "Infrastructure deployment complete ✓"
echo ""

# Step 11: Get outputs
print_info "Step 11: Retrieving infrastructure outputs..."
CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
REDIS_ENDPOINT=$(terraform output -raw redis_endpoint)
# CLOUDFRONT_DOMAIN=$(terraform output -raw cloudfront_domain)

echo ""
echo "=========================================="
echo "  Infrastructure Details"
echo "=========================================="
echo "EKS Cluster: $CLUSTER_NAME"
echo "RDS Endpoint: $RDS_ENDPOINT"
echo "Redis Endpoint: $REDIS_ENDPOINT"
# echo "CloudFront Domain: $CLOUDFRONT_DOMAIN"
echo "=========================================="
echo ""

# Step 12: Configure kubectl
print_info "Step 12: Configuring kubectl..."
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

print_info "kubectl configured ✓"
echo ""

# Step 13: Verify cluster access
print_info "Step 13: Verifying cluster access..."
kubectl get nodes

print_info "Cluster access verified ✓"
echo ""

# Step 14: Install AWS Load Balancer Controller
print_info "Step 14: Installing AWS Load Balancer Controller..."

# Create IAM OIDC provider
print_info "Creating IAM OIDC provider..."
eksctl utils associate-iam-oidc-provider \
    --region="${AWS_REGION}" \
    --cluster="${CLUSTER_NAME}" \
    --approve || true

# Download IAM policy
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.6.0/docs/install/iam_policy.json

# Create IAM policy
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json || true

# Create service account
eksctl create iamserviceaccount \
    --cluster="${CLUSTER_NAME}" \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --approve

# Add Helm repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="${CLUSTER_NAME}" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller

print_info "AWS Load Balancer Controller installed ✓"
echo ""

# Step 15: Install Metrics Server
print_info "Step 15: Installing Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

print_info "Metrics Server installed ✓"
echo ""

# Step 16: Create namespaces
print_info "Step 16: Creating application namespaces..."
kubectl create namespace microservices || true
kubectl create namespace monitoring || true
kubectl create namespace argocd || true

print_info "Namespaces created ✓"
echo ""

# Step 17: Save connection information
print_info "Step 17: Saving connection information..."
cd ../../..

cat > connection-info.txt <<EOF
========================================
  Microservices Platform Connection Info
========================================

AWS Account ID: ${AWS_ACCOUNT_ID}
AWS Region: ${AWS_REGION}

EKS Cluster Name: ${CLUSTER_NAME}
RDS Endpoint: ${RDS_ENDPOINT}
Redis Endpoint: ${REDIS_ENDPOINT}


To connect to the cluster:
  aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

To view nodes:
  kubectl get nodes

To view all resources:
  kubectl get all -A

Next Steps:
1. Deploy microservices
2. Install ArgoCD
3. Configure monitoring stack
4. Set up CI/CD pipelines

EOF

cat connection-info.txt

print_info "Connection info saved to connection-info.txt ✓"
echo ""

# Final message
echo ""
echo "=========================================="
print_info "Infrastructure deployment complete!"
echo "=========================================="
echo ""
print_info "Next steps:"
echo "  1. Review connection-info.txt for cluster details"
echo "  2. Run ./deploy-microservices.sh to deploy applications"
echo "  3. Run ./setup-monitoring.sh to install monitoring stack"
echo "  4. Run ./setup-argocd.sh to configure GitOps"
echo ""
print_warning "Remember: This infrastructure will incur AWS costs"
print_info "To destroy everything later: cd terraform/environments/prod && terraform destroy"
echo ""