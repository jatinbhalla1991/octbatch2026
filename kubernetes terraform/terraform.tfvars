# Cluster Name - Update this for your demo
cluster_name = "demo-eks-cluster1"

# AWS Region
region = "us-east-1"

# Kubernetes Version
kubernetes_version = "1.32"

# VPC Configuration
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]

# Node Group Configuration
instance_types     = ["t3.medium"]
capacity_type      = "ON_DEMAND"
disk_size          = 20
desired_capacity   = 2
min_capacity       = 1
max_capacity       = 4

# Access Configuration
public_access_cidrs = ["0.0.0.0/0"]  # Restrict this to your IP for production

# ECR Configuration
ecr_repository_name = "demo-app"

# Common Tags
common_tags = {
  Environment = "demo"
  Project     = "eks-demo"
  ManagedBy   = "terraform"
  Owner       = "DevOps-Team"
}