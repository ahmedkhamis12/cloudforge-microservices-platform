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
echo "  CloudForge - Build & Push Images"
echo "=========================================="
echo ""

# Get AWS info
print_info "Getting AWS account information..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="us-east-1"

print_success "AWS Account: $AWS_ACCOUNT_ID"
print_success "Region: $AWS_REGION"
echo ""

# ECR Repository base
ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Step 1: Login to ECR
print_info "Step 1: Logging into Amazon ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_BASE

print_success "Logged into ECR"
echo ""

# Step 2: Check if auth-service exists
print_info "Step 2: Checking services directory..."

if [ ! -d "services/auth-service" ]; then
    print_error "services/auth-service directory not found"
    echo ""
    print_info "Creating auth-service structure..."
    mkdir -p services/auth-service/src
    
    print_warning "Please add your service code to services/auth-service/"
    print_info "Required files:"
    echo "  - services/auth-service/Dockerfile"
    echo "  - services/auth-service/package.json"
    echo "  - services/auth-service/src/index.js"
    echo ""
    exit 1
fi

print_success "Service directory found"
echo ""

# Step 3: Build and push auth-service
print_info "Step 3: Building auth-service..."
cd services/auth-service

if [ ! -f "Dockerfile" ]; then
    print_error "Dockerfile not found in services/auth-service/"
    echo ""
    print_info "Creating Dockerfile..."
    
    cat > Dockerfile <<'EOF'
FROM node:18-alpine AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

COPY . .

FROM node:18-alpine

RUN apk add --no-cache dumb-init && \
    addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001

WORKDIR /app
COPY --from=builder --chown=nodejs:nodejs /app .

USER nodejs
EXPOSE 3001

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3001/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1))"

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/index.js"]
EOF
    
    print_success "Dockerfile created"
fi

if [ ! -f "package.json" ]; then
    print_error "package.json not found in services/auth-service/"
    echo ""
    print_info "Creating package.json..."
    
    cat > package.json <<'EOF'
{
  "name": "auth-service",
  "version": "1.0.0",
  "description": "CloudForge Authentication Service",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "nodemon src/index.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "jsonwebtoken": "^9.0.2",
    "bcrypt": "^5.1.1",
    "pg": "^8.11.3",
    "ioredis": "^5.3.2",
    "prom-client": "^15.1.0",
    "morgan": "^1.10.0",
    "helmet": "^7.1.0",
    "cors": "^2.8.5",
    "dotenv": "^16.3.1"
  }
}
EOF
    
    print_success "package.json created"
fi

if [ ! -f "src/index.js" ]; then
    print_warning "src/index.js not found - creating a basic service"
    mkdir -p src
    
    cat > src/index.js <<'EOF'
const express = require('express');
const app = express();

app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ 
    status: 'healthy',
    service: 'auth-service',
    timestamp: new Date().toISOString()
  });
});

app.get('/ready', (req, res) => {
  res.json({ ready: true });
});

app.get('/metrics', (req, res) => {
  res.set('Content-Type', 'text/plain');
  res.send('# Metrics endpoint');
});

const PORT = process.env.PORT || 3001;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Auth service listening on port ${PORT}`);
});
EOF
    
    print_success "Basic service created"
fi

print_info "Building Docker image..."
docker build -t auth-service:latest . --quiet

print_success "Docker image built"

# Tag for ECR
print_info "Tagging image for ECR..."
docker tag auth-service:latest ${ECR_BASE}/cloudforge-microservices-platform/auth-service:latest
docker tag auth-service:latest ${ECR_BASE}/cloudforge-microservices-platform/auth-service:v1.0.0
docker tag auth-service:latest ${ECR_BASE}/cloudforge-microservices-platform/auth-service:$(git rev-parse --short HEAD 2>/dev/null || echo "manual")

print_success "Image tagged"

# Push to ECR
print_info "Pushing to ECR..."
docker push ${ECR_BASE}/cloudforge-microservices-platform/auth-service:latest --quiet
docker push ${ECR_BASE}/cloudforge-microservices-platform/auth-service:v1.0.0 --quiet

print_success "Image pushed to ECR"

cd ../..
echo ""

# Step 4: Summary
echo "=========================================="
print_success "Build & Push Complete!"
echo "=========================================="
echo ""

print_info "Image Details:"
echo "  Repository: ${ECR_BASE}/cloudforge-microservices-platform/auth-service"
echo "  Tags: latest, v1.0.0"
echo ""

print_info "View in ECR:"
echo "  aws ecr describe-images --repository-name cloudforge-microservices-platform/auth-service --region $AWS_REGION"
echo ""

# Save image info
cat > image-info.txt <<EOF
CloudForge - Docker Images
==========================

Built: $(date)

Auth Service:
  Repository: ${ECR_BASE}/cloudforge-microservices-platform/auth-service
  Tags: latest, v1.0.0
  
ECR Login Command:
  aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_BASE

List Images:
  aws ecr list-images --repository-name cloudforge-microservices-platform/auth-service --region $AWS_REGION

Pull Image:
  docker pull ${ECR_BASE}/cloudforge-microservices-platform/auth-service:latest

Next Steps:
1. Deploy to Kubernetes: ./deploy-services.sh
2. Verify deployment: kubectl get pods -n microservices
3. Test service: kubectl port-forward svc/auth-service 3001:80 -n microservices

EOF

print_success "Image info saved to image-info.txt"
echo ""

print_info "Next step: Deploy to Kubernetes"
echo "  Run: ./deploy-services.sh"
echo ""