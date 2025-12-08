#!/bin/bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo "=========================================="
echo "  CloudForge - Deployment Fixer"
echo "=========================================="
echo ""

print_info "This script will fix your current deployment issues"
echo ""

# Get AWS info
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="us-east-1"

print_success "AWS Account: $AWS_ACCOUNT_ID"
print_success "Region: $AWS_REGION"
echo ""

# Step 1: Find the actual cluster name
print_info "Step 1: Finding your EKS cluster..."

CLUSTERS=$(aws eks list-clusters --region $AWS_REGION --query 'clusters[]' --output text)

if [ -z "$CLUSTERS" ]; then
    print_error "No EKS clusters found in region $AWS_REGION"
    echo ""
    print_info "Checking if cluster is being created..."
    
    cd terraform/environments/prod 2>/dev/null || {
        print_error "Terraform directory not found"
        exit 1
    }
    
    terraform init -upgrade >/dev/null 2>&1
    
    print_info "Checking Terraform state..."
    if terraform state list | grep -q "aws_eks_cluster"; then
        print_info "Cluster exists in Terraform state"
        CLUSTER_NAME=$(terraform output -raw eks_cluster_name 2>/dev/null)
        
        if [ -n "$CLUSTER_NAME" ]; then
            print_success "Found cluster name in Terraform: $CLUSTER_NAME"
        else
            print_warning "Cluster may still be creating..."
            print_info "Checking cluster status..."
            
            # Try to get cluster name from state file
            CLUSTER_NAME=$(terraform state show module.eks.aws_eks_cluster.main 2>/dev/null | grep "name " | awk '{print $3}' | tr -d '"')
            
            if [ -n "$CLUSTER_NAME" ]; then
                print_info "Found cluster name: $CLUSTER_NAME"
                print_info "Checking cluster status in AWS..."
                
                CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region $AWS_REGION --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")
                
                if [ "$CLUSTER_STATUS" = "CREATING" ]; then
                    print_warning "Cluster is still being created. Status: $CLUSTER_STATUS"
                    print_info "Please wait for cluster creation to complete (usually 10-15 minutes)"
                    echo ""
                    print_info "You can check status with:"
                    echo "  aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.status'"
                    exit 0
                elif [ "$CLUSTER_STATUS" = "NOT_FOUND" ]; then
                    print_error "Cluster not found in AWS but exists in Terraform state"
                    print_warning "This might be a state inconsistency"
                    echo ""
                    print_info "Recommended actions:"
                    echo "  1. Wait 5 more minutes for cluster creation"
                    echo "  2. Check AWS Console for cluster status"
                    echo "  3. Or run: cd terraform/environments/prod && terraform destroy && terraform apply"
                    exit 1
                else
                    print_success "Cluster status: $CLUSTER_STATUS"
                fi
            fi
        fi
    else
        print_error "No cluster found in Terraform state"
        print_info "Starting fresh deployment..."
        terraform plan -out=tfplan
        read -p "Apply this plan? (yes/no): " APPLY
        if [ "$APPLY" = "yes" ]; then
            terraform apply tfplan
        fi
        exit 0
    fi
    
    cd ../../..
else
    echo "Found EKS clusters:"
    echo "$CLUSTERS"
    echo ""
    
    # If multiple clusters, ask user to choose
    CLUSTER_COUNT=$(echo "$CLUSTERS" | wc -w)
    
    if [ "$CLUSTER_COUNT" -eq 1 ]; then
        CLUSTER_NAME="$CLUSTERS"
        print_success "Using cluster: $CLUSTER_NAME"
    else
        print_warning "Multiple clusters found. Which one do you want to use?"
        select CLUSTER_NAME in $CLUSTERS; do
            if [ -n "$CLUSTER_NAME" ]; then
                print_success "Selected: $CLUSTER_NAME"
                break
            fi
        done
    fi
fi

echo ""

# Step 2: Configure kubectl
print_info "Step 2: Configuring kubectl..."
aws eks update-kubeconfig --region $AWS_REGION --name "$CLUSTER_NAME" --alias cloudforge

print_success "kubectl configured for cluster: $CLUSTER_NAME"
echo ""

# Step 3: Verify cluster access
print_info "Step 3: Verifying cluster access..."

if kubectl get nodes 2>/dev/null; then
    print_success "Successfully connected to cluster!"
    echo ""
    print_info "Cluster nodes:"
    kubectl get nodes
else
    print_error "Cannot connect to cluster"
    print_info "Waiting 30 seconds and retrying..."
    sleep 30
    
    if kubectl get nodes 2>/dev/null; then
        print_success "Connection successful on retry"
    else
        print_error "Still cannot connect. Cluster may not be ready yet."
        exit 1
    fi
fi

echo ""

# Step 4: Check namespaces
print_info "Step 4: Checking namespaces..."

for ns in microservices monitoring argocd; do
    if kubectl get namespace $ns >/dev/null 2>&1; then
        print_success "Namespace '$ns' exists"
    else
        print_info "Creating namespace '$ns'..."
        kubectl create namespace $ns
        print_success "Namespace '$ns' created"
    fi
done

echo ""

# Step 5: Check AWS Load Balancer Controller
print_info "Step 5: Checking AWS Load Balancer Controller..."

if kubectl get deployment -n kube-system aws-load-balancer-controller >/dev/null 2>&1; then
    print_success "AWS Load Balancer Controller is installed"
    
    # Check if it's running
    REPLICAS=$(kubectl get deployment -n kube-system aws-load-balancer-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    
    if [ "$REPLICAS" -gt 0 ]; then
        print_success "Controller is running ($REPLICAS replicas ready)"
    else
        print_warning "Controller is installed but not running"
        print_info "Checking pod status..."
        kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
    fi
else
    print_warning "AWS Load Balancer Controller not installed"
    print_info "Installing now..."
    
    # Install with basic configuration
    helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
    helm repo update
    
    # Create service account manually
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
EOF
    
    # Install controller
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --wait
    
    print_success "Controller installed"
fi

echo ""

# Step 6: Check Metrics Server
print_info "Step 6: Checking Metrics Server..."

if kubectl get deployment -n kube-system metrics-server >/dev/null 2>&1; then
    print_success "Metrics Server is installed"
else
    print_info "Installing Metrics Server..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    print_success "Metrics Server installed"
fi

echo ""

# Step 7: Summary
echo "=========================================="
print_success "Deployment Status Check Complete"
echo "=========================================="
echo ""

print_info "Cluster Information:"
echo "  Name: $CLUSTER_NAME"
echo "  Region: $AWS_REGION"
echo "  Endpoint: $(aws eks describe-cluster --name "$CLUSTER_NAME" --region $AWS_REGION --query 'cluster.endpoint' --output text 2>/dev/null || echo 'N/A')"
echo ""

print_info "Cluster Status:"
kubectl get nodes
echo ""

print_info "System Pods:"
kubectl get pods -n kube-system
echo ""

print_info "Ready to deploy applications!"
echo ""

# Save cluster info
cat > cluster-info.txt <<EOF
CloudForge Cluster Information
==============================

Cluster Name: $CLUSTER_NAME
Region: $AWS_REGION
AWS Account: $AWS_ACCOUNT_ID

Connection Command:
  aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

Kubectl Context:
  $(kubectl config current-context)

Nodes:
$(kubectl get nodes)

System Components:
- AWS Load Balancer Controller: $(kubectl get deployment -n kube-system aws-load-balancer-controller >/dev/null 2>&1 && echo "Installed" || echo "Not Installed")
- Metrics Server: $(kubectl get deployment -n kube-system metrics-server >/dev/null 2>&1 && echo "Installed" || echo "Not Installed")

Namespaces:
- microservices
- monitoring  
- argocd

Next Steps:
1. Build and push Docker images
2. Deploy microservices
3. Configure monitoring
4. Set up ArgoCD

Generated: $(date)
EOF

print_success "Cluster info saved to cluster-info.txt"
echo ""

print_info "Next steps:"
echo "  1. Review cluster-info.txt"
echo "  2. Build your Docker images"
echo "  3. Deploy microservices"
echo "  4. Set up monitoring stack"
echo ""

print_success "All systems ready! 🚀"