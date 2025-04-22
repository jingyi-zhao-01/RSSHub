#!/bin/zsh
# Check if AWS CLI is installed and configured

if ! command -v aws &> /dev/null; then
    echo "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Load environment variables
if ! [ -f .env ]; then
    echo ".env file not found!"
    exit 1
fi

source .env


# Create ECR repository
if ! aws ecr describe-repositories --repository-names rsshub > /dev/null 2>&1; then
    echo "Creating ECR repository..."
    aws ecr create-repository --repository-name rsshub
fi

# Login to ECR
echo "Logging into ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# Build and push Docker image
echo "Building and pushing Docker image..."
docker build -t rsshub .
docker tag rsshub:latest "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/rsshub:latest"
docker push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/rsshub:latest"

# Create ECS cluster
if ! aws ecs describe-clusters --clusters rsshub-cluster --query 'clusters[0]' > /dev/null 2>&1; then
    echo "Creating ECS cluster..."
    aws ecs create-cluster --cluster-name rsshub-cluster
fi

# Create IAM roles
if ! aws iam get-role --role-name ecsTaskExecutionRole > /dev/null 2>&1; then
    echo "Creating IAM role..."
    aws iam create-role \
        --role-name ecsTaskExecutionRole \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Service": "ecs-tasks.amazonaws.com"
                    },
                    "Action": "sts:AssumeRole"
                }
            ]
        }'

    sleep 10

    aws iam attach-role-policy \
        --role-name ecsTaskExecutionRole \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

    sleep 10
fi

# Create CloudWatch log group
if ! aws logs describe-log-groups --log-group-name-prefix /ecs/rsshub > /dev/null 2>&1; then
    echo "Creating CloudWatch log group..."
    aws logs create-log-group --log-group-name /ecs/rsshub
fi

# Create task definition
echo "Creating task definition..."
ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole --query 'Role.Arn' --output text)
cat > task-definition.json << EOF
{
    "family": "rsshub",
    "networkMode": "awsvpc",
    "executionRoleArn": "$ROLE_ARN",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "512",
    "containerDefinitions": [
        {
            "name": "rsshub",
            "image": "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/rsshub:latest",
            "portMappings": [
                {
                    "containerPort": 1200,
                    "protocol": "tcp"
                }
            ],
            "environment": [
                {
                    "name": "NODE_ENV",
                    "value": "production"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/rsshub",
                    "awslogs-region": "$AWS_REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ]
}
EOF

# Register task definition
echo "Registering task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json file://task-definition.json \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

# Create or update ECS service
if ! aws ecs describe-services --cluster rsshub-cluster --services rsshub-service --query 'services[0]' > /dev/null 2>&1; then
    echo "Creating ECS service..."
    aws ecs create-service \
        --cluster rsshub-cluster \
        --service-name rsshub-service \
        --task-definition $TASK_DEF_ARN \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}"
else
    echo "Updating ECS service..."
    aws ecs update-service \
        --cluster rsshub-cluster \
        --service rsshub-service \
        --task-definition $TASK_DEF_ARN \
        --force-new-deployment
fi

echo "Waiting for service stability..."
aws ecs wait services-stable \
    --cluster rsshub-cluster \
    --services rsshub-service

echo "Deployment completed!"
