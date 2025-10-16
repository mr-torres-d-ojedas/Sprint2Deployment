# ***************** Universidad de los Andes ***********************
# ****** Departamento de Ingeniería de Sistemas y Computación ******
# ********** Arquitectura y diseño de Software - Sprint2 ***********
#
# Infraestructura para la plataforma de despachos (Sprint2)
#
# Elementos a desplegar en AWS:
# 1. Grupos de seguridad:
#    - des-traffic-django (puerto 8080)
#    - des-traffic-kong (puertos 8000 y 8001)
#    - des-traffic-db (puerto 5432)
#    - des-traffic-ssh (puerto 22)
#
# 2. Instancias EC2:
#    - des-kong (Kong API Gateway)
#    - des-db (PostgreSQL)
#    - des-backend (Aplicación Django Sprint2)
# ******************************************************************

variable "region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "project_prefix" {
  description = "Prefix used for AWS resource names"
  type        = string
  default     = "des"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.nano"
}

provider "aws" {
  region = var.region
}

locals {
  project_name = "${var.project_prefix}-sprint2"
  repository   = "https://github.com/mr-torres-d-ojedas/Sprint2.git" # <-- cámbialo a tu repo

  common_tags = {
    Project   = local.project_name
    ManagedBy = "Terraform"
  }
}

# ------------------------------------------------------------
# Imagen base (Ubuntu 24.04)
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Grupos de seguridad
# ------------------------------------------------------------

resource "aws_security_group" "traffic_django" {
  name        = "${var.project_prefix}-traffic-django"
  description = "Allow Django traffic on port 8080"

  ingress {
    description = "HTTP access"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-django" })
}

resource "aws_security_group" "traffic_kong" {
  name        = "${var.project_prefix}-traffic-kong"
  description = "Allow Kong traffic"

  ingress {
    from_port   = 8000
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-kong" })
}

resource "aws_security_group" "traffic_db" {
  name        = "${var.project_prefix}-traffic-db"
  description = "Allow PostgreSQL access"

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-db" })
}

resource "aws_security_group" "traffic_ssh" {
  name        = "${var.project_prefix}-traffic-ssh"
  description = "Allow SSH access"

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

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-ssh" })
}

# ------------------------------------------------------------
# Instancia: Base de datos PostgreSQL
# ------------------------------------------------------------
resource "aws_instance" "database" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_db.id, aws_security_group.traffic_ssh.id]

user_data = <<-EOT
  #!/bin/bash
  apt-get update -y
  apt-get install -y postgresql postgresql-contrib
  sudo -u postgres psql -c "CREATE USER dispatch_user WITH PASSWORD 'despacho2025';"
  sudo -u postgres createdb -O dispatch_user dispatch_db
  echo "host all all 0.0.0.0/0 trust" >> /etc/postgresql/16/main/pg_hba.conf
  echo "listen_addresses='*'" >> /etc/postgresql/16/main/postgresql.conf
  echo "max_connections=2000" >> /etc/postgresql/16/main/postgresql.conf
  systemctl restart postgresql
EOT


  tags = merge(local.common_tags, { Name = "${var.project_prefix}-db" })
}

  
# ------------------------------------------------------------
# Instancia: Django Sprint2 (CORREGIDO)
# ------------------------------------------------------------
resource "aws_instance" "backend" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_django.id, aws_security_group.traffic_ssh.id]

user_data = <<-EOT
#!/bin/bash
set -e
echo "[INIT] Backend Sprint2 - $(date)" | tee -a /var/log/backend.log

# ✅ Configuración de base de datos
DB_IP="${aws_instance.database.private_ip}"
echo "DATABASE_HOST=$DB_IP" >> /etc/environment
export DATABASE_HOST=$DB_IP
echo "[DB] $DB_IP OK" | tee -a /var/log/backend.log

# ✅ Instalación de dependencias del sistema
apt-get update -y
apt-get install -y python3-pip python3-venv git build-essential libpq-dev python3-dev

# ✅ Clonar proyecto
mkdir -p /apps
cd /apps
git clone ${local.repository}
cd Sprint2

# ✅ Crear entorno virtual
python3 -m venv /apps/Sprint2/venv

# ✅ Instalar dependencias en el entorno virtual
/apps/Sprint2/venv/bin/pip install --upgrade pip
/apps/Sprint2/venv/bin/pip install -r requirements.txt
/apps/Sprint2/venv/bin/pip install psycopg2-binary
echo "[PIP] OK" | tee -a /var/log/backend.log

# ✅ Migraciones
/apps/Sprint2/venv/bin/python manage.py makemigrations | tee -a /var/log/backend.log
/apps/Sprint2/venv/bin/python manage.py migrate | tee -a /var/log/backend.log
echo "[MIGRATE] OK" | tee -a /var/log/backend.log

# ✅ Poblar datos iniciales
/apps/Sprint2/venv/bin/python populate.py | tee -a /var/log/backend.log || true
/apps/Sprint2/venv/bin/python populateDespachos.py | tee -a /var/log/backend.log || true
echo "[POPULATE] OK" | tee -a /var/log/backend.log

# ✅ Levantar servidor Django
nohup /apps/Sprint2/venv/bin/python manage.py runserver 0.0.0.0:8080 > /var/log/django.log 2>&1 &
echo "[DJANGO] 8080 OK" | tee -a /var/log/backend.log
EOT


  depends_on = [aws_instance.database]
  tags = merge(local.common_tags, { Name = "${var.project_prefix}-backend" })
}

# ------------------------------------------------------------
# Instancia: Kong (API Gateway)
# ------------------------------------------------------------
resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_kong.id, aws_security_group.traffic_ssh.id]

  user_data = <<-EOT
              #!/bin/bash
              apt-get update -y
              apt-get install -y docker.io docker-compose
              systemctl start docker
              systemctl enable docker
              EOT

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-kong" })
}

# ------------------------------------------------------------
# Salidas
# ------------------------------------------------------------
output "database_private_ip" {
  value = aws_instance.database.private_ip
}

output "backend_public_ip" {
  value = aws_instance.backend.public_ip
}

output "kong_public_ip" {
  value = aws_instance.kong.public_ip
}


