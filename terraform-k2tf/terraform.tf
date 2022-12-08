terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "4.45.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.16.1"
    }
  }
}

data "aws_eks_cluster" "eks-cluster" {
  name = "rm-demo-sp"
}

data "aws_eks_cluster_auth" "eks-cluster" {
  name = "rm-demo-sp"
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks-cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks-cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks-cluster.token
}
