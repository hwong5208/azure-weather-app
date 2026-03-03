#!/bin/bash
# deploy.sh
# Deployment helper script tailored for local testing and infrastructure deployment.

set -e

# Default variables
PROJECT_NAME="yvrweather"
ENVIRONMENT="dev"
LOCATION="westus3"

# Colors for log output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Vancouver Weather App Deployment Script ===${NC}"

# Check dependencies
for tool in terraform docker az; do
  if ! command -v $tool &> /dev/null; then
    echo "Error: $tool is not installed."
    exit 1
  fi
done

echo -e "${GREEN}==> Initializing Terraform...${NC}"
cd ../infrastructure
terraform init

echo -e "${GREEN}==> Deploying Infrastructure...${NC}"
terraform apply -auto-approve \
  -var="project_name=${PROJECT_NAME}" \
  -var="environment=${ENVIRONMENT}" \
  -var="location=${LOCATION}"

# Get outputs
ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
echo -e "${GREEN}==> Infrastructure Deployed. ACR Server: ${ACR_LOGIN_SERVER}${NC}"

echo -e "${GREEN}==> Authenticating to ACR...${NC}"
az acr login --name "acr${PROJECT_NAME}${ENVIRONMENT}"

echo -e "${GREEN}==> Building Docker Image...${NC}"
cd ../app
docker build -t vancouver-weather-app:latest .

echo -e "${GREEN}==> Tagging and Pushing Image to ACR...${NC}"
docker tag vancouver-weather-app:latest ${ACR_LOGIN_SERVER}/vancouver-weather-app:latest
docker push ${ACR_LOGIN_SERVER}/vancouver-weather-app:latest

echo -e "${BLUE}=== Deployment Complete ===${NC}"
echo "You may need to wait a few minutes for the container app to pull the new image."
