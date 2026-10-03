variable "region" {
  description = "AWS region for everything"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name (also used to name the VPC and IAM roles)"
  type        = string
  default     = "shopflow"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Check what's supported: aws eks describe-cluster-versions"
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "IP range of the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_types" {
  description = "EC2 instance types for the worker nodes (several = better Spot availability)"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND, or SPOT (~60-70% cheaper, but AWS can reclaim nodes; fine for a demo)"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_count" {
  description = "Desired / minimum / maximum number of worker nodes"
  type = object({
    desired = number
    min     = number
    max     = number
  })
  default = {
    desired = 3
    min     = 2
    max     = 4
  }
}

variable "api_allowed_cidrs" {
  description = <<-EOT
    IP ranges allowed to reach the Kubernetes API from the internet, e.g. your own IP
    ["203.0.113.7/32"]. Empty (the default) = no public access at all: the API is only
    reachable from inside the VPC. Secure by default.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.api_allowed_cidrs, "0.0.0.0/0")
    error_message = "Don't open the Kubernetes API to the whole internet (0.0.0.0/0): list specific IPs."
  }
}

variable "monthly_budget_usd" {
  description = "Send an email when this month's AWS spend is forecast to pass this amount"
  type        = number
  default     = 20
}

variable "budget_alert_email" {
  description = "Where budget alerts go. Empty = don't create the budget."
  type        = string
  default     = ""
}
