provider "aws" {
  region = "eu-west-3"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "3.11.0"

  name = "my-vpc"
  cidr = "10.1.0.0/16"

  azs             = ["eu-west-3a", "eu-west-3b"]
  private_subnets = ["10.1.1.0/24", "10.1.2.0/24"]
  public_subnets  = ["10.1.101.0/24", "10.1.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
  manage_default_route_table = true

  tags = {
    Terraform = "true"
    Environment = "master-ec2"
  }
}

resource "aws_iam_instance_profile" "ssm" {
  name = "ssm"
  role = aws_iam_role.ssm.name
}

resource "aws_iam_role" "ssm" {
  name = "ssm_role"
  path = "/"

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
               "Service": "ec2.amazonaws.com"
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}
resource "aws_iam_policy" "secret_manager_read" {
  name = "secret_manager_read"
  path = "/"

  policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action = [
            "secretsmanager:GetSecretValue",
          ]
          Effect   = "Allow"
          Resource = aws_secretsmanager_secret.phpmyadmin_config.arn
        },
      ]
    })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

resource "aws_iam_role_policy_attachment" "secret_manager_read" {
  role = aws_iam_role.ssm.name
  policy_arn = aws_iam_policy.secret_manager_read.arn
}

resource "aws_key_pair" "student" {
  key_name   = "student"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCz2R7B74v9XjZ8QBIK3vlmiEwE7D3s750IGsdoEE1WyzErqSD0pau8tVLcct6o/IP8F9irD5vTsbgfbBR7h3Tcchr+sBUgIIIPRJw2Xvfb0XdYVSnHgG1UdLVGjuSmaRgMkxdy0BndRE6noxMSM764tpbmJmXDQSK7VwwFzfmgm/h40nPN6ERd3vHz1VmQflh93+nS+88dZl3cYlIbMQY9nAXQ0BNpTcW4NEnw6+snNx+POkC9SGqDuMPA9Irb0N2JRUYCy0yfA9yawycw+81r1gT3aPZ44vFXkyC6s8DxxB/4EpsJ1uEaMOFydqpXlRXJpLvQ65FH89BZQainNAXd4QP0173hObsIicNze2v3kpM7SUHh8zfrTFbUJMrKd3Lz6HLWaZhifdAGfEjosPevKNCLzAsgBZHC2gbyaPvL6KpBDERs+y3FQr0ki3i4q5YwlIBmlRnjlSdSJr+r+ch96y+CK6Ojk0sZikiXlzpTX1SillcLzg2kVmkolUe63sk= student"
}

resource "aws_db_subnet_group" "db" {
  name       = "main"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "allow_sql" {
  name        = "allow_sql"
  description = "Allow SQL traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description      = "tcp"
    from_port        = 3306
    to_port          = 3306
    protocol         = "tcp"
    cidr_blocks      = ["10.0.0.0/8"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group" "webservers" {
  name        = "webservers"
  description = "Allow HTTP traffic to the webservers"
  vpc_id      = module.vpc.vpc_id


  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_db_instance" "mysql" {
  allocated_storage    = 10
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "db.t3.micro"
  name                 = "mydb"
  username             = "applicationuser"
  password             = "a_secured_password"
  parameter_group_name = "default.mysql5.7"
  skip_final_snapshot  = true

  db_subnet_group_name = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.allow_sql.id]
}

resource "aws_secretsmanager_secret" "phpmyadmin_config" {
  name = "phpmyadmin_config"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "phpmyadmin_config" {
  secret_id     = aws_secretsmanager_secret.phpmyadmin_config.id
  secret_string = templatefile(
               "${path.module}/config.inc.php.tpl",
               {
                 config = {
                   "host"   = aws_db_instance.mysql.address
                   "user" = aws_db_instance.mysql.username
                   "password" = aws_db_instance.mysql.password
                 }
               }
              )
}