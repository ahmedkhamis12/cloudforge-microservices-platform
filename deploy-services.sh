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
echo "  CloudForge - Deploy Services"
echo "=========================================="
echo ""

# Get AWS info
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="us-east-1"
ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

print_success "AWS Account: $AWS_ACCOUNT_ID"
print_success "Region: $AWS_REGION"
echo ""

# Step 1: Verify cluster access
print_info "Step 1: Verifying cluster access..."

if ! kubectl cluster-info >/dev/null 2>&1; then
    print_error "Cannot connect to Kubernetes cluster"
    print_info "Run: aws eks update-kubeconfig --region $AWS_REGION --name <cluster-name>"
    exit 1
fi

print_success "Connected to cluster"
echo ""

# Step 2: Get database and Redis credentials
print_info "Step 2: Getting database credentials..."

cd terraform/environments/prod

# Get RDS info
if terraform output db_instance_endpoint >/dev/null 2>&1; then
    DB_ENDPOINT=$(terraform output -raw db_instance_endpoint)
    DB_HOST=$(echo $DB_ENDPOINT | cut -d: -f1)
    DB_PORT=$(echo $DB_ENDPOINT | cut -d: -f2)
    
    print_success "RDS endpoint: $DB_ENDPOINT"
else
    print_warning "Could not get RDS endpoint from Terraform"
    DB_HOST="localhost"
    DB_PORT="5432"
fi

# Get DB password from Secrets Manager
DB_SECRET_ARN=$(aws secretsmanager list-secrets --query "SecretList[?contains(Name, 'db-password')].ARN" --output text 2>/dev/null)

if [ -n "$DB_SECRET_ARN" ]; then
    DB_CREDENTIALS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --query SecretString --output text)
    DB_USER=$(echo $DB_CREDENTIALS | jq -r '.username')
    DB_PASSWORD=$(echo $DB_CREDENTIALS | jq -r '.password')
    DB_NAME=$(echo $DB_CREDENTIALS | jq -r '.dbname')
    
    print_success "Retrieved database credentials from Secrets Manager"
else
    print_warning "Could not find database credentials in Secrets Manager"
    DB_USER="admin"
    DB_PASSWORD="changeme"
    DB_NAME="microservices"
fi

# Get Redis info
if terraform output redis_endpoint >/dev/null 2>&1; then
    REDIS_ENDPOINT=$(terraform output -raw redis_endpoint)
    REDIS_HOST=$REDIS_ENDPOINT
    REDIS_PORT="6379"
    
    print_success "Redis endpoint: $REDIS_ENDPOINT"
else
    print_warning "Could not get Redis endpoint from Terraform"
    REDIS_HOST="localhost"
    REDIS_PORT="6379"
fi

# Get Redis password from Secrets Manager
REDIS_SECRET_ARN=$(aws secretsmanager list-secrets --query "SecretList[?contains(Name, 'redis-auth')].ARN" --output text 2>/dev/null)

if [ -n "$REDIS_SECRET_ARN" ]; then
    REDIS_CREDENTIALS=$(aws secretsmanager get-secret-value --secret-id "$REDIS_SECRET_ARN" --query SecretString --output text)
    REDIS_PASSWORD=$(echo $REDIS_CREDENTIALS | jq -r '.auth_token')
    
    print_success "Retrieved Redis credentials from Secrets Manager"
else
    print_warning "Could not find Redis credentials in Secrets Manager"
    REDIS_PASSWORD="changeme"
fi

cd ../../..
echo ""

# Step 3: Create Kubernetes secrets
print_info "Step 3: Creating Kubernetes secrets..."

# Generate JWT secret
JWT_SECRET=$(openssl rand -base64 32)

kubectl create secret generic auth-service-secrets \
    --from-literal=db-host="$DB_HOST" \
    --from-literal=db-port="$DB_PORT" \
    --from-literal=db-name="$DB_NAME" \
    --from-literal=db-user="$DB_USER" \
    --from-literal=db-password="$DB_PASSWORD" \
    --from-literal=redis-host="$REDIS_HOST" \
    --from-literal=redis-port="$REDIS_PORT" \
    --from-literal=redis-password="$REDIS_PASSWORD" \
    --from-literal=jwt-secret="$JWT_SECRET" \
    --from-literal=database-url="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}" \
    --from-literal=redis-url="redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}" \
    -n microservices \
    --dry-run=client -o yaml | kubectl apply -f -

print_success "Secrets created"
echo ""

# Step 4: Update Kubernetes manifests with ECR image URLs
print_info "Step 4: Updating Kubernetes manifests..."

if [ -d "kubernetes/base/auth-service" ]; then
    # Update image references
    find kubernetes/base -type f -name "*.yaml" -exec sed -i.bak "s|<ECR_REPO>|${ECR_BASE}/microservices|g" {} \;
    find kubernetes/base -type f -name "*.bak" -delete
    
    print_success "Manifests updated with ECR URLs"
else
    print_warning "kubernetes/base/auth-service directory not found"
    print_info "Creating basic Kubernetes manifests..."
    
    mkdir -p kubernetes/base/auth-service
    
    cat > kubernetes/base/auth-service/deployment.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: auth-service
  labels:
    app: auth-service
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service
  labels:
    app: auth-service
spec:
  replicas: 2
  selector:
    matchLabels:
      app: auth-service
  template:
    metadata:
      labels:
        app: auth-service
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "3001"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: auth-service
      containers:
      - name: auth-service
        image: ${ECR_BASE}/cloudforge-microservices-platform/auth-service:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 3001
          name: http
        env:
        - name: NODE_ENV
          value: "production"
        - name: PORT
          value: "3001"
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: auth-service-secrets
              key: db-host
        - name: DB_PORT
          valueFrom:
            secretKeyRef:
              name: auth-service-secrets
              key: db-port
        - name: DB_NAME
          valueFrom:
            secretKeyRef:
              name: auth-service-secrets
              key: db-name
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: auth-service-secrets
              key: db-user
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: auth-service-secrets
              key: db-password
        - name: REDIS_HOST
          valueFrom:
            secretKeyRef:
              name: auth-service-secrets
              key: redis-host
        - name: REDIS_PORT
          valueFrom:
            secretKeyRef:
              name: auth-service-secrets
              key: redis-port
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: auth-service-secrets
              key: redis-password
        - name: JWT_SECRET
          valueFrom:
            secretKeyRef:
              name: auth-service-secrets
              key: jwt-secret
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /health
            port: 3001
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 3001
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: auth-service
  labels:
    app: auth-service
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 3001
    protocol: TCP
    name: http
  selector:
    app: auth-service
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: auth-service-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: auth-service
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
EOF
    
    print_success "Created deployment manifest"
fi

echo ""

# Step 5: Deploy to Kubernetes
print_info "Step 5: Deploying auth-service to Kubernetes..."

kubectl apply -f kubernetes/base/auth-service/ -n microservices

print_success "Deployment applied"
echo ""

# Step 6: Wait for deployment
print_info "Step 6: Waiting for deployment to be ready..."
print_warning "This may take 2-3 minutes..."

kubectl rollout status deployment/auth-service -n microservices --timeout=600s

print_success "Deployment is ready!"
echo ""

# Step 7: Create Ingress
print_info "Step 7: Creating ingress..."

if [ ! -f "kubernetes/base/ingress.yaml" ]; then
    cat > kubernetes/base/ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cloudforge-ingress
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /health
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: auth-service
            port:
              number: 80
EOF
fi

kubectl apply -f kubernetes/base/ingress.yaml -n microservices

print_success "Ingress created"
echo ""

# Step 8: Wait for load balancer
print_info "Step 8: Waiting for load balancer (this takes 2-3 minutes)..."

for i in {1..60}; do
    LB_HOSTNAME=$(kubectl get ingress cloudforge-ingress -n microservices -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -n "$LB_HOSTNAME" ]; then
        print_success "Load balancer ready!"
        break
    fi
    
    echo -n "."
    sleep 5
done

echo ""
echo ""

# Step 9: Display deployment info
echo "=========================================="
print_success "Deployment Complete!"
echo "=========================================="
echo ""

print_info "Service Status:"
kubectl get pods -n microservices
echo ""

print_info "Service Endpoints:"
kubectl get svc -n microservices
echo ""

if [ -n "$LB_HOSTNAME" ]; then
    print_info "Load Balancer URL:"
    echo "  http://$LB_HOSTNAME"
    echo ""
    
    print_info "Test Commands:"
    echo "  # Health check"
    echo "  curl http://$LB_HOSTNAME/health"
    echo ""
    echo "  # Register user"
    echo "  curl -X POST http://$LB_HOSTNAME/api/auth/register \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"email\":\"test@example.com\",\"password\":\"password123\",\"username\":\"testuser\"}'"
    echo ""
else
    print_warning "Load balancer not ready yet. Check status with:"
    echo "  kubectl get ingress -n microservices -w"
fi

# Save deployment info
cat > deployment-info.txt <<EOF
CloudForge - Deployment Information
===================================

Deployed: $(date)

Namespace: microservices

Pods:
$(kubectl get pods -n microservices)

Services:
$(kubectl get svc -n microservices)

Ingress:
$(kubectl get ingress -n microservices)

Load Balancer URL:
  http://$LB_HOSTNAME

Database Connection:
  Host: $DB_HOST
  Port: $DB_PORT
  Database: $DB_NAME
  User: $DB_USER

Redis Connection:
  Host: $REDIS_HOST
  Port: $REDIS_PORT

Useful Commands:
  # View logs
  kubectl logs -f deployment/auth-service -n microservices
  
  # Port forward for local testing
  kubectl port-forward svc/auth-service 3001:80 -n microservices
  
  # Scale deployment
  kubectl scale deployment auth-service --replicas=5 -n microservices
  
  # View events
  kubectl get events -n microservices --sort-by='.lastTimestamp'
  
  # Restart deployment
  kubectl rollout restart deployment/auth-service -n microservices

Next Steps:
1. Install monitoring: ./setup-monitoring.sh
2. Configure ArgoCD: ./setup-argocd.sh
3. Add more microservices
4. Set up CI/CD pipelines

EOF

print_success "Deployment info saved to deployment-info.txt"
echo ""

print_info "Next steps:"
echo "  1. Test the service: curl http://$LB_HOSTNAME/health"
echo "  2. View logs: kubectl logs -f deployment/auth-service -n microservices"
echo "  3. Install monitoring: ./setup-monitoring.sh"
echo ""

print_success "All done! 🚀"