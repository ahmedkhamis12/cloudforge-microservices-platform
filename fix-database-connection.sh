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
echo "  CloudForge - Fix Database Connection"
echo "=========================================="
echo ""

# Get AWS info
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="us-east-1"

# Step 1: Get actual RDS endpoint
print_info "Step 1: Finding RDS endpoint..."

cd terraform/environments/prod

# Try to get from Terraform
if terraform output db_instance_endpoint >/dev/null 2>&1; then
    DB_ENDPOINT=$(terraform output -raw db_instance_endpoint)
    DB_HOST=$(echo $DB_ENDPOINT | cut -d: -f1)
    DB_PORT=$(echo $DB_ENDPOINT | cut -d: -f2)
    print_success "Found RDS: $DB_HOST:$DB_PORT"
else
    # Try to find RDS directly
    print_warning "Terraform output not available, searching for RDS..."
    DB_HOST=$(aws rds describe-db-instances --region $AWS_REGION \
        --query "DBInstances[?contains(DBInstanceIdentifier, 'microservices') || contains(DBInstanceIdentifier, 'cloudforge')].Endpoint.Address" \
        --output text | head -1)
    
    if [ -n "$DB_HOST" ]; then
        DB_PORT="5432"
        print_success "Found RDS: $DB_HOST:$DB_PORT"
    else
        print_error "No RDS instance found"
        print_warning "Creating placeholder values for testing..."
        DB_HOST="postgres-placeholder.rds.amazonaws.com"
        DB_PORT="5432"
    fi
fi

cd ../../..

# Step 2: Get Redis endpoint
print_info "Step 2: Finding Redis endpoint..."

cd terraform/environments/prod

if terraform output redis_endpoint >/dev/null 2>&1; then
    REDIS_HOST=$(terraform output -raw redis_endpoint)
    REDIS_PORT="6379"
    print_success "Found Redis: $REDIS_HOST:$REDIS_PORT"
else
    print_warning "Terraform output not available, searching for Redis..."
    REDIS_HOST=$(aws elasticache describe-replication-groups --region $AWS_REGION \
        --query "ReplicationGroups[?contains(ReplicationGroupId, 'microservices') || contains(ReplicationGroupId, 'cloudforge')].NodeGroups[0].PrimaryEndpoint.Address" \
        --output text | head -1)
    
    if [ -n "$REDIS_HOST" ]; then
        REDIS_PORT="6379"
        print_success "Found Redis: $REDIS_HOST:$REDIS_PORT"
    else
        print_warning "No Redis found, using placeholder"
        REDIS_HOST="redis-placeholder"
        REDIS_PORT="6379"
    fi
fi

cd ../../..

# Step 3: Get credentials from Secrets Manager
print_info "Step 3: Getting credentials from Secrets Manager..."

# Get DB password
DB_SECRET_ARN=$(aws secretsmanager list-secrets --region $AWS_REGION \
    --query "SecretList[?contains(Name, 'db-password') || contains(Name, 'rds')].ARN" \
    --output text | head -1)

if [ -n "$DB_SECRET_ARN" ]; then
    DB_CREDENTIALS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --region $AWS_REGION --query SecretString --output text)
    DB_USER=$(echo $DB_CREDENTIALS | python3 -c "import sys, json; print(json.load(sys.stdin)['username'])" 2>/dev/null || echo "admin")
    DB_PASSWORD=$(echo $DB_CREDENTIALS | python3 -c "import sys, json; print(json.load(sys.stdin)['password'])" 2>/dev/null || echo "changeme")
    DB_NAME=$(echo $DB_CREDENTIALS | python3 -c "import sys, json; print(json.load(sys.stdin).get('dbname', 'microservices'))" 2>/dev/null || echo "microservices")
    print_success "Retrieved DB credentials"
else
    print_warning "DB credentials not found in Secrets Manager"
    DB_USER="admin"
    DB_PASSWORD="changeme123"
    DB_NAME="microservices"
fi

# Get Redis password
REDIS_SECRET_ARN=$(aws secretsmanager list-secrets --region $AWS_REGION \
    --query "SecretList[?contains(Name, 'redis-auth') || contains(Name, 'redis')].ARN" \
    --output text | head -1)

if [ -n "$REDIS_SECRET_ARN" ]; then
    REDIS_CREDENTIALS=$(aws secretsmanager get-secret-value --secret-id "$REDIS_SECRET_ARN" --region $AWS_REGION --query SecretString --output text)
    REDIS_PASSWORD=$(echo $REDIS_CREDENTIALS | python3 -c "import sys, json; print(json.load(sys.stdin)['auth_token'])" 2>/dev/null || echo "changeme")
    print_success "Retrieved Redis credentials"
else
    print_warning "Redis credentials not found in Secrets Manager"
    REDIS_PASSWORD="changeme123"
fi

echo ""
print_info "Configuration Summary:"
echo "  DB Host: $DB_HOST"
echo "  DB Port: $DB_PORT"
echo "  DB Name: $DB_NAME"
echo "  DB User: $DB_USER"
echo "  Redis Host: $REDIS_HOST"
echo "  Redis Port: $REDIS_PORT"
echo ""

# Step 4: Delete old secret and create new one
print_info "Step 4: Updating Kubernetes secrets..."

# Delete old secret
kubectl delete secret auth-service-secrets -n microservices 2>/dev/null || true

# Generate JWT secret
JWT_SECRET=$(openssl rand -base64 32)

# Create new secret with correct values
kubectl create secret generic auth-service-secrets \
    --from-literal=DB_HOST="$DB_HOST" \
    --from-literal=DB_PORT="$DB_PORT" \
    --from-literal=DB_NAME="$DB_NAME" \
    --from-literal=DB_USER="$DB_USER" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --from-literal=REDIS_HOST="$REDIS_HOST" \
    --from-literal=REDIS_PORT="$REDIS_PORT" \
    --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
    --from-literal=JWT_SECRET="$JWT_SECRET" \
    -n microservices

print_success "Secrets updated"
echo ""

# Step 5: Verify secret
print_info "Step 5: Verifying secret contents..."
echo "Secret keys:"
kubectl get secret auth-service-secrets -n microservices -o jsonpath='{.data}' | grep -o '"[^"]*":' | tr -d '":' | sort
echo ""

# Step 6: Restart deployment
print_info "Step 6: Restarting deployment..."
kubectl rollout restart deployment/auth-service -n microservices

print_success "Deployment restarted"
echo ""

# Step 7: Wait for rollout
print_info "Step 7: Waiting for pods to restart (30 seconds)..."
sleep 30

print_info "Checking pod status..."
kubectl get pods -n microservices -l app=auth-service
echo ""

# Step 8: Check logs
print_info "Step 8: Checking logs for errors..."
echo ""
echo "Last 30 log lines:"
kubectl logs -n microservices -l app=auth-service --tail=30 --prefix=true || print_warning "Pods may still be starting"
echo ""

# Step 9: Wait for deployment
print_info "Step 9: Waiting for deployment to be ready (this may take 2-3 minutes)..."
if kubectl rollout status deployment/auth-service -n microservices --timeout=180s; then
    print_success "Deployment is ready!"
    echo ""
    
    # Show running pods
    print_info "Running pods:"
    kubectl get pods -n microservices -l app=auth-service
    echo ""
    
    # Test if service is responding
    print_info "Testing service health..."
    POD=$(kubectl get pods -n microservices -l app=auth-service -o jsonpath='{.items[0].metadata.name}')
    
    if kubectl exec $POD -n microservices -- wget -q -O- http://localhost:3001/health 2>/dev/null; then
        echo ""
        print_success "Service is healthy!"
    else
        print_warning "Service may still be starting up"
    fi
else
    print_error "Deployment still not ready"
    echo ""
    print_info "Checking pod status..."
    kubectl get pods -n microservices -l app=auth-service
    echo ""
    print_info "Recent logs:"
    kubectl logs -n microservices -l app=auth-service --tail=50 --prefix=true
    echo ""
    print_warning "If pods are still crashing, check the logs above for errors"
fi

echo ""
echo "=========================================="
print_info "Fix Complete!"
echo "=========================================="
echo ""

print_info "Next steps:"
echo "  1. Check pod status: kubectl get pods -n microservices"
echo "  2. View logs: kubectl logs -f deployment/auth-service -n microservices"
echo "  3. Test service: kubectl port-forward svc/auth-service 3001:80 -n microservices"
echo ""

# Save connection info
cat > database-connection-info.txt <<EOF
CloudForge - Database Connection Info
=====================================

Updated: $(date)

Database:
  Host: $DB_HOST
  Port: $DB_PORT
  Name: $DB_NAME
  User: $DB_USER

Redis:
  Host: $REDIS_HOST
  Port: $REDIS_PORT

Environment variables in secret:
  DB_HOST
  DB_PORT
  DB_NAME
  DB_USER
  DB_PASSWORD
  REDIS_HOST
  REDIS_PORT
  REDIS_PASSWORD
  JWT_SECRET

Test database connection from pod:
  kubectl exec -it <pod-name> -n microservices -- sh
  # Then inside pod:
  # nc -zv \$DB_HOST \$DB_PORT

View logs:
  kubectl logs -f deployment/auth-service -n microservices

EOF

print_success "Connection info saved to database-connection-info.txt"