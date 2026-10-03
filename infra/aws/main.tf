data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Spread across 3 availability zones (separate data centres), so losing one isn't fatal
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# ── Network ──────────────────────────────────────────────────────────────────────
# Worker nodes live in PRIVATE subnets (no public IPs); load balancers go in PUBLIC ones.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]      # 10.0.0.0/20, ...
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 48 + i)] # 10.0.48.0/24, ...

  # Private nodes reach the internet (to pull images) through a NAT gateway.
  # ONE shared NAT instead of one per zone: ~$32/month instead of ~$97. Fine for a demo;
  # production would use one per zone so a zone outage doesn't cut off the others.
  enable_nat_gateway = true
  single_nat_gateway = true

  # Tags the AWS Load Balancer Controller uses to find where to put load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ── Kubernetes cluster ───────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.26"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # The API is private by default. Listing IPs in api_allowed_cidrs (e.g. your own) opens
  # it to exactly those addresses, so kubectl works from a laptop; nobody else can reach it.
  endpoint_private_access      = true
  endpoint_public_access       = length(var.api_allowed_cidrs) > 0
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  # Whoever runs terraform apply becomes cluster admin (via EKS access entries)
  enable_cluster_creator_admin_permissions = true

  # Managed add-ons: AWS installs and upgrades these
  addons = {
    vpc-cni = {
      before_compute = true # networking must exist before nodes join
    }
    coredns    = {}
    kube-proxy = {}
    # Lets pods get IAM permissions without access keys (used by the EBS driver below)
    eks-pod-identity-agent = {
      before_compute = true
    }
    # Creates EBS disks for PersistentVolumeClaims (Postgres and RabbitMQ data)
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    # metrics-server is NOT installed here: GitOps owns it (argocd/apps/platform-metrics-server.yaml),
    # so kind and EKS run the same thing and the two can't conflict.
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      desired_size = var.node_count.desired
      min_size     = var.node_count.min
      max_size     = var.node_count.max
    }
  }
}

# IAM role for the EBS CSI driver, handed to its pods through EKS Pod Identity:
# no long-lived AWS keys anywhere in the cluster.
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name                      = "${var.cluster_name}-ebs-csi"
  attach_aws_ebs_csi_policy = true
}

# gp3 disks (cheaper and faster than gp2), encrypted, and the default for new PVCs
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer" # create the disk in the zone where the pod lands
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}

# ── Cost guard ───────────────────────────────────────────────────────────────────
# Emails you when the month's spend is FORECAST to pass the limit, so a cluster that
# was forgotten after a demo is noticed within days, not at the end of the month.
resource "aws_budgets_budget" "monthly" {
  count = var.budget_alert_email == "" ? 0 : 1

  name         = "${var.cluster_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
