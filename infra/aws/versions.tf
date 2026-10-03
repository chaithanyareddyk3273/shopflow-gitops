terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  # Remote state: one S3 bucket per AWS account, created once by hand (see README).
  # S3's native lock file (use_lockfile) stops two people applying at the same time,
  # so no DynamoDB table is needed (Terraform >= 1.10).
  # Commented out so `terraform init` works without an AWS account; uncomment and fill in.
  # backend "s3" {
  #   bucket       = "<your-terraform-state-bucket>"
  #   key          = "shopflow/eks/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  # Every resource gets these tags: easy to find, and to see what it costs
  default_tags {
    tags = {
      Project   = "shopflow"
      ManagedBy = "terraform"
      Repo      = "github.com/chaithanyareddyk3273/shopflow-gitops"
    }
  }
}

# Talks to the new cluster (only for the gp3 StorageClass). Logs in with a short-lived
# token from `aws eks get-token`, using whatever AWS login runs Terraform; nothing is stored.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}
