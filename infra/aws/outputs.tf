output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API address"
  value       = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "VPC the cluster runs in"
  value       = module.vpc.vpc_id
}
