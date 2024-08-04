#!/bin/bash

# Create AWS credentials file
mkdir -p ~/.aws
cat <<EOF > ~/.aws/credentials
[${aws_profile}]
aws_access_key_id = ${aws_access_key_id}
aws_secret_access_key = ${aws_secret_access_key}
EOF


cat <<EOF > eks-config.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${cluster_name}
  region: ${cluster_region}

nodeGroups:
  - name: linux-nodes
    instanceType: ${instance_type}
    desiredCapacity: ${desiredCapacity}
    minSize: ${minSize}
    maxSize: ${maxSize}
iam:
  serviceRoleARN: arn:aws:iam::${account_no}:role/${cluster_role}
EOF
exit_code=$?
if [[ ${exit_code} == 0 ]];then
    echo "eks-config.yaml is succesfully created"
    echo "Now launching EKS Cluster......."
else
    echo "eks-config.yaml creation failed.....exiting now"
    exit 1
fi    

eksctl create cluster -f eks-config.yaml --profile ${aws_profile}
exit_code=$?
if [[ ${exit_code} == 0 ]];then
    echo "EKS Created Succesfully with below configuration"
    cat eks-config.yaml
    echo "Enjoyyyy Maadiii......."
else
    echo "EKS Cluster creation Failed. Pls check cloud formagtion logs."
    exit 1
fi
