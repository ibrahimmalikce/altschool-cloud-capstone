terraform {
  required_version = ">= 1.3.0"
  
  backend "s3" {
    bucket = "bedrock-state-alt-soe-025-3210"
    key    = "capstone/terraform.tfstate"
    region = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project = "karatu-2025-capstone"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"
  
  name = "project-bedrock-vpc"
  cidr = "10.0.0.0/16" 
  
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
  
  enable_nat_gateway   = true
  single_nat_gateway   = true 
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"
  
  cluster_name    = "project-bedrock-cluster"
  cluster_version = "1.30" 
  
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  cluster_endpoint_public_access  = true
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets 
  control_plane_subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    capstone_nodes = {
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_x86_64_STANDARD" 
    }
  }
  
  enable_cluster_creator_admin_permissions = true
}

resource "aws_security_group" "db_sg" {
  name   = "bedrock-db-sg"
  vpc_id = module.vpc.vpc_id
  
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
}

resource "aws_db_subnet_group" "db_subnet" {
  name       = "bedrock-db-subnet"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/bedrock/database/password"
  type  = "SecureString"
  value = "InnovateMart2026!"
}

resource "aws_db_instance" "mysql" {
  identifier             = "bedrock-mysql"
  engine                 = "mysql"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  username               = "admin"
  password               = aws_ssm_parameter.db_password.value
  db_subnet_group_name   = aws_db_subnet_group.db_subnet.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  skip_final_snapshot    = true
}

resource "aws_db_instance" "postgres" {
  identifier             = "bedrock-postgres"
  engine                 = "postgres"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  username               = "dbadmin"
  password               = aws_ssm_parameter.db_password.value
  db_subnet_group_name   = aws_db_subnet_group.db_subnet.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  skip_final_snapshot    = true
}

resource "aws_dynamodb_table" "dynamo" {
  name         = "bedrock-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  
  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_iam_user" "developer" {
  name = "bedrock-dev-view"
}

resource "aws_iam_user_policy_attachment" "dev_readonly" {
  user       = aws_iam_user.developer.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_user_policy" "dev_s3" {
  name = "dev-s3-put"
  user = aws_iam_user.developer.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = "s3:PutObject"
      Effect   = "Allow"
      Resource = "${aws_s3_bucket.assets.arn}/*"
    }]
  })
}

resource "aws_s3_bucket" "assets" {
  bucket = "bedrock-assets-alt-soe-025-3210"
}

resource "aws_iam_role" "lambda_role" {
  name = "bedrock_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "lambda_code" {
  type        = "zip"
  output_path = "${path.module}/lambda.zip"
  source {
    filename = "index.py"
    content  = <<EOF
def lambda_handler(event, context):
    for record in event.get('Records', []):
        print(f"Image received: {record['s3']['object']['key']}")
EOF
  }
}

resource "aws_lambda_function" "asset_processor" {
  filename      = data.archive_file.lambda_code.output_path
  function_name = "bedrock-asset-processor"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.12"
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.asset_processor.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.assets.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.assets.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.asset_processor.arn
    events              = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_lambda_permission.allow_s3]
}

resource "tls_private_key" "bastion_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "bastion_key_pair" {
  key_name   = "capstone-bastion-key"
  public_key = tls_private_key.bastion_key.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.bastion_key.private_key_pem
  filename        = "${path.module}/bastion-key.pem"
  file_permission = "0400"
}

resource "aws_security_group" "bastion_sg" {
  name   = "bastion-sg"
  vpc_id = module.vpc.vpc_id
  
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.bastion_key_pair.key_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
output "cluster_name" {
  value = module.eks.cluster_name
}
output "region" {
  value = "us-east-1"
}
output "vpc_id" {
  value = module.vpc.vpc_id
}
output "assets_bucket_name" {
  value = aws_s3_bucket.assets.id
}
output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}