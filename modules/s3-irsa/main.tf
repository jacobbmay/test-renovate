locals {
  eks_oidc_issuer_url = replace(var.eks_oidc_provider_arn, "/^(.*provider/)/", "")
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_kms_key" "default" {
  key_id = var.kms_key_arn
}

#####################################################
################## Loki S3 Bucket ###################
module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "v4.2.1"

  bucket_prefix           = var.name_prefix
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  force_destroy           = var.force_destroy

  tags = var.tags
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = data.aws_kms_key.default.arn
        sse_algorithm     = "aws:kms"
      }
    }
  }
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = module.s3_bucket.s3_bucket_id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "logging" {
  count = var.access_logging_enabled ? 1 : 0

  bucket        = module.s3_bucket.s3_bucket_id
  target_bucket = var.access_logging_bucket_id
  target_prefix = var.access_logging_bucket_prefix

  depends_on = [module.s3_bucket.s3_bucket_id]

  lifecycle {
    precondition {
      condition     = var.access_logging_bucket_id != null && var.access_logging_bucket_prefix != null
      error_message = "access_logging_bucket_id and access_logging_bucket_path must be set to enable access logging."
    }
  }
}

data "aws_iam_policy_document" "irsa_policy" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [module.s3_bucket.s3_bucket_arn]
  }
  statement {
    actions   = ["s3:*Object"]
    resources = ["${module.s3_bucket.s3_bucket_arn}/*"]
  }
  statement {
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt"
    ]
    resources = [data.aws_kms_key.default.arn]
  }
}

resource "aws_iam_policy" "irsa_policy" {
  description = "IAM Policy for IRSA"
  name_prefix = "${var.name_prefix}-${var.policy_name_prefix}"
  policy      = data.aws_iam_policy_document.irsa_policy.json
}

resource "aws_iam_role" "irsa" {
  count = var.irsa_iam_policies != null ? 1 : 0

  name        = try(coalesce(var.irsa_iam_role_name, format("%s-%s-%s", var.name_prefix, trim(var.kubernetes_service_account, "-*"), "irsa")), null)
  description = "AWS IAM Role for the Kubernetes service account ${var.kubernetes_service_account}."
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Federated" : var.eks_oidc_provider_arn
        },
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Condition" : {
          "StringLike" : {
            "${local.eks_oidc_issuer_url}:sub" : "system:serviceaccount:${var.kubernetes_namespace}:${var.kubernetes_service_account}",
            "${local.eks_oidc_issuer_url}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })
  path                  = var.irsa_iam_role_path
  force_detach_policies = true
  permissions_boundary  = var.irsa_iam_permissions_boundary

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "irsa" {

  policy_arn = aws_iam_policy.irsa_policy.arn
  role       = aws_iam_role.irsa[0].name
}

resource "aws_s3_bucket_policy" "bucket_policy" {
  # count  = local.create_bucket_policy ? 1 : 0
  bucket = module.s3_bucket.s3_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject"
        ]
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.irsa[0].arn
        }
        Resource = [
          module.s3_bucket.s3_bucket_arn,
          "${module.s3_bucket.s3_bucket_arn}/*"
        ]
      }
    ]
  })
}

################################################################################
# DynamoDB Table
################################################################################

resource "aws_dynamodb_table" "loki_dynamodb" {
  count = var.dynamodb_enabled != null ? 1 : 0

  name         = "${var.name_prefix}-dynamodb_index"
  hash_key     = "Log_id"
  billing_mode = "PAY_PER_REQUEST"

  point_in_time_recovery {
    enabled = true
  }

  attribute {
    name = "Log_id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = data.aws_kms_key.default.arn
  }
}

data "aws_iam_policy_document" "dynamo_irsa_policy" {


  statement {
    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:ListTagsOfResource",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
      "dynamodb:UpdateItem",
      "dynamodb:UpdateTable",
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:ListTables"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/bigbang-*"]
  }
}

resource "aws_iam_policy" "dynamodb_irsa_policy" {
  # count     = var.dynamodb_enabled != null ? 1 : 0
  name        = "${var.name_prefix}-dynmodb_irsa_policy"
  description = "DynamoDB IAM policy"
  policy      = data.aws_iam_policy_document.dynamo_irsa_policy.json
}

resource "aws_iam_role_policy_attachment" "dynamodb_policy_attachment" {
  # count    = var.dynamodb_enabled != null ? 1 : 0

  policy_arn = aws_iam_policy.dynamodb_irsa_policy.arn
  role       = aws_iam_role.irsa[0].name
}
