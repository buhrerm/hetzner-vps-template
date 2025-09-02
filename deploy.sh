#!/bin/bash

# Full Stack TypeGraphQL/Next.js Deployment Script for Hetzner VPS
# This script handles fresh deployment and updates

set -e

# Configuration - EDIT THESE
DOMAIN="example.com"
APP_NAME="myapp"
BACKEND_REPO="git@github.com:yourusername/backend.git"
FRONTEND_REPO="git@github.com:yourusername/frontend.git"
BACKEND_REPO_NAME="Backend"
FRONTEND_REPO_NAME="Frontend"
EMAIL="your-email@example.com"

echo "🚀 Starting deployment for $APP_NAME..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root"
  exit 1
fi

# Update system
echo "📦 Updating system packages..."
apt update && apt upgrade -y

# Install Docker
echo "🐳 Installing Docker..."
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  rm get-docker.sh
fi

# Install Docker Compose
echo "🐳 Installing Docker Compose..."
apt install -y docker-compose-plugin

# Install required tools
echo "🔧 Installing required tools..."
apt install -y git fail2ban ufw nginx certbot python3-certbot-nginx

# Create deployment user
echo "👤 Creating deployment user..."
if ! id "deploy" &>/dev/null; then
  useradd -m -s /bin/bash deploy
  usermod -aG docker deploy
fi

# Setup firewall
echo "🔥 Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
ufw allow 9000
ufw --force enable

# Create directory structure
echo "📁 Creating directory structure..."
mkdir -p /opt/deployment/{nginx/sites-enabled,certbot/{conf,www},webhook,secrets,env}
cd /opt

# Check for SSH keys
if [ ! -f "/root/.ssh/github_deploy_key_backend" ] || [ ! -f "/root/.ssh/github_deploy_key_frontend" ]; then
  echo "🔑 Generating SSH deploy keys..."
  mkdir -p /root/.ssh
  
  # Generate backend key
  ssh-keygen -t ed25519 -f /root/.ssh/github_deploy_key_backend -N "" -C "deploy-backend@$DOMAIN"
  
  # Generate frontend key
  ssh-keygen -t ed25519 -f /root/.ssh/github_deploy_key_frontend -N "" -C "deploy-frontend@$DOMAIN"
  
  echo ""
  echo "⚠️  IMPORTANT: Add these deploy keys to your GitHub repositories:"
  echo ""
  echo "Backend Repository Deploy Key:"
  cat /root/.ssh/github_deploy_key_backend.pub
  echo ""
  echo "Frontend Repository Deploy Key:"
  cat /root/.ssh/github_deploy_key_frontend.pub
  echo ""
  read -p "Press enter once you've added the deploy keys to GitHub..."
fi

# Clone repositories
echo "📥 Cloning repositories..."
cd /opt

if [ ! -d "$BACKEND_REPO_NAME" ]; then
  GIT_SSH_COMMAND="ssh -i /root/.ssh/github_deploy_key_backend -o StrictHostKeyChecking=no" \
    git clone $BACKEND_REPO $BACKEND_REPO_NAME
  cd $BACKEND_REPO_NAME
  git config core.sshCommand "ssh -i /root/.ssh/github_deploy_key_backend -o StrictHostKeyChecking=no"
  cd ..
fi

if [ ! -d "$FRONTEND_REPO_NAME" ]; then
  GIT_SSH_COMMAND="ssh -i /root/.ssh/github_deploy_key_frontend -o StrictHostKeyChecking=no" \
    git clone $FRONTEND_REPO $FRONTEND_REPO_NAME
  cd $FRONTEND_REPO_NAME
  git config core.sshCommand "ssh -i /root/.ssh/github_deploy_key_frontend -o StrictHostKeyChecking=no"
  cd ..
fi

# Set ownership
chown -R deploy:deploy /opt/$BACKEND_REPO_NAME
chown -R deploy:deploy /opt/$FRONTEND_REPO_NAME

# Copy deployment files
echo "📋 Setting up deployment configuration..."
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cp -r $SCRIPT_DIR/* /opt/deployment/

# Setup environment file
cd /opt/deployment
if [ ! -f ".env" ]; then
  if [ -f "env/.env.template" ]; then
    cp env/.env.template .env
    
    # Generate secrets
    echo "🔐 Generating secrets..."
    sed -i "s/generate-a-secure-random-string-here/$(openssl rand -hex 32)/g" .env
    sed -i "s/generate-a-secure-password-here/$(openssl rand -hex 16)/g" .env
    sed -i "s/generate-a-secure-jwt-secret-here/$(openssl rand -hex 32)/g" .env
    sed -i "s/generate-another-secure-secret-here/$(openssl rand -hex 32)/g" .env
    sed -i "s/generate-a-secure-nextauth-secret-here/$(openssl rand -hex 32)/g" .env
    
    # Update domain and app name
    sed -i "s/example.com/$DOMAIN/g" .env
    sed -i "s/myapp/$APP_NAME/g" .env
    sed -i "s/MyAppBackend/$BACKEND_REPO_NAME/g" .env
    sed -i "s/MyAppFrontend/$FRONTEND_REPO_NAME/g" .env
    
    echo "✅ Generated .env file with secrets"
    echo "⚠️  Please edit /opt/deployment/.env to add any additional configuration"
    read -p "Press enter once you've reviewed the .env file..."
  fi
fi

# Update nginx config with domain
echo "🔧 Configuring nginx..."
cp nginx/sites-enabled/app.conf.template nginx/sites-enabled/default.conf
sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" nginx/sites-enabled/default.conf

# Update webhook configuration
echo "🔧 Configuring webhook..."
sed -i "s|/opt/deployment|/opt/deployment|g" webhook/webhook-server.ts

# Start database services
echo "🗄️ Starting database services..."
docker compose up -d postgres cache

# Wait for postgres
echo "⏳ Waiting for PostgreSQL to be ready..."
sleep 15

# Run migrations
echo "🔄 Running database migrations..."
docker compose run --rm api bunx prisma migrate deploy || echo "Migrations may need to be run manually"

# Start all services (without SSL first)
echo "🚀 Starting all services..."
# Use HTTP-only config initially
cat > nginx/sites-enabled/default.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        proxy_pass http://frontend:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

docker compose up -d

# Wait for services
sleep 20

# Setup SSL
echo "🔐 Setting up SSL certificate..."
certbot certonly --webroot \
  -w /opt/deployment/certbot/www \
  -d $DOMAIN \
  --non-interactive \
  --agree-tos \
  --email $EMAIL

# Restore full nginx config with SSL
cp nginx/sites-enabled/app.conf.template nginx/sites-enabled/default.conf
sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" nginx/sites-enabled/default.conf

# Restart nginx with SSL
docker compose restart nginx

# Generate webhook secret
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo $WEBHOOK_SECRET > secrets/webhook_secret.txt
sed -i "s/GITHUB_WEBHOOK_SECRET=.*/GITHUB_WEBHOOK_SECRET=$WEBHOOK_SECRET/g" .env

# Restart webhook with secret
docker compose up -d webhook

# Show status
echo ""
echo "✅ Deployment complete!"
echo ""
echo "📊 Service Status:"
docker compose ps

echo ""
echo "🔗 Access your application:"
echo "   - Frontend: https://$DOMAIN"
echo "   - API: https://$DOMAIN/graphql"
echo "   - Webhook: https://$DOMAIN/webhook"
echo ""
echo "📝 GitHub Webhook Configuration:"
echo "   - URL: https://$DOMAIN/webhook"
echo "   - Content type: application/json"
echo "   - Secret: $(cat secrets/webhook_secret.txt)"
echo "   - Events: Just the push event"
echo ""
echo "🔑 Deploy Keys Location:"
echo "   - Backend: /root/.ssh/github_deploy_key_backend.pub"
echo "   - Frontend: /root/.ssh/github_deploy_key_frontend.pub"
echo ""
echo "📚 Commands:"
echo "   - View logs: docker compose logs -f [service_name]"
echo "   - Restart service: docker compose restart [service_name]"
echo "   - Run migrations: docker compose run --rm api bunx prisma migrate deploy"