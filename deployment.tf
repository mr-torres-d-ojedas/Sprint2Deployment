# ***************** Universidad de los Andes ***********************
# ****** Departamento de Ingeniería de Sistemas y Computación ******
# ********** Arquitectura y diseño de Software - Sprint2 ***********
#
# Infraestructura para la plataforma de despachos (Sprint2)

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
  repository   = "https://github.com/mr-torres-d-ojedas/Sprint2.git"

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
# Obtener VPC y subnets por defecto
# ------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ------------------------------------------------------------
# Grupos de seguridad
# ------------------------------------------------------------

resource "aws_security_group" "traffic_django" {
  name        = "${var.project_prefix}-traffic-django"
  description = "Allow Django traffic on port 8080"

  ingress {
    description = "HTTP access from Kong"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-django" })
}

# COMENTADO: Security group del ALB (no necesario sin Load Balancer)
# resource "aws_security_group" "traffic_alb" {
#   name        = "${var.project_prefix}-traffic-alb"
#   description = "Allow HTTP traffic to Load Balancer"
#
#   ingress {
#     description = "HTTP from anywhere"
#     from_port   = 80
#     to_port     = 80
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#
#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#
#   tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-alb" })
# }

resource "aws_security_group" "traffic_db" {
  name        = "${var.project_prefix}-traffic-db"
  description = "Allow PostgreSQL access"

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
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

# CORREGIDO: Agregado egress para que Kong pueda comunicarse con backends
resource "aws_security_group" "traffic_cb" {
  name        = "${var.project_prefix}-traffic-cb"
  description = "Expose Kong circuit breaker ports"

  ingress {
    description = "Kong Proxy traffic"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kong Admin API"
    from_port   = 8001
    to_port     = 8001
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
    Name = "${var.project_prefix}-traffic-cb"
  })
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
# Instancias: Django Sprint2 (2 réplicas: a y b)
# ------------------------------------------------------------
resource "aws_instance" "dispatch" {
  for_each = toset(["a", "b"])

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_django.id, aws_security_group.traffic_ssh.id]

  user_data = <<-EOT
#!/bin/bash
set -e
echo "[INIT] Backend Sprint2 ${each.key} - $(date)" | tee -a /var/log/backend.log

# Configuración de base de datos
DB_IP="${aws_instance.database.private_ip}"
echo "DATABASE_HOST=$DB_IP" >> /etc/environment
export DATABASE_HOST=$DB_IP
echo "[DB] $DB_IP OK" | tee -a /var/log/backend.log

# Instalación de dependencias del sistema
apt-get update -y
apt-get install -y python3-pip python3-venv git build-essential libpq-dev python3-dev

# Clonar proyecto
mkdir -p /apps
cd /apps
git clone ${local.repository}
cd Sprint2

# Crear entorno virtual
python3 -m venv /apps/Sprint2/venv

# Instalar dependencias en el entorno virtual
/apps/Sprint2/venv/bin/pip install --upgrade pip
/apps/Sprint2/venv/bin/pip install -r requirements.txt
/apps/Sprint2/venv/bin/pip install psycopg2-binary
echo "[PIP] OK" | tee -a /var/log/backend.log

# Migraciones
/apps/Sprint2/venv/bin/python manage.py makemigrations | tee -a /var/log/backend.log
/apps/Sprint2/venv/bin/python manage.py migrate | tee -a /var/log/backend.log
echo "[MIGRATE] OK" | tee -a /var/log/backend.log

# Poblar datos iniciales
/apps/Sprint2/venv/bin/python populate.py | tee -a /var/log/backend.log || true
/apps/Sprint2/venv/bin/python populateDespachos.py | tee -a /var/log/backend.log || true
echo "[POPULATE] OK" | tee -a /var/log/backend.log

# Levantar servidor Django
nohup /apps/Sprint2/venv/bin/python manage.py runserver 0.0.0.0:8080 > /var/log/django.log 2>&1 &
echo "[DJANGO] 8080 OK" | tee -a /var/log/backend.log
EOT

  depends_on = [aws_instance.database]
  tags       = merge(local.common_tags, { Name = "${var.project_prefix}-backend-${each.key}" })
}

# ------------------------------------------------------------
# Application Load Balancer (ALB) - COMENTADO
# ------------------------------------------------------------
# NOTA: Si solo quieres usar Kong como balanceador, comenta todo este bloque
# resource "aws_lb" "main" {
#   name               = "${var.project_prefix}-alb"
#   internal           = false
#   load_balancer_type = "application"
#   security_groups    = [aws_security_group.traffic_alb.id]
#   subnets            = data.aws_subnets.default.ids
#
#   enable_deletion_protection = false
#
#   tags = merge(local.common_tags, { Name = "${var.project_prefix}-alb" })
# }

# ------------------------------------------------------------
# Target Group (para los backends) - COMENTADO
# ------------------------------------------------------------
# resource "aws_lb_target_group" "backend" {
#   name     = "${var.project_prefix}-backend-tg"
#   port     = 8080
#   protocol = "HTTP"
#   vpc_id   = data.aws_vpc.default.id
#
#   health_check {
#     enabled             = true
#     healthy_threshold   = 2
#     unhealthy_threshold = 2
#     timeout             = 5
#     interval            = 30
#     path                = "/"
#     matcher             = "200-399"
#   }
#
#   tags = merge(local.common_tags, { Name = "${var.project_prefix}-backend-tg" })
# }

# Registrar instancias en el Target Group - COMENTADO
# ------------------------------------------------------------
# resource "aws_lb_target_group_attachment" "backend" {
#   for_each = aws_instance.dispatch
#
#   target_group_arn = aws_lb_target_group.backend.arn
#   target_id        = each.value.id
#   port             = 8080
# }

# ------------------------------------------------------------
# Listener del Load Balancer (puerto 80) - COMENTADO
# ------------------------------------------------------------
# resource "aws_lb_listener" "http" {
#   load_balancer_arn = aws_lb.main.arn
#   port              = "80"
#   protocol          = "HTTP"
#
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.backend.arn
#   }
# }

# ------------------------------------------------------------
# Instancia EC2 para Kong (Circuit Breaker) - VERSIÓN ÚNICA CORREGIDA
# ------------------------------------------------------------
resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.small" # Kong necesita más recursos
  associate_public_ip_address = true
  vpc_security_group_ids      = [
    aws_security_group.traffic_cb.id, 
    aws_security_group.traffic_ssh.id
  ]

  user_data = <<-EOT
#!/bin/bash
set -e
echo "[KONG] Iniciando instalación - $(date)" | tee -a /var/log/kong.log

# Actualizar sistema
apt-get update -y
apt-get install -y curl wget apt-transport-https lsb-release ca-certificates

# Instalar PostgreSQL client
apt-get install -y postgresql-client

# Instalar Kong
curl -Lo kong-3.5.0.amd64.deb "https://download.konghq.com/gateway-3.x-ubuntu-$(lsb_release -cs)/pool/all/k/kong/kong_3.5.0_amd64.deb"
dpkg -i kong-3.5.0.amd64.deb || apt-get install -y -f

# Esperar a que la BD esté lista
until PGPASSWORD=despacho2025 psql -h ${aws_instance.database.private_ip} -U dispatch_user -d dispatch_db -c '\q' 2>/dev/null; do
  echo "Esperando PostgreSQL..." | tee -a /var/log/kong.log
  sleep 5
done

# Crear base de datos para Kong
PGPASSWORD=despacho2025 psql -h ${aws_instance.database.private_ip} -U dispatch_user -d postgres <<SQL
CREATE DATABASE kong_db;
GRANT ALL PRIVILEGES ON DATABASE kong_db TO dispatch_user;
SQL

# Configurar Kong
cat > /etc/kong/kong.conf <<CONF
database = postgres
pg_host = ${aws_instance.database.private_ip}
pg_port = 5432
pg_user = dispatch_user
pg_password = despacho2025
pg_database = kong_db
proxy_listen = 0.0.0.0:8000
admin_listen = 0.0.0.0:8001
CONF

# Migrar base de datos de Kong
kong migrations bootstrap -c /etc/kong/kong.conf
echo "[KONG] Migraciones completadas" | tee -a /var/log/kong.log

# Iniciar Kong
kong start -c /etc/kong/kong.conf
echo "[KONG] Kong iniciado en puerto 8000 (proxy) y 8001 (admin)" | tee -a /var/log/kong.log

# Esperar a que Kong esté listo
sleep 10

# Configurar servicios y rutas para los backends
BACKEND_A_IP="${aws_instance.dispatch["a"].private_ip}"
BACKEND_B_IP="${aws_instance.dispatch["b"].private_ip}"

# Crear upstream (pool de backends)
curl -i -X POST http://localhost:8001/upstreams \
  --data name=backend-cluster \
  --data healthchecks.active.type=http \
  --data healthchecks.active.http_path=/ \
  --data healthchecks.active.healthy.interval=10 \
  --data healthchecks.active.healthy.successes=2 \
  --data healthchecks.active.unhealthy.interval=10 \
  --data healthchecks.active.unhealthy.http_failures=3

# Agregar targets (backends) al upstream
curl -i -X POST http://localhost:8001/upstreams/backend-cluster/targets \
  --data target="$BACKEND_A_IP:8080" \
  --data weight=100

curl -i -X POST http://localhost:8001/upstreams/backend-cluster/targets \
  --data target="$BACKEND_B_IP:8080" \
  --data weight=100

# Crear servicio
curl -i -X POST http://localhost:8001/services \
  --data name=dispatch-service \
  --data host=backend-cluster \
  --data path=/

# Crear ruta
curl -i -X POST http://localhost:8001/services/dispatch-service/routes \
  --data paths[]=/

# Habilitar plugin de Rate Limiting
curl -i -X POST http://localhost:8001/plugins \
  --data name=rate-limiting \
  --data config.minute=100

echo "[KONG] Configuración completada" | tee -a /var/log/kong.log
echo "[KONG] Backends configurados: $BACKEND_A_IP:8080, $BACKEND_B_IP:8080" | tee -a /var/log/kong.log
EOT

  depends_on = [
    aws_instance.database,
    aws_instance.dispatch
  ]

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-kong"
    Role = "circuit-breaker"
  })
}

# ------------------------------------------------------------
# Salidas
# ------------------------------------------------------------
output "kong_public_ip" {
  description = "Public IP address for the Kong circuit breaker instance"
  value       = aws_instance.kong.public_ip
}

output "kong_proxy_url" {
  description = "Kong Proxy URL (acceso principal a la aplicación)"
  value       = "http://${aws_instance.kong.public_ip}:8000"
}

output "kong_admin_url" {
  description = "Kong Admin API URL (para configuración)"
  value       = "http://${aws_instance.kong.public_ip}:8001"
}

output "database_private_ip" {
  description = "IP privada de la base de datos PostgreSQL"
  value       = aws_instance.database.private_ip
}

output "backend_private_ips" {
  description = "IPs privadas de las instancias backend"
  value       = { for k, v in aws_instance.dispatch : k => v.private_ip }
}

output "backend_public_ips" {
  description = "IPs públicas de las instancias backend (acceso directo)"
  value       = { for k, v in aws_instance.dispatch : k => v.public_ip }
}

# COMENTADO: Outputs del Load Balancer (no disponible sin ALB)
# output "load_balancer_dns" {
#   description = "DNS del Load Balancer"
#   value       = aws_lb.main.dns_name
# }

# output "application_url" {
#   description = "URL completa de tu aplicación"
#   value       = "http://${aws_lb.main.dns_name}"
# }

output "instructions" {
  description = "Instrucciones de uso"
  value       = <<-INSTRUCTIONS

🚀 DESPLIEGUE COMPLETADO EXITOSAMENTE (SIN ALB)

🔀 ACCESO PRINCIPAL VÍA KONG (CIRCUIT BREAKER + LOAD BALANCER):
   ✨ URL Principal: http://${aws_instance.kong.public_ip}:8000
   🔧 Admin API:     http://${aws_instance.kong.public_ip}:8001

🖥️  Backends directos (solo para pruebas/debugging):
   Backend A: http://${aws_instance.dispatch["a"].public_ip}:8080
   Backend B: http://${aws_instance.dispatch["b"].public_ip}:8080

💾 Base de datos PostgreSQL:
   IP privada: ${aws_instance.database.private_ip}:5432

📊 KONG Configuration:
   ✅ Balanceo de carga entre 2 backends (Round Robin)
   ✅ Health checks activos cada 10 segundos
   ⚡ Rate limiting: 100 peticiones/minuto
   🛡️  Circuit breaker: 3 fallos → circuit abierto
   🔄 Auto-recuperación de backends fallidos

🔍 COMANDOS ÚTILES (desde Kong server o usando su IP pública):
   # Ver estado de backends
   curl http://${aws_instance.kong.public_ip}:8001/upstreams/backend-cluster/health
   
   # Ver servicios configurados
   curl http://${aws_instance.kong.public_ip}:8001/services
   
   # Ver plugins activos
   curl http://${aws_instance.kong.public_ip}:8001/plugins
   
   # Ver targets y su estado
   curl http://${aws_instance.kong.public_ip}:8001/upstreams/backend-cluster/targets

📝 NOTA: Kong actúa como único punto de entrada (Circuit Breaker + Load Balancer)
⏱️  Los servicios pueden tardar 2-3 minutos en estar completamente operativos

INSTRUCTIONS
}