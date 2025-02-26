################################################################################
# Kubernetes secret to store db credential
################################################################################
resource "kubernetes_secret" "rds_secret" {
  metadata {
    name      = "${local.product_name}-db-cred"
    namespace = var.namespace
  }

  data = {
    username = module.database.rds_master_username
    password = module.database.rds_master_password
  }
}

################################################################################
# Kubernetes secret to store license
################################################################################
resource "kubernetes_secret" "license_secret" {
  metadata {
    name      = "${local.product_name}-license"
    namespace = var.namespace
  }

  data = {
    license = var.bamboo_configuration["license"]
  }
}

################################################################################
# Kubernetes secret to store system admin credentials
################################################################################
resource "kubernetes_secret" "admin_secret" {
  metadata {
    name      = "${local.product_name}-admin"
    namespace = var.namespace
  }

  data = {
    username     = var.admin_configuration["admin_username"]
    password     = var.admin_configuration["admin_password"]
    displayName  = var.admin_configuration["admin_display_name"]
    emailAddress = var.admin_configuration["admin_email_address"]
  }
}

################################################################################
# Kubernetes secret to store bamboo security token
################################################################################
resource "random_id" "security_token" {
  byte_length = 20
}

resource "kubernetes_secret" "security_token_secret" {
  metadata {
    name      = "${local.product_name}-security-token"
    namespace = var.namespace
  }

  data = {
    security-token = random_id.security_token.hex
  }
}