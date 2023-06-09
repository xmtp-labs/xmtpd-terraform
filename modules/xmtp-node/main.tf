locals {
  labels = {
    "app.kubernetes.io/part-of" = "xmtp-nodes"
    "app.kubernetes.io/name" : var.name
  }
  # For the parameter definitions see
  # https://github.com/DataDog/integrations-core/blob/master/datadog_checks_dev/datadog_checks/dev/tooling/templates/configuration/instances/openmetrics.yaml
  annotations = {
    "ad.datadoghq.com/node.checks" = <<EOT
      {
        "openmetrics": {
          "init_config": {},
          "instances": [
            {
              "openmetrics_endpoint": "http://%%host%%:%%port_admin%%/metrics",
              "namespace": "xmtpd2",
              "raw_metric_prefix": "xmtpd_",
              "metrics": [".*"],
              "tag_by_endpoint": false,
              "histogram_buckets_as_distributions": true
            }
          ]
        }
      }          
    EOT
  }
}

resource "kubernetes_ingress_v1" "ingress" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    ingress_class_name = var.ingress_class_name
    tls {
      hosts = var.hostnames
    }
    dynamic "rule" {
      for_each = var.hostnames
      content {
        host = rule.value
        http {
          path {
            path = "/"
            backend {
              service {
                name = var.name
                port {
                  number = var.api_http_port
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "service" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name = "api"
      port = var.api_http_port
    }
    port {
      name = "p2p"
      port = var.p2p_port
    }
    port {
      name = "admin"
      port = var.admin_port
    }
  }
}

resource "kubernetes_secret" "secret" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  data = merge(
    {
      XMTP_NODE_KEY = var.private_key
    },
    local.postgres_dsn != null ? { POSTGRES_DSN = local.postgres_dsn } : {}
  )
}

resource "kubernetes_stateful_set" "statefulset" {
  wait_for_rollout = var.wait_for_ready
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    selector {
      match_labels = local.labels
    }
    service_name = var.name
    replicas     = 1
    template {
      metadata {
        labels      = local.labels
        annotations = local.annotations
      }
      spec {
        termination_grace_period_seconds = 10
        node_selector = {
          (var.node_pool_label_key) = var.node_pool
        }
        dynamic "affinity" {
          for_each = var.one_instance_per_k8s_node ? [1] : []
          content {
            pod_anti_affinity {
              required_during_scheduling_ignored_during_execution {
                label_selector {
                  match_expressions {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = [local.labels["app.kubernetes.io/name"]]
                  }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }
        container {
          name  = "node"
          image = var.container_image
          port {
            name           = "http-api"
            container_port = var.api_http_port
          }
          port {
            name           = "p2p"
            container_port = var.p2p_port
          }
          port {
            name           = "admin"
            container_port = var.admin_port
          }
          dynamic "volume_mount" {
            for_each = var.store_type == "bolt" ? [1] : []
            content {
              name       = "data"
              mount_path = "/data"
            }
          }
          env_from {
            secret_ref {
              name = kubernetes_secret.secret.metadata[0].name
            }
          }
          command = concat(
            [
              "xmtpd",
              "start",
              "--log.encoding=json",
              "--p2p.port=${var.p2p_port}",
              "--api.http-port=${var.api_http_port}",
              "--api.grpc-port=${var.api_grpc_port}",
              "--admin.port=${var.admin_port}",
              "--store.type=${var.store_type}",
              "--topic-reaper-period=${var.topic_reaper_period}",
            ],
            [for peer in var.p2p_persistent_peers : "--p2p.persistent-peer=${peer}"],
            var.debug ? ["--log.level=debug"] : [],
            var.store_type == "bolt" ? ["--store.bolt.data-path=/data/db.bolt"] : [],
          )
          readiness_probe {
            http_get {
              path = "/healthz"
              port = "http-api"
            }
            success_threshold = 1
            failure_threshold = 3
            period_seconds    = 10
          }
          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }
        }
      }
    }
    dynamic "volume_claim_template" {
      for_each = var.store_type == "bolt" ? [1] : []
      content {
        metadata {
          name   = "data"
          labels = local.labels
        }
        spec {
          access_modes = [
            "ReadWriteOnce"
          ]
          storage_class_name = var.storage_class_name
          resources {
            requests = {
              "storage" = var.storage_request
            }
          }
        }
      }
    }
  }
}
