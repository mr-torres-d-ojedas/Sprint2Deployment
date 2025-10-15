# ***************** Plataforma de Despachos ***********************
# Infraestructura para el despliegue de la plataforma de despachos
#
# Elementos a desplegar en AWS:
# 1. Grupos de seguridad:
#    - des-traffic-dispatch (puerto 8080)
#    - des-traffic-kong (puertos 8000 y 8001)
#    - des-traffic-db (puerto 5432)
#    - des-traffic-ssh (puerto 22)
#
# 2. Instancias EC2:
#    - des-kong
#    - des-db (PostgreSQL instalado y configurado)
#    - des-dispatch-a (Aplicación Django instalada)
#    - des-dispatch-b (Aplicación Django instalada)
# ******************************************************************

variable "region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "project_prefix" {
  description = "Prefix used for naming AWS resources"
  type        = string
  default     = "des"
}

variable "instance_type" {
  description = "EC2 instance type for application hosts"
  type        = string
  default     = "t2.nano"
}

provider "aws" {
  region = var.region
}

locals {
  project_name = "${var.project_prefix}-dispatch-platform"
  repository   = "https://github.com/mr-torres-d-ojedas/Sprint2.git"
  branch       = "experimento"

  common_tags = {
    Project   = local.project_name
    ManagedBy = "Terraform"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "traffic_dispatch" {
  name        = "${var.project_prefix}-traffic-dispatch"
  description = "Allow application traffic on port 8080"

  ingress {
    description = "HTTP access for dispatch service"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-dispatch"
  })
}

resource "aws_security_group" "traffic_kong" {
  name        = "${var.project_prefix}-traffic-kong"
  description = "Expose Kong circuit breaker ports"

  ingress {
    description = "Kong traffic"
    from_port   = 8000
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-kong"
  })
}

resource "aws_security_group" "traffic_db" {
  name        = "${var.project_prefix}-traffic-db"
  description = "Allow PostgreSQL access"

  ingress {
    description = "Traffic from anywhere to DB"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-db"
  })
}

resource "aws_security_group" "traffic_ssh" {
  name        = "${var.project_prefix}-traffic-ssh"
  description = "Allow SSH access"

  ingress {
    description = "SSH access from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-ssh"
  })
}

resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_kong.id, aws_security_group.traffic_ssh.id]

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-kong"
    Role = "circuit-breaker"
  })
}

resource "aws_instance" "database" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_db.id, aws_security_group.traffic_ssh.id]

  user_data = <<-EOT
              #!/bin/bash
              set -e

              apt-get update -y
              apt-get install -y postgresql postgresql-contrib

              sudo -u postgres psql -c "CREATE USER dispatch_user WITH PASSWORD 'despacho2025';" || true
              sudo -u postgres createdb -O dispatch_user dispatch_db || true

              echo "host all all 0.0.0.0/0 trust" >> /etc/postgresql/16/main/pg_hba.conf
              echo "listen_addresses='*'" >> /etc/postgresql/16/main/postgresql.conf
              echo "max_connections=2000" >> /etc/postgresql/16/main/postgresql.conf

              systemctl restart postgresql
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-db"
    Role = "database"
  })
}
resource "aws_instance" "dispatch" {
  for_each = toset(["a", "b"])

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_dispatch.id, aws_security_group.traffic_ssh.id]

  user_data = <<-EOT
              #!/bin/bash
              set -e

              # Variables de base de datos (compartida)
              echo "DATABASE_HOST=${aws_instance.database.private_ip}" >> /etc/environment
              echo "DATABASE_NAME=dispatch_db" >> /etc/environment
              echo "DATABASE_USER=dispatch_user" >> /etc/environment
              echo "DATABASE_PASSWORD=despacho2025" >> /etc/environment
              echo "DATABASE_PORT=5432" >> /etc/environment

              export DATABASE_HOST=${aws_instance.database.private_ip}
              export DATABASE_NAME=dispatch_db
              export DATABASE_USER=dispatch_user
              export DATABASE_PASSWORD=despacho2025
              export DATABASE_PORT=5432

              sudo apt-get update -y
              sudo apt-get install -y python3-pip git build-essential libpq-dev python3-dev

              mkdir -p /experimento
              cd /experimento

              if [ ! -d Sprint2 ]; then
                git clone ${local.repository}
              fi

              cd Sprint2

              sudo pip3 install --upgrade pip --break-system-packages
              sudo pip3 install -r requirements.txt --break-system-packages

              # Migraciones
              python3 manage.py makemigrations
              python3 manage.py migrate

              # Ejecutar pobladores SOLO en la instancia 'a'
              if [ "${each.key}" = "a" ]; then
                echo "[populate] Ejecutando en instancia dispatch-a" | tee -a /var/log/provision.log
                # Poblar productos/pedidos y despachos
                python3 populate.py            >> /var/log/provision.log 2>&1 || true
                python3 populateDespachos.py   >> /var/log/provision.log 2>&1 || true
              else
                echo "[populate] Saltado en instancia dispatch-${each.key}" | tee -a /var/log/provision.log
              fi
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-dispatch-${each.key}"
    Role = "dispatch"
  })

  depends_on = [aws_instance.database]
}

output "kong_public_ip" {
  description = "Public IP address for the Kong circuit breaker instance"
  value       = aws_instance.kong.public_ip
}

output "dispatch_public_ips" {
  description = "Public IP addresses for the dispatch service instances"
  value       = { for id, instance in aws_instance.dispatch : id => instance.public_ip }
}

output "dispatch_private_ips" {
  description = "Private IP addresses for the dispatch service instances"
  value       = { for id, instance in aws_instance.dispatch : id => instance.private_ip }
}

output "database_private_ip" {
  description = "Private IP address for the PostgreSQL database instance"
  value       = aws_instance.database.private_ip
}