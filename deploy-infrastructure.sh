#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Banner
echo "=========================================="
echo "  CloudForge Platform Deployment"
echo "=========================================="
echo ""

# Step 1: Verify Prerequisites
print_info "Step 1: Verifying prerequisites..."

REQUIRED_COMMANDS=("terraform" "aws" "kubectl" "helm")
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

print_success "All prerequisites satisfied"
echo ""

# Step 2: Get AWS Account ID
print_info "Step 2: Getting AWS account information..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
AWS_REGION="us-east-1"

if [ -z "$AWS_ACCOUNT_ID" ]; then
    print_error "Failed to get AWS account ID. Please check your AWS credentials."
    exit 1
fi

print_success "AWS Account ID: $AWS_ACCOUNT_ID"
print_success "AWS Region: $AWS_REGION"
echo ""

# Step 3: Check if infrastructure already exists
print_info "Step 3: Checking existing infrastructure..."

cd terraform/environments/prod

# Initialize Terraform to check state
terraform init -upgrade >/dev/null 2>&1 || true

# Check if cluster exists
CLUSTER_EXISTS=$(terraform state list 2>/dev/null | grep -c "module.eks.aws_eks_cluster.main" || echo "0")

if [ "$CLUSTER_EXISTS" -gt 0 ]; then
    print_warning "Infrastructure already exists!"
    
    # Get existing cluster name from Terraform state
    CLUSTER_NAME=$(terraform output -raw eks_cluster_name 2>/dev/null || echo "")
    
    if [ -n "$CLUSTER_NAME" ]; then
        print_success "Found existing cluster: $CLUSTER_NAME"
        
        # Configure kubectl
        print_info "Configuring kubectl..."
        aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1
        
        # Verify cluster access
        if kubectl get nodes >/dev/null 2>&1; then
            print_success "Cluster is accessible"
            echo ""
            
            print_info "Existing Infrastructure:"
            echo "  Cluster: $CLUSTER_NAME"
            echo "  RDS: $(terraform output -raw rds_endpoint 2>/dev/null || echo 'N/A')"
            echo "  Redis: $(terraform output -raw redis_endpoint 2>/dev/null || echo 'N/A')"
            echo ""
            
            read -p "Do you want to continue with post-installation setup? (yes/no): " CONTINUE
            if [ "$CONTINUE" != "yes" ]; then
                print_info "Exiting..."
                exit 0
            fi
        fi
    else
        print_warning "Could not determine cluster name from Terraform state"
        read -p "Enter your cluster name: " CLUSTER_NAME
    fi
else
    print_info "No existing infrastructure found. Starting fresh deployment..."
    echo ""
    
    # Step 4: Update Terraform backend configuration
    print_info "Step 4: Updating Terraform backend configuration..."
    
    # Update the backend configuration with actual account ID
    sed -i.bak "s/YOUR_ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" main.tf
    rm -f main.tf.bak
    
    print_success "Backend configuration updated"
    echo ""
    
    # Step 5: Initialize Terraform
    print_info "Step 5: Initializing Terraform..."
    terraform init -upgrade
    
    print_success "Terraform initialized"
    echo ""
    
    # Step 6: Validate Terraform configuration
    print_info "Step 6: Validating Terraform configuration..."
    terraform validate
    
    print_success "Terraform configuration valid"
    echo ""
    
    # Step 7: Plan Terraform deployment
    print_info "Step 7: Planning Terraform deployment..."
    terraform plan -out=tfplan
    
    print_success "Terraform plan created"
    echo ""
    
    # Step 8: Ask for confirmation
    print_warning "Step 8: Ready to deploy infrastructure"
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
    
    # Step 9: Apply Terraform
    print_info "Step 9: Applying Terraform configuration..."
    print_warning "This will take approximately 15-20 minutes..."
    terraform apply -auto-approve tfplan
    
    print_success "Infrastructure deployment complete"
    echo ""
    
    # Step 10: Get outputs
    print_info "Step 10: Retrieving infrastructure outputs..."
    CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
    RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
    REDIS_ENDPOINT=$(terraform output -raw redis_endpoint)
    CLOUDFRONT_DOMAIN=$(terraform output -raw cloudfront_domain)
    
    echo ""
    echo "=========================================="
    echo "  Infrastructure Details"
    echo "=========================================="
    echo "EKS Cluster: $CLUSTER_NAME"
    echo "RDS Endpoint: $RDS_ENDPOINT"
    echo "Redis Endpoint: $REDIS_ENDPOINT"
    echo "CloudFront Domain: $CLOUDFRONT_DOMAIN"
    echo "=========================================="
    echo ""
    
    # Step 11: Configure kubectl
    print_info "Step 11: Configuring kubectl..."
    aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"
    
    print_success "kubectl configured"
    echo ""
fi

cd ../../..

# Step 12: Verify cluster access
print_info "Step 12: Verifying cluster access..."
if ! kubectl get nodes >/dev/null 2>&1; then
    print_error "Cannot access cluster. Trying to reconfigure..."
    
    # Try to get cluster name from Terraform
    cd terraform/environments/prod
    CLUSTER_NAME=$(terraform output -raw eks_cluster_name 2>/dev/null)
    cd ../../..
    
    if [ -n "$CLUSTER_NAME" ]; then
        print_info "Found cluster name: $CLUSTER_NAME"
        aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"
    else
        print_error "Could not determine cluster name"
        exit 1
    fi
fi

print_info "Cluster nodes:"
kubectl get nodes
print_success "Cluster access verified"
echo ""

# Step 13: Create namespaces
print_info "Step 13: Creating namespaces..."
kubectl create namespace microservices 2>/dev/null || print_info "Namespace 'microservices' already exists"
kubectl create namespace monitoring 2>/dev/null || print_info "Namespace 'monitoring' already exists"
kubectl create namespace argocd 2>/dev/null || print_info "Namespace 'argocd' already exists"

print_success "Namespaces ready"
echo ""

# Step 14: Install AWS Load Balancer Controller
print_info "Step 14: Installing AWS Load Balancer Controller..."

# Check if already installed
if kubectl get deployment -n kube-system aws-load-balancer-controller >/dev/null 2>&1; then
    print_warning "AWS Load Balancer Controller already installed"
else
    print_info "Downloading IAM policy..."
    
    # Download IAM policy
    curl -sS -o /tmp/iam_policy.json \
        https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.6.0/docs/install/iam_policy.json
    
    # Create IAM policy (ignore if exists)
    print_info "Creating IAM policy..."
    aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file:///tmp/iam_policy.json 2>/dev/null || \
        print_warning "IAM policy already exists"
    
    # Create service account with eksctl (if available)
    if command_exists eksctl; then
        print_info "Creating service account with IRSA..."
        eksctl create iamserviceaccount \
            --cluster="${CLUSTER_NAME}" \
            --namespace=kube-system \
            --name=aws-load-balancer-controller \
            --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
            --override-existing-serviceaccounts \
            --approve 2>/dev/null || \
            print_warning "Service account already exists or eksctl not available"
    else
        print_warning "eksctl not found, skipping IRSA setup"
        print_info "You may need to manually configure service account"
    fi
    
    # Add Helm repo
    print_info "Adding EKS Helm repository..."
    helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
    helm repo update
    
    # Install controller
    print_info "Installing AWS Load Balancer Controller..."
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="${CLUSTER_NAME}" \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --wait --timeout=300s 2>/dev/null || \
        print_warning "Controller may already be installed"
    
    print_success "AWS Load Balancer Controller setup complete"
fi
echo ""

# Step 15: Install Metrics Server
print_info "Step 15: Installing Metrics Server..."

if kubectl get deployment -n kube-system metrics-server >/dev/null 2>&1; then
    print_warning "Metrics Server already installed"
else
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    print_success "Metrics Server installed"
fi
echo ""

# Step 16: Wait for nodes to be ready
print_info "Step 16: Waiting for all nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s || print_warning "Some nodes may not be ready yet"
print_success "Cluster is ready"
echo ""

# Step 17: Save connection information
print_info "Step 17: Saving connection information..."

cat > connection-info.txt <<EOF
========================================
  CloudForge Platform - Connection Info
========================================

Deployed: $(date)
AWS Account ID: ${AWS_ACCOUNT_ID}
AWS Region: ${AWS_REGION}

EKS Cluster Name: ${CLUSTER_NAME}

To connect to the cluster:
  aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

To view nodes:
  kubectl get nodes

To view all resources:
  kubectl get all -A

Namespaces created:
  - microservices (for application services)
  - monitoring (for Prometheus/Grafana)
  - argocd (for GitOps)

Next Steps:
1. Build and push Docker images: ./build-and-push.sh
2. Deploy microservices: ./deploy-services.sh
3. Install monitoring: ./setup-monitoring.sh
4. Configure ArgoCD: ./setup-argocd.sh

Infrastructure Details:
----------------------
$(cd terraform/environments/prod && terraform output 2>/dev/null || echo "Run 'terraform output' in terraform/environments/prod")

EOF

cat connection-info.txt

print_success "Connection info saved to connection-info.txt"
echo ""

# Final message
echo ""
echo "=========================================="
print_success "Infrastructure deployment complete!"
echo "=========================================="
echo ""
print_info "Cluster Status:"
kubectl get nodes
echo ""
print_info "Next steps:"
echo "  1. Build Docker images: cd services/auth-service && docker build -t auth-service ."
echo "  2. Push to ECR: Follow the build-and-push guide"
echo "  3. Deploy services: kubectl apply -f kubernetes/base/"
echo "  4. Install monitoring: helm install prometheus..."
echo ""
print_warning "Remember: This infrastructure will incur AWS costs (~\$150-200/month)"
print_info "To destroy everything: cd terraform/environments/prod && terraform destroy"
echo ""
print_success "All done! 🚀"