#!/bin/bash

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
echo "  CloudForge - Deployment Diagnostics"
echo "=========================================="
echo ""

print_info "Checking deployment status..."
echo ""

# 1. Check deployment status
print_info "1. Deployment Status:"
kubectl get deployment auth-service -n microservices
echo ""

# 2. Check pods
print_info "2. Pod Status:"
kubectl get pods -n microservices -l app=auth-service
echo ""

# 3. Check pod details
print_info "3. Pod Details:"
PODS=$(kubectl get pods -n microservices -l app=auth-service -o jsonpath='{.items[*].metadata.name}')

for POD in $PODS; do
    echo "----------------------------------------"
    echo "Pod: $POD"
    echo "----------------------------------------"
    
    # Get pod status
    STATUS=$(kubectl get pod $POD -n microservices -o jsonpath='{.status.phase}')
    echo "Status: $STATUS"
    
    # Get container status
    CONTAINER_STATUS=$(kubectl get pod $POD -n microservices -o jsonpath='{.status.containerStatuses[0].state}')
    echo "Container State: $CONTAINER_STATUS"
    
    # Check if waiting
    WAITING_REASON=$(kubectl get pod $POD -n microservices -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
    if [ -n "$WAITING_REASON" ]; then
        print_error "Waiting Reason: $WAITING_REASON"
        
        WAITING_MESSAGE=$(kubectl get pod $POD -n microservices -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null)
        if [ -n "$WAITING_MESSAGE" ]; then
            echo "Message: $WAITING_MESSAGE"
        fi
    fi
    
    # Check events
    echo ""
    echo "Recent Events:"
    kubectl get events -n microservices --field-selector involvedObject.name=$POD --sort-by='.lastTimestamp' | tail -5
    echo ""
    
    # Show last 20 lines of logs
    echo "Last 20 Log Lines:"
    kubectl logs $POD -n microservices --tail=20 2>&1 || echo "No logs available yet"
    echo ""
done

# 4. Check secrets
print_info "4. Checking Secrets:"
if kubectl get secret auth-service-secrets -n microservices >/dev/null 2>&1; then
    print_success "Secret exists"
    kubectl get secret auth-service-secrets -n microservices -o jsonpath='{.data}' | jq -r 'keys[]'
else
    print_error "Secret not found"
fi
echo ""

# 5. Check events in namespace
print_info "5. Recent Events in Namespace:"
kubectl get events -n microservices --sort-by='.lastTimestamp' | tail -10
echo ""

# 6. Check image pull
print_info "6. Checking Image Status:"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/cloudforge-microservices-platform/auth-service:latest"

echo "Expected Image: $IMAGE"
echo ""

# Try to pull image info from ECR
print_info "Checking ECR for image..."
if aws ecr describe-images --repository-name cloudforge-microservices-platform/auth-service --region us-east-1 --image-ids imageTag=latest >/dev/null 2>&1; then
    print_success "Image exists in ECR"
    aws ecr describe-images --repository-name cloudforge-microservices-platform/auth-service --region us-east-1 --image-ids imageTag=latest --query 'imageDetails[0].[imagePushedAt,imageSizeInBytes]' --output table
else
    print_error "Image not found in ECR"
    echo ""
    print_warning "You need to build and push the image first:"
    echo "  ./build-and-push.sh"
fi
echo ""

# 7. Describe deployment
print_info "7. Deployment Details:"
kubectl describe deployment auth-service -n microservices | grep -A 10 "Conditions:"
echo ""

# 8. Check node resources
print_info "8. Node Resources:"
kubectl top nodes 2>/dev/null || print_warning "Metrics server not ready yet"
echo ""

# 9. Check if pods can be scheduled
print_info "9. Checking if pods can be scheduled:"
PENDING_PODS=$(kubectl get pods -n microservices -l app=auth-service --field-selector=status.phase=Pending -o jsonpath='{.items[*].metadata.name}')

if [ -n "$PENDING_PODS" ]; then
    print_warning "Pods stuck in Pending state"
    for POD in $PENDING_PODS; do
        echo "Checking pod: $POD"
        kubectl describe pod $POD -n microservices | grep -A 5 "Events:"
    done
else
    print_success "No pods stuck in Pending"
fi
echo ""

# 10. Summary and recommendations
echo "=========================================="
print_info "DIAGNOSIS SUMMARY"
echo "=========================================="
echo ""

# Get pod statuses
RUNNING=$(kubectl get pods -n microservices -l app=auth-service --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)
PENDING=$(kubectl get pods -n microservices -l app=auth-service --field-selector=status.phase=Pending -o jsonpath='{.items[*].metadata.name}' | wc -w)
FAILED=$(kubectl get pods -n microservices -l app=auth-service --field-selector=status.phase=Failed -o jsonpath='{.items[*].metadata.name}' | wc -w)

echo "Pod Status:"
echo "  Running: $RUNNING"
echo "  Pending: $PENDING"
echo "  Failed: $FAILED"
echo ""

# Provide recommendations
print_info "RECOMMENDED ACTIONS:"
echo ""

if [ $RUNNING -eq 0 ]; then
    # No pods running - check common issues
    
    # Check if image exists
    if ! aws ecr describe-images --repository-name microservices/auth-service --region us-east-1 --image-ids imageTag=latest >/dev/null 2>&1; then
        print_error "Issue: Docker image not found in ECR"
        echo "  Solution: Build and push the image"
        echo "  Command: ./build-and-push.sh"
        echo ""
    fi
    
    # Check for ImagePullBackOff
    IMAGE_PULL_ERROR=$(kubectl get pods -n microservices -l app=auth-service -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
    if [ "$IMAGE_PULL_ERROR" = "ImagePullBackOff" ] || [ "$IMAGE_PULL_ERROR" = "ErrImagePull" ]; then
        print_error "Issue: Cannot pull Docker image"
        echo "  Possible causes:"
        echo "    1. Image doesn't exist in ECR"
        echo "    2. ECR permissions issue"
        echo "    3. Wrong image name/tag"
        echo ""
        echo "  Solutions:"
        echo "    1. Verify image exists: aws ecr describe-images --repository-name microservices/auth-service --region us-east-1"
        echo "    2. Check node IAM role has ECR pull permissions"
        echo "    3. Verify image name in deployment manifest"
        echo ""
    fi
    
    # Check for CrashLoopBackOff
    if [ "$IMAGE_PULL_ERROR" = "CrashLoopBackOff" ]; then
        print_error "Issue: Container keeps crashing"
        echo "  Check logs for errors:"
        FIRST_POD=$(kubectl get pods -n microservices -l app=auth-service -o jsonpath='{.items[0].metadata.name}')
        echo "  Command: kubectl logs $FIRST_POD -n microservices"
        echo ""
    fi
    
    # Check for pending pods
    if [ $PENDING -gt 0 ]; then
        print_error "Issue: Pods stuck in Pending"
        echo "  Possible causes:"
        echo "    1. Insufficient node resources"
        echo "    2. Node selector not matching"
        echo "    3. PVC not available"
        echo ""
        echo "  Check with:"
        FIRST_PENDING=$(kubectl get pods -n microservices -l app=auth-service --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
        echo "  kubectl describe pod $FIRST_PENDING -n microservices"
        echo ""
    fi
else
    print_success "Pods are running!"
    echo "  You may need to wait for readiness probes to pass"
    echo ""
fi

# Quick fix commands
print_info "QUICK FIX COMMANDS:"
echo ""
echo "1. View detailed pod status:"
echo "   kubectl describe pod <pod-name> -n microservices"
echo ""
echo "2. View logs:"
echo "   kubectl logs -f deployment/auth-service -n microservices"
echo ""
echo "3. Delete and recreate deployment:"
echo "   kubectl delete deployment auth-service -n microservices"
echo "   kubectl apply -f kubernetes/base/auth-service/"
echo ""
echo "4. Force rollout restart:"
echo "   kubectl rollout restart deployment/auth-service -n microservices"
echo ""
echo "5. Check all resources:"
echo "   kubectl get all -n microservices"
echo ""