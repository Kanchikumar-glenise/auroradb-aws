provider "aws" {
  region = local.region
}

locals {
  name   = "auroradb-${replace(basename(path.cwd), "_", "-")}"
  region = "us-west-2"
  tags = {
    Owner       = "user"
    Environment = "dev"
  }
}

################################################################################
# Supporting Resources
################################################################################

# Firstly create a random generated password to use in secrets.
 
resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "^[a-zA-Z0-9]*$"
}
 
# Creating a AWS secret for database master account (Aurora-Secret-DB)
 
resource "aws_secretsmanager_secret" "aurorasecretmasterDB" {
   name = "Aurora-Secret-DB123"
}
 
# Creating a AWS secret versions for database master account (Masteraccoundb)
 
resource "aws_secretsmanager_secret_version" "sversion" {
  secret_id = aws_secretsmanager_secret.aurorasecretmasterDB.id
  secret_string = <<EOF
   {
    "username": "adminaccount",
    "password": "${random_password.password.result}"
   }
EOF
}


 
# Importing the AWS secrets created previously using arn.
 
data "aws_secretsmanager_secret" "aurorasecretmasterDB" {
  arn = aws_secretsmanager_secret.aurorasecretmasterDB.arn
}
 
# Importing the AWS secret version created previously using arn.
 
data "aws_secretsmanager_secret_version" "creds" {
  secret_id = data.aws_secretsmanager_secret.aurorasecretmasterDB.arn
}
 
# After importing the secrets storing into Locals
 
locals {
  db_creds = jsondecode(data.aws_secretsmanager_secret_version.creds.secret_string)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = "10.99.0.0/18"

  enable_dns_support   = true
  enable_dns_hostnames = true

  azs              = ["${local.region}a", "${local.region}b", "${local.region}c"]
  public_subnets   = ["10.99.0.0/24", "10.99.1.0/24", "10.99.2.0/24"]
  private_subnets  = ["10.99.3.0/24", "10.99.4.0/24", "10.99.5.0/24"]
  database_subnets = ["10.99.7.0/24", "10.99.8.0/24", "10.99.9.0/24"]

  tags = local.tags
}

################################################################################
# RDS Aurora Module
################################################################################

module "aurora" {
  source = "terraform-aws-modules/rds-aurora/aws"

  name           = local.name
  engine         = "aurora-postgresql"
  engine_version = "14.3"
  instances = {
    1 = {
      instance_class      = "db.r5.2xlarge"
      publicly_accessible = true
    }
    2 = {
      identifier     = "static-member-1"
      instance_class = "db.r5.2xlarge"
    }
    3 = {
      identifier     = "excluded-member-1"
      instance_class = "db.r5.large"
      promotion_tier = 15
    }
  }

  endpoints = {
    static = {
      identifier     = "static-custom-endpt"
      type           = "ANY"
      static_members = ["static-member-1"]
      tags           = { Endpoint = "static-members" }
    }
    excluded = {
      identifier       = "excluded-custom-endpt"
      type             = "READER"
      excluded_members = ["excluded-member-1"]
      tags             = { Endpoint = "excluded-members" }
    }
  }

  vpc_id                 = module.vpc.vpc_id
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  create_db_subnet_group = false
  create_security_group  = true
  allowed_cidr_blocks    = module.vpc.private_subnets_cidr_blocks
  security_group_egress_rules = {
    to_cidrs = {
      cidr_blocks = ["10.33.0.0/28"]
      description = "Egress to corporate printer closet"
    }
  }

  iam_database_authentication_enabled = true
  master_password                     = local.db_creds.password
  create_random_password              = false

  apply_immediately   = true
  skip_final_snapshot = true

  db_parameter_group_name         = aws_db_parameter_group.auroradb.id
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.auroradb.id
  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = local.tags
}

resource "aws_db_parameter_group" "auroradb" {
  name        = "${local.name}-aurora-db-postgres14-parameter-group"
  family      = "aurora-postgresql14"
  description = "${local.name}-aurora-db-postgres14-parameter-group"
  tags        = local.tags
}

resource "aws_rds_cluster_parameter_group" "auroradb" {
  name        = "${local.name}-aurora-postgres14-cluster-parameter-group"
  family      = "aurora-postgresql14"
  description = "${local.name}-aurora-postgres14-cluster-parameter-group"
  tags        = local.tags
}
