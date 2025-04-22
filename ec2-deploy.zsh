#!/bin/zsh

# Load environment variables from .env file
if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo ".env file not found!"
    exit 1
fi

# Variables
PEM_FILE="secrets/instance-alpha.pem"  # Path to your .pem file
DOCKER_COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"

# Check if Docker Compose file exists
if ! [ -f $DOCKER_COMPOSE_FILE ]; then
    echo "$DOCKER_COMPOSE_FILE file not found!"
    exit 1
fi

# Check if .env file exists
if ! [ -f $ENV_FILE ]; then
    echo "$ENV_FILE file not found!"
    exit 1
fi

# Ensure .pem file has correct permissions
chmod 400 $PEM_FILE

# Copy files to EC2 instance
echo "Copying files to EC2 instance..."
scp -i $PEM_FILE $DOCKER_COMPOSE_FILE $ENV_FILE ubuntu@ec2-54-202-240-149.us-west-2.compute.amazonaws.com:~/

# SSH into EC2
echo "Connecting to EC2 instance..."
ssh -i $PEM_FILE ubuntu@ec2-54-202-240-149.us-west-2.compute.amazonaws.com << 'SETUP'
    # Ensure Docker is installed
    if ! command -v docker &> /dev/null; then
        echo "Docker is not installed. Installing Docker..."
        sudo apt update
        sudo apt install -y docker.io
        sudo systemctl start docker
        sudo systemctl enable docker
    fi

    # Ensure Docker Compose is installed
    if ! command -v docker-compose &> /dev/null; then
        echo "Docker Compose is not installed. Installing Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
SETUP

# Deploy application
echo "Deploying application on EC2 instance..."
ssh -i $PEM_FILE ubuntu@ec2-54-202-240-149.us-west-2.compute.amazonaws.com << 'DEPLOY'
    echo "Running Docker Compose..."
    sudo docker-compose up -d
DEPLOY

echo "Deployment to EC2 instance completed!"
