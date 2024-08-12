#!/bin/bash

# AWS Credentials
AWS_ACCESS_KEY="xxxx"                            # Replace with your AWS access key
AWS_SECRET_KEY="xxxx"                            # Replace with your AWS secret key
AWS_PROFILE="eksprofile"                                    # Name of the AWS profile to use



# Global Variables
REGION="us-east-1"                                          # Change this to your desired region
EKS_CLUSTER_NAME="my-eks-cluster"                           # Change this to your desired EKS cluster name
NODE_GROUP_NAME="${EKS_CLUSTER_NAME}-backend"               # Change this to your desired Node Group name
MIN_SIZE=1                                                  # Minimum size of the node group
MAX_SIZE=1                                                  # Maximum size of the node group
DESIRED_CAPACITY=1                                          # Desired capacity of the node group
INSTANCE_TYPE="t3.medium"                                   # EC2 instance type for the node group
K8S_VERSION="1.29"                                          # Kubernetes version
KEY_NAME="${EKS_CLUSTER_NAME}-myEksKeyPair"                 # Key pair name
SECRET_NAME="${EKS_CLUSTER_NAME}-myEksKeyPair"            # Secret name for the key pair
OUTPUT_FILE="${EKS_CLUSTER_NAME}-key_pair_output.json"      # File to store key pair details
VPC_STACK_NAME="${EKS_CLUSTER_NAME}-eks-vpc-stack"          # CloudFormation stack name for VPC
CLUSTER_ROLE_NAME="eksClusterRole"                          # IAM role name for EKS cluster
NODE_GROUP_STACK_NAME="eks-nodegroup-stack"                 # CloudFormation stack name for Node Group

# Configure AWS CLI with the provided access key and secret key
aws configure set aws_access_key_id $AWS_ACCESS_KEY --profile $AWS_PROFILE
aws configure set aws_secret_access_key $AWS_SECRET_KEY --profile $AWS_PROFILE
aws configure set region $REGION --profile $AWS_PROFILE

# Function to create VPC and networks
create_vpc_and_networks() {
    echo "Creating VPC and networks..."
    aws cloudformation create-stack --profile $AWS_PROFILE --region $REGION --stack-name $VPC_STACK_NAME \
        --template-url https://s3.us-west-2.amazonaws.com/amazon-eks/cloudformation/2020-10-29/amazon-eks-vpc-private-subnets.yaml \
        --parameters ParameterKey=VpcBlock,ParameterValue="192.168.0.0/16" \
                     ParameterKey=PublicSubnet01Block,ParameterValue="192.168.0.0/18" \
                     ParameterKey=PublicSubnet02Block,ParameterValue="192.168.64.0/18" \
                     ParameterKey=PrivateSubnet01Block,ParameterValue="192.168.128.0/18" \
                     ParameterKey=PrivateSubnet02Block,ParameterValue="192.168.192.0/18" \
        --capabilities CAPABILITY_NAMED_IAM

    echo "Waiting for VPC stack creation to complete..."
    aws cloudformation wait stack-create-complete --profile $AWS_PROFILE --region $REGION --stack-name $VPC_STACK_NAME

    # Retry logic
    for attempt in {1..5}; do
        echo "Attempt $attempt: Fetching VPC, Subnet IDs, and Control Plane Security Group..."

        VPC_ID=$(aws cloudformation describe-stacks --profile $AWS_PROFILE --region $REGION --stack-name $VPC_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)
        SUBNET_IDS=$(aws cloudformation describe-stacks --profile $AWS_PROFILE --region $REGION --stack-name $VPC_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='SubnetIds'].OutputValue" --output text | tr ',' '\n')
        CONTROL_PLANE_SG=$(aws cloudformation describe-stacks --profile $AWS_PROFILE --region $REGION --stack-name $VPC_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='SecurityGroups'].OutputValue" --output text)

        if [ -n "$VPC_ID" ] && [ -n "$SUBNET_IDS" ] && [ -n "$CONTROL_PLANE_SG" ]; then
            echo "Successfully retrieved VPC ID, Subnet IDs, and Control Plane Security Group."
            echo "VPC ID: $VPC_ID"
            echo "Subnet IDs: $SUBNET_IDS"
            echo "Control Plane Security Group: $CONTROL_PLANE_SG"
            break
        else
            echo "Failed to retrieve VPC, Subnet IDs, or Control Plane Security Group. Retrying in 10 seconds..."
            sleep 10
        fi
    done

    if [ -z "$VPC_ID" ] || [ -z "$SUBNET_IDS" ] || [ -z "$CONTROL_PLANE_SG" ]; then
        echo "Error: Failed to retrieve VPC, Subnet IDs, or Control Plane Security Group after multiple attempts."
        exit 1
    fi

    echo "VPC and networks created successfully."
}

# Function to create EKS cluster role
create_eks_cluster_role() {
    echo "Checking if EKS Cluster Role exists..."
    
    aws iam get-role --profile $AWS_PROFILE --role-name $CLUSTER_ROLE_NAME &>/dev/null
    
    if [[ $? -eq 0 ]]; then
        echo "EKS Cluster Role already exists. Skipping creation."
    else
        echo "Creating EKS Cluster Role..."
        aws iam create-role --profile $AWS_PROFILE --role-name $CLUSTER_ROLE_NAME --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Service": "eks.amazonaws.com"
                    },
                    "Action": "sts:AssumeRole"
                }
            ]
        }'
        aws iam attach-role-policy --profile $AWS_PROFILE --role-name $CLUSTER_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
        echo "EKS Cluster Role created successfully."
    fi
}

# Function to create EKS cluster
create_eks_cluster() {
    echo "Creating EKS Cluster..."

    # Dynamically determine the availability zones for the region
    AVAILABILITY_ZONES=$(aws ec2 describe-availability-zones --profile $AWS_PROFILE --region $REGION --query "AvailabilityZones[].ZoneName" --output text)
    AVAILABILITY_ZONE_ARRAY=($AVAILABILITY_ZONES)

    if [ ${#AVAILABILITY_ZONE_ARRAY[@]} -lt 2 ]; then
        echo "Error: Not enough availability zones in the selected region."
        exit 1
    fi

    # Map subnets to availability zones dynamically
    PUBLIC_SUBNETS=""
    PRIVATE_SUBNETS=""
    index=0
    for subnet_id in $SUBNET_IDS; do
        if [ $index -lt 2 ]; then
            PUBLIC_SUBNETS+="${AVAILABILITY_ZONE_ARRAY[$index]}:\n        id: $subnet_id\n"
        else
            PRIVATE_SUBNETS+="${AVAILABILITY_ZONE_ARRAY[$index-2]}:\n        id: $subnet_id\n"
        fi
        index=$((index+1))
    done

    cat <<EOF > create-eks.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $EKS_CLUSTER_NAME
  region: $REGION
  version: "$K8S_VERSION"

vpc:
  subnets:
    public:
$(echo -e "$PUBLIC_SUBNETS" | sed 's/^/      /')
    private:
$(echo -e "$PRIVATE_SUBNETS" | sed 's/^/      /')

iam:
  withOIDC: false
  serviceRoleARN: arn:aws:iam::$(aws sts get-caller-identity --profile $AWS_PROFILE --query Account --output text):role/$CLUSTER_ROLE_NAME
EOF

    eksctl create cluster -f create-eks.yaml
    echo "EKS Cluster created successfully."
}

# Function to create key pair and store in Secrets Manager
create_key_pair_and_store() {
    echo "Creating EC2 Key Pair..."
    aws ec2 create-key-pair --profile $AWS_PROFILE --key-name "$KEY_NAME" --region "$REGION" > "$OUTPUT_FILE"

    if [[ $? -ne 0 ]]; then
        echo "Error creating key pair. Check the output file: $OUTPUT_FILE"
        exit 1
    fi

    aws secretsmanager create-secret --profile $AWS_PROFILE --name "$SECRET_NAME" --secret-string file://"$OUTPUT_FILE" --region "$REGION"

    if [[ $? -ne 0 ]]; then
        echo "Error storing private key in Secrets Manager."
        exit 1
    fi

    echo "Key pair '$KEY_NAME' created and output stored in Secrets Manager as '$SECRET_NAME'."
}


# Function to create node group
create_node_group() {
    
    echo "Creating EKS Node Group..."
    # Ensure SUBNET_IDS is properly formatted as a single, comma-separated string
    SUBNET_IDS_CSV=$(echo "$SUBNET_IDS" | paste -sd, -)

    echo "Subnets are:"
    echo "$SUBNET_IDS_CSV"

    # Create the Node Group stack
    aws cloudformation create-stack --region $REGION --profile $AWS_PROFILE \
        --stack-name $NODE_GROUP_STACK_NAME \
        --template-url https://s3.us-west-2.amazonaws.com/amazon-eks/cloudformation/2022-12-23/amazon-eks-nodegroup.yaml \
        --capabilities CAPABILITY_IAM \
        --parameters ParameterKey=ClusterName,ParameterValue=$EKS_CLUSTER_NAME \
                    ParameterKey=ClusterControlPlaneSecurityGroup,ParameterValue=$CONTROL_PLANE_SG \
                    ParameterKey=NodeGroupName,ParameterValue=$NODE_GROUP_NAME \
                    ParameterKey=NodeAutoScalingGroupMinSize,ParameterValue=$MIN_SIZE \
                    ParameterKey=NodeAutoScalingGroupDesiredCapacity,ParameterValue=$DESIRED_CAPACITY \
                    ParameterKey=NodeAutoScalingGroupMaxSize,ParameterValue=$MAX_SIZE \
                    ParameterKey=NodeInstanceType,ParameterValue=$INSTANCE_TYPE \
                    ParameterKey=NodeImageIdSSMParam,ParameterValue=/aws/service/eks/optimized-ami/$K8S_VERSION/amazon-linux-2/recommended/image_id \
                    ParameterKey=NodeVolumeSize,ParameterValue=20 \
                    ParameterKey=NodeVolumeType,ParameterValue=gp2 \
                    ParameterKey=KeyName,ParameterValue=$KEY_NAME \
                    ParameterKey=DisableIMDSv1,ParameterValue=false \
                    ParameterKey=VpcId,ParameterValue=$VPC_ID \
                    ParameterKey=Subnets,ParameterValue=\"$SUBNET_IDS_CSV\"

    echo "Waiting for Node Group stack creation to complete..."
    aws cloudformation wait stack-create-complete --region $REGION --stack-name $NODE_GROUP_STACK_NAME --profile $AWS_PROFILE

    echo "EKS Node Group created successfully."
}

# Function to attach NodeInstanceRole to aws-auth ConfigMap
attach_nodegroup_to_cluster() {
    echo "Attaching Node Group to EKS Cluster..."

    # Get the NodeInstanceRole from CloudFormation stack outputs
    NODE_INSTANCE_ROLE=$(aws cloudformation describe-stacks --region $REGION --stack-name $NODE_GROUP_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='NodeInstanceRole'].OutputValue" --output text --profile $AWS_PROFILE)

    if [ -z "$NODE_INSTANCE_ROLE" ]; then
        echo "Error: Could not retrieve NodeInstanceRole."
        exit 1
    fi

    echo "Retrieved NodeInstanceRole: $NODE_INSTANCE_ROLE"

    # Create aws-auth ConfigMap to attach the Node Group
    cat <<EOF > aws-auth-patch.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: $NODE_INSTANCE_ROLE
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF

    kubectl apply -f aws-auth-patch.yaml

    echo "Node Group successfully attached to the EKS Cluster."
}

# Main Script Execution
create_vpc_and_networks
create_eks_cluster_role
create_eks_cluster
create_key_pair_and_store
create_node_group
attach_nodegroup_to_cluster

echo "EKS cluster setup and node group attachment completed successfully."
