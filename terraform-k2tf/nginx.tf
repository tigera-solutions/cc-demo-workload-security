resource "kubernetes_pod" "nginx" {
  metadata {
    name = "nginx"

    labels = {
      run = "nginx"
    }
  }

  spec {
    container {
      name  = "nginx"
      image = "nginx"
    }

    restart_policy = "Always"
    dns_policy     = "ClusterFirst"
  }
}

