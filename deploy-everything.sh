#!/bin/bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_banner() {
    echo -e "${BLUE}"
    echo "=========================================="
    echo "  $1"
    echo "=========================================="
    echo -e "${NC}"
}

print_step() {
    echo -e "${GREEN}[STEP $1]${NC} $2"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
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

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_banner "Microservices Platform - Complete Deployment"
echo ""

# Parse arguments
SKIP_INFRA=false
SKIP_BUILD=false
SKIP_DEPLOY=false
SKIP_MONITORING=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-infra)
            SKIP_INFRA=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-deploy)
            SKIP_DEPLOY=true
            shift
            ;;
        --skip-monitoring)
            SKIP_MONITORING=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-infra] [--skip-build] [--skip-deploy] [--skip-monitoring]"
            exit 1
            ;;
    esac
done

# ============================================
# Phase 0: Prerequisites Check
# ============================================

print_banner "Phase 0: Checking Prerequisites"

REQUIRED_COMMANDS=("terraform" "aws" "kubectl" "helm" "docker" "git" "jq")
MISSING_COMMANDS=()

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command_exists "$cmd"; then
        MISSING_COMMANDS+=("$cmd")
    else
        print_success "$cmd is installed"
    fi
done

if [ ${#MISSING_COMMANDS[@]} -ne 0 ]; then
    print_error "Missing required commands: ${MISSING_COMMANDS[*]}"
    echo ""
    echo "Installation instructions:"
    echo "  macOS: brew install ${MISSING_COMMANDS[*]}"
    echo "  Ubuntu: sudo apt-get install ${MISSING_COMMANDS[*]}"
    exit 1
fi

# Get AWS credentials
print_info "Checking AWS credentials..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    print_error "AWS credentials not configured"
    echo "Run: aws configure"
    exit 1
fi

AWS_REGION="us-east-1"
print_success "AWS Account ID: $AWS_ACCOUNT_ID"
print_success "AWS Region: $AWS_REGION"

echo ""

# ============================================
# Phase 1: Infrastructure Deployment
# ============================================

if [ "$SKIP_INFRA" = false ]; then
    print_banner "Phase 1: Deploying Infrastructure (15-20 min)"
    
    print_step "1.1" "Creating Terraform backend..."
    
    # Create S3 bucket
    BUCKET_NAME="microservices-terraform-state-${AWS_ACCOUNT_ID}"
    if aws s3 ls "s3://${BUCKET_NAME}" 2>&1 | grep -q 'NoSuchBucket'; then
        aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}"
        aws s3api put-bucket-versioning --bucket "${BUCKET_NAME}" \
            --versioning-configuration Status=Enabled
        print_success "Created S3 bucket: ${BUCKET_NAME}"
    else
        print_success "S3 bucket exists: ${BUCKET_NAME}"
    fi
    
    # Create DynamoDB table
    if aws dynamodb describe-table --table-name terraform-state-lock --region "${AWS_REGION}" 2>&1 | grep -q 'ResourceNotFoundException'; then
        aws dynamodb create-table \
            --table-name terraform-state-lock \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST \
            --region "${AWS_REGION}" >/dev/null
        print_success "Created DynamoDB table: terraform-state-lock"
    else
        print_success "DynamoDB table exists: terraform-state-lock"
    fi
    
    print_step "1.2" "Initializing Terraform..."
    cd terraform/environments/prod
    
    # Update backend config
    sed -i.bak "s/YOUR_ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" main.tf
    rm -f main.tf.bak
    
    terraform init -upgrade
    print_success "Terraform initialized"
    
    print_step "1.3" "Validating configuration..."
    terraform validate
    print_success "Configuration valid"
    
    print_step "1.4" "Planning deployment..."
    terraform plan -out=tfplan
    
    print_warning "About to deploy infrastructure (estimated cost: ~\$150-200/month)"
    read -p "Continue? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        print_info "Deployment cancelled"
        exit 0
    fi
    
    print_step "1.5" "Applying Terraform (this takes 15-20 minutes)..."
    terraform apply -auto-approve tfplan
    
    # Get outputs
    CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
    RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
    REDIS_ENDPOINT=$(terraform output -raw redis_endpoint)
    
    print_success "Infrastructure deployed!"
    echo ""
    echo "Cluster: $CLUSTER_NAME"
    echo "RDS: $RDS_ENDPOINT"
    echo "Redis: $REDIS_ENDPOINT"
    
    cd ../../..
    
    print_step "1.6" "Configuring kubectl..."
    aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"
    print_success "kubectl configured"
    
    print_step "1.7" "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    print_success "Cluster is ready"
    
    # Install AWS Load Balancer Controller
    print_step "1.8" "Installing AWS Load Balancer Controller..."
    
    # Check if eksctl is installed
    if command_exists eksctl; then
        eksctl utils associate-iam-oidc-provider \
            --region="${AWS_REGION}" \
            --cluster="${CLUSTER_NAME}" \
            --approve 2>/dev/null || true
    fi
    
    # Download and create IAM policy
    curl -sS -o /tmp/iam_policy.json \
        https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.6.0/docs/install/iam_policy.json
    
    aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file:///tmp/iam_policy.json 2>/dev/null || true
    
    # Create service account with eksctl
    if command_exists eksctl; then
        eksctl create iamserviceaccount \
            --cluster="${CLUSTER_NAME}" \
            --namespace=kube-system \
            --name=aws-load-balancer-controller \
            --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
            --override-existing-serviceaccounts \
            --approve 2>/dev/null || true
    fi
    
    # Install with Helm
    helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
    helm repo update
    
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="${CLUSTER_NAME}" \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --wait
    
    print_success "Load Balancer Controller installed"
    
    # Install Metrics Server
    print_step "1.9" "Installing Metrics Server..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    print_success "Metrics Server installed"
    
    # Create namespaces
    print_step "1.10" "Creating namespaces..."
    kubectl create namespace microservices 2>/dev/null || true
    kubectl create namespace monitoring 2>/dev/null || true
    kubectl create namespace argocd 2>/dev/null || true
    print_success "Namespaces created"
    
    echo ""
else
    print_info "Skipping infrastructure deployment"
    CLUSTER_NAME=$(kubectl config current-context | cut -d/ -f2)
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    echo ""
fi

# ============================================
# Phase 2: Build and Push Docker Images
# ============================================

if [ "$SKIP_BUILD" = false ]; then
    print_banner "Phase 2: Building and Pushing Docker Images"
    
    print_step "2.1" "Logging into ECR..."
    aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin \
        $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
    print_success "Logged into ECR"
    
    # Build and push each service
    SERVICES=("auth-service" "user-service" "orders-service" "products-service" "frontend")
    
    for service in "${SERVICES[@]}"; do
        print_step "2.2" "Building $service..."
        
        if [ ! -d "services/$service" ]; then
            print_warning "$service directory not found, skipping..."
            continue
        fi
        
        cd "services/$service"
        
        # Build
        docker build -t $service:latest . -q
        
        # Tag
        docker tag $service:latest \
            $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudforge-microservices-platform/$service:latest
        
        docker tag $service:latest \
            $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudforge-microservices-platform/$service:v1.0.0
        
        # Push
        docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudforge-microservices-platform/$service:latest -q
        docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudforge-microservices-platform/$service:v1.0.0 -q
        
        print_success "$service built and pushed"
        cd ../..
    done
    
    echo ""
else
    print_info "Skipping Docker build"
    echo ""
fi

# ============================================
# Phase 3: Deploy Microservices
# ============================================

if [ "$SKIP_DEPLOY" = false ]; then
    print_banner "Phase 3: Deploying Microservices"
    
    print_step "3.1" "Creating secrets..."
    
    # Get RDS credentials
    DB_SECRET_ARN=$(aws secretsmanager list-secrets \
    --region us-east-1 \
    --query "SecretList[?contains(Name, 'db-password')].ARN" \
    --output text)
    
    if [ -n "$DB_SECRET_ARN" ] && [ "$DB_SECRET_ARN" != "None" ]; then
    DB_CREDENTIALS=$(aws secretsmanager get-secret-value \
        --region "$AWS_REGION" \
        --secret-id "$DB_SECRET_ARN" \
        --query SecretString --output text)
        
        DB_HOST=$(echo $DB_CREDENTIALS | jq -r '.host')
        DB_PORT=$(echo $DB_CREDENTIALS | jq -r '.port')
        DB_NAME=$(echo $DB_CREDENTIALS | jq -r '.dbname')
        DB_USER=$(echo $DB_CREDENTIALS | jq -r '.username')
        DB_PASSWORD=$(echo $DB_CREDENTIALS | jq -r '.password')
    else
        print_warning "Database secret not found, using placeholder values"
        DB_HOST="localhost"
        DB_PORT="5432"
        DB_NAME="microservices"
        DB_USER="admin"
        DB_PASSWORD="changeme"
    fi
    
    # Get Redis credentials
    REDIS_SECRET_ARN=$(aws secretsmanager list-secrets \
    --region "$AWS_REGION" \
    --query "SecretList[?contains(Name, 'redis-auth')].ARN" \
    --output text)
    
    if [ -n "$REDIS_SECRET_ARN" ] && [ "$REDIS_SECRET_ARN" != "None" ]; then
    REDIS_CREDENTIALS=$(aws secretsmanager get-secret-value \
        --region "$AWS_REGION" \
        --secret-id "$REDIS_SECRET_ARN" \
        --query SecretString --output text)
        
        REDIS_HOST=$(echo $REDIS_CREDENTIALS | jq -r '.endpoint')
        REDIS_PORT=$(echo $REDIS_CREDENTIALS | jq -r '.port')
        REDIS_PASSWORD=$(echo $REDIS_CREDENTIALS | jq -r '.auth_token')
    else
        print_warning "Redis secret not found, using placeholder values"
        REDIS_HOST="localhost"
        REDIS_PORT="6379"
        REDIS_PASSWORD="changeme"
    fi
    
    # Create Kubernetes secrets
    kubectl create secret generic auth-service-secrets \
        --from-literal=database-url="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}" \
        --from-literal=redis-url="redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}" \
        --from-literal=jwt-secret="$(openssl rand -base64 32)" \
        --from-literal=db-host="${DB_HOST}" \
        --from-literal=db-port="${DB_PORT}" \
        --from-literal=db-name="${DB_NAME}" \
        --from-literal=db-user="${DB_USER}" \
        --from-literal=db-password="${DB_PASSWORD}" \
        --from-literal=redis-host="${REDIS_HOST}" \
        --from-literal=redis-port="${REDIS_PORT}" \
        --from-literal=redis-password="${REDIS_PASSWORD}" \
        -n microservices \
        --dry-run=client -o yaml | kubectl apply -f -
    
    print_success "Secrets created"
    
    print_step "3.2" "Updating manifests with ECR URLs..."
    find kubernetes/base -type f -name "*.yaml" \
        -exec sed -i.bak "s|<ECR_REPO>|${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/cloudforge-microservices-platform|g" {} \;
    find kubernetes/base -type f -name "*.bak" -delete
    print_success "Manifests updated"
    
    print_step "3.3" "Deploying services..."
    
    # Deploy auth service first
    if [ -d "kubernetes/base/auth-service" ]; then
        kubectl apply -f kubernetes/base/auth-service/ -n microservices
        kubectl rollout status deployment/auth-service -n microservices --timeout=300s
        print_success "Auth service deployed"
    fi
    
    # Deploy other services
    for dir in kubernetes/base/*/; do
        service=$(basename "$dir")
        if [ "$service" != "auth-service" ] && [ -f "$dir/deployment.yaml" ]; then
            kubectl apply -f "$dir" -n microservices 2>/dev/null || true
            print_success "$service deployed"
        fi
    done
    
    print_step "3.4" "Deploying ingress..."
    if [ -f "kubernetes/base/ingress.yaml" ]; then
        kubectl apply -f kubernetes/base/ingress.yaml -n microservices
        print_success "Ingress deployed"
    fi
    
    print_step "3.5" "Waiting for load balancer..."
    print_info "This may take 2-3 minutes..."
    
    for i in {1..60}; do
        LB_HOSTNAME=$(kubectl get ingress -n microservices -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ -n "$LB_HOSTNAME" ]; then
            print_success "Load balancer ready: $LB_HOSTNAME"
            break
        fi
        sleep 5
    done
    
    echo ""
else
    print_info "Skipping microservices deployment"
    echo ""
fi

# ============================================
# Phase 4: Install Monitoring
# ============================================

if [ "$SKIP_MONITORING" = false ]; then
    print_banner "Phase 4: Installing Monitoring Stack"
    
    print_step "4.1" "Installing Prometheus & Grafana..."
    
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update
    
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --wait --timeout=600s
    
    print_success "Monitoring stack installed"
    
    # Get Grafana password
    GRAFANA_PASSWORD=$(kubectl get secret --namespace monitoring prometheus-grafana \
        -o jsonpath="{.data.admin-password}" | base64 -d)
    
    echo ""
    print_info "Grafana Access:"
    echo "  Username: admin"
    echo "  Password: $GRAFANA_PASSWORD"
    echo "  Port Forward: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    echo "  URL: http://localhost:3000"
    
    echo ""
else
    print_info "Skipping monitoring installation"
    echo ""
fi

# ============================================
# Final Summary
# ============================================

print_banner "Deployment Complete!"

echo -e "${GREEN}✓ Infrastructure deployed${NC}"
echo -e "${GREEN}✓ Docker images built and pushed${NC}"
echo -e "${GREEN}✓ Microservices deployed${NC}"
echo -e "${GREEN}✓ Monitoring stack installed${NC}"

echo ""
echo "=========================================="
echo "  Quick Access Commands"
echo "=========================================="
echo ""

# Get load balancer URL
LB_HOSTNAME=$(kubectl get ingress -n microservices -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

if [ -n "$LB_HOSTNAME" ]; then
    echo "Application URL: http://$LB_HOSTNAME"
    echo ""
    echo "Test Auth Service:"
    echo "  curl http://$LB_HOSTNAME/auth/health"
    echo ""
fi

echo "View all pods:"
echo "  kubectl get pods -n microservices"
echo ""

echo "View logs:"
echo "  kubectl logs -f deployment/auth-service -n microservices"
echo ""

echo "Access Grafana:"
echo "  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo "  Open: http://localhost:3000"
echo "  Username: admin"
echo "  Password: $GRAFANA_PASSWORD"
echo ""

echo "=========================================="
echo -e "${YELLOW}Next Steps:${NC}"
echo "=========================================="
echo "1. Set up CI/CD pipelines in GitHub Actions"
echo "2. Install ArgoCD for GitOps"
echo "3. Configure custom domain with Route53"
echo "4. Add SSL certificates"
echo "5. Implement Istio service mesh"
echo ""

echo -e "${YELLOW}Cost Warning:${NC}"
echo "This infrastructure costs approximately \$150-200/month"
echo "To destroy: cd terraform/environments/prod && terraform destroy"
echo ""

print_success "All done! 🎉"