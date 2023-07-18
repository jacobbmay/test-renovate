
###########################################################
############## Big Bang Core Dependencies #################
###########################################################

###########################################################
################# Enable EKS Sops #########################

module "flux_sops" {
  # source = "git::https://github.com/defenseunicorns/delivery-aws-iac.git//modules/sops?ref=v<insert tagged version>"
  source = "../../modules/sops"

  cluster_name                  = module.eks.cluster_name
  policy_name_prefix            = "${module.eks.cluster_name}-flux-sops"
  kms_key_arn                   = aws_kms_key.default.arn
  kubernetes_service_account    = "flux-system-sops-sa"
  kubernetes_namespace          = "flux-system"
  irsa_sops_iam_role_name       = "${module.eks.cluster_name}-flux-system-sa-role"
  irsa_iam_permissions_boundary = var.iam_role_permissions_boundary
  eks_oidc_provider_arn         = module.eks.oidc_provider_arn
  tags                          = local.tags
  role_name                     = module.bastion.bastion_role_name
}

###########################################################
################## Loki S3 Buckets ########################

module "loki_s3_bucket" {
  # source = "git::https://github.com/defenseunicorns/delivery-aws-iac.git//modules/s3-irsa?ref=v<insert tagged version>"
  source = "../../modules/s3-irsa"

  name_prefix                   = "${local.loki_name_prefix}-s3"
  region                        = var.region
  policy_name_prefix            = "${local.loki_name_prefix}-s3-policy"
  kms_key_arn                   = aws_kms_key.default.arn
  kubernetes_service_account    = "logging-loki" #Must be logging-loki to match BigBang deployment
  kubernetes_namespace          = "logging"
  irsa_iam_role_name            = "${module.eks.cluster_name}-logging-loki-sa-role"
  irsa_iam_permissions_boundary = var.iam_role_permissions_boundary
  eks_oidc_provider_arn         = module.eks.oidc_provider_arn
  tags                          = local.tags
  dynamodb_enabled              = false
}

###########################################################
############ Big Bang Add-Ons Dependencies ################
###########################################################

###########################################################
############### Keycloak RDS Database #####################

module "rds_postgres_keycloak" {
  source = "git::https://github.com/defenseunicorns/terraform-aws-uds-rds.git?ref=v0.0.1-alpha"

  count = var.keycloak_enabled ? 1 : 0

  # provider alias is needed for every parent module supporting RDS backup replication is a separate region
  providers = {
    aws.region2 = aws.region2
  }

  vpc_id                               = module.vpc.vpc_id
  vpc_cidr                             = module.vpc.vpc_cidr_block
  database_subnet_group_name           = module.vpc.database_subnet_group_name
  engine                               = "postgres"
  engine_version                       = var.kc_db_engine_version
  family                               = var.kc_db_family
  major_engine_version                 = var.kc_db_major_engine_version
  instance_class                       = var.kc_db_instance_class
  identifier                           = "${local.cluster_name}-keycloak"
  db_name                              = "keycloak" # Can only be alphanumeric, no hyphens or underscores
  username                             = "kcadmin"
  create_random_password               = false
  password                             = var.keycloak_db_password
  allocated_storage                    = var.kc_db_allocated_storage
  max_allocated_storage                = var.kc_db_max_allocated_storage
  deletion_protection                  = false
  monitoring_role_permissions_boundary = var.iam_role_permissions_boundary
  tags                                 = local.tags
}
