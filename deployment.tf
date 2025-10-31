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
set -e
apt-get update -y
apt-get install -y postgresql postgresql-contrib

# Configurar PostgreSQL
sudo -u postgres psql -c "CREATE USER dispatch_user WITH PASSWORD 'despacho2025' SUPERUSER;"
sudo -u postgres createdb -O dispatch_user dispatch_db

# Configuración de acceso remoto
echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/16/main/pg_hba.conf
echo "listen_addresses='*'" >> /etc/postgresql/16/main/postgresql.conf
echo "max_connections=200" >> /etc/postgresql/16/main/postgresql.conf

systemctl restart postgresql
echo "[DB] PostgreSQL configurado correctamente" | tee -a /var/log/database.log
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
echo "[INIT] Backend Sprint2 ${each.key} - $$(date)" | tee -a /var/log/backend.log

# Configuración de base de datos
DB_IP="${aws_instance.database.private_ip}"
echo "DATABASE_HOST=$${DB_IP}" >> /etc/environment
export DATABASE_HOST=$${DB_IP}
echo "[DB] $${DB_IP} OK" | tee -a /var/log/backend.log

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

# Esperar a que la BD esté lista con verificación
timeout=180
elapsed=0
until PGPASSWORD=despacho2025 psql -h $${DB_IP} -U dispatch_user -d dispatch_db -c '\q' 2>/dev/null; do
  if [ $${elapsed} -ge $${timeout} ]; then
    echo "[ERROR] Timeout esperando PostgreSQL" | tee -a /var/log/backend.log
    exit 1
  fi
  echo "[WAIT] Esperando PostgreSQL..." | tee -a /var/log/backend.log
  sleep 5
  elapsed=$$((elapsed + 5))
done

# Migraciones
/apps/Sprint2/venv/bin/python manage.py makemigrations | tee -a /var/log/backend.log
/apps/Sprint2/venv/bin/python manage.py migrate | tee -a /var/log/backend.log
echo "[MIGRATE] OK" | tee -a /var/log/backend.log

# Poblar datos iniciales (solo en backend-a)
if [ "${each.key}" = "a" ]; then
  /apps/Sprint2/venv/bin/python populate.py | tee -a /var/log/backend.log || true
  /apps/Sprint2/venv/bin/python populateDespachos.py | tee -a /var/log/backend.log || true
  echo "[POPULATE] OK" | tee -a /var/log/backend.log
fi

# Crear endpoint de health check
mkdir -p /apps/Sprint2/health_app
cat > /apps/Sprint2/health_app/__init__.py <<'PYINIT'
PYINIT

cat > /apps/Sprint2/health_app/views.py <<'PYVIEWS'
from django.http import JsonResponse

def health_check(request):
    return JsonResponse({"status": "healthy", "backend": "${each.key}"}, status=200)
PYVIEWS

cat > /apps/Sprint2/health_app/urls.py <<'PYURLS'
from django.urls import path
from . import views

urlpatterns = [
    path('health', views.health_check, name='health'),
]
PYURLS

# Agregar health_app a INSTALLED_APPS y urls
if ! grep -q "health_app" /apps/Sprint2/dispatch_platform/settings.py; then
    sed -i "/INSTALLED_APPS = \[/a\    'health_app'," /apps/Sprint2/dispatch_platform/settings.py
fi

if ! grep -q "health_app" /apps/Sprint2/dispatch_platform/urls.py; then
    sed -i "s|from django.urls import path|from django.urls import path, include|" /apps/Sprint2/dispatch_platform/urls.py
    sed -i "/urlpatterns = \[/a\    path('', include('health_app.urls'))," /apps/Sprint2/dispatch_platform/urls.py
fi

# Levantar servidor Django
nohup /apps/Sprint2/venv/bin/python manage.py runserver 0.0.0.0:8080 > /var/log/django.log 2>&1 &
echo "[DJANGO] 8080 OK" | tee -a /var/log/backend.log

# Crear archivo de estado para Kong
echo "READY" > /tmp/backend_ready
EOT

  depends_on = [aws_instance.database]
  tags       = merge(local.common_tags, { Name = "${var.project_prefix}-backend-${each.key}" })
}

# ------------------------------------------------------------
# Kong CORREGIDO - Instalación y configuración mejorada
# ------------------------------------------------------------
resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.small"
  associate_public_ip_address = true
  vpc_security_group_ids      = [
    aws_security_group.traffic_cb.id, 
    aws_security_group.traffic_ssh.id
  ]

  user_data = <<-EOT
#!/bin/bash
set -e
set -x
trap 'echo "ERROR en línea $${LINENO} de Kong"' ERR

echo "[KONG] Iniciando instalación - $$(date)" | tee -a /var/log/kong.log

# Actualizar sistema
apt-get update -y
apt-get install -y curl wget postgresql-client

# Instalar Kong usando paquete .deb
KONG_VERSION=3.5.0
curl -Lo /tmp/kong.deb "https://download.konghq.com/gateway-3.x-ubuntu-$$(lsb_release -cs)/pool/all/k/kong/kong_$${KONG_VERSION}_amd64.deb"
dpkg -i /tmp/kong.deb || apt-get install -f -y

echo "[KONG] Kong $${KONG_VERSION} instalado" | tee -a /var/log/kong.log

# Esperar PostgreSQL
DB_IP="${aws_instance.database.private_ip}"
timeout=300
elapsed=0
until PGPASSWORD=despacho2025 psql -h $${DB_IP} -U dispatch_user -d dispatch_db -c '\q' 2>/dev/null; do
  if [ $${elapsed} -ge $${timeout} ]; then
    echo "[ERROR] Timeout esperando PostgreSQL" | tee -a /var/log/kong.log
    exit 1
  fi
  sleep 5
  elapsed=$$((elapsed + 5))
done

# Crear BD de Kong
PGPASSWORD=despacho2025 psql -h $${DB_IP} -U dispatch_user -d postgres <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'kong_db';
DROP DATABASE IF EXISTS kong_db;
CREATE DATABASE kong_db;
SQL

# Configurar Kong
mkdir -p /etc/kong
cat > /etc/kong/kong.conf <<CONF
database = postgres
pg_host = $${DB_IP}
pg_port = 5432
pg_user = dispatch_user
pg_password = despacho2025
pg_database = kong_db
proxy_listen = 0.0.0.0:8000
admin_listen = 0.0.0.0:8001
log_level = info
nginx_worker_processes = auto
CONF

# Migrar BD
kong migrations bootstrap -c /etc/kong/kong.conf 2>&1 | tee -a /var/log/kong.log

# Iniciar Kong
kong start -c /etc/kong/kong.conf 2>&1 | tee -a /var/log/kong.log

# Esperar a que Kong responda
timeout=60
elapsed=0
until curl -sf http://localhost:8001 > /dev/null; do
  if [ $${elapsed} -ge $${timeout} ]; then
    echo "[ERROR] Kong no responde" | tee -a /var/log/kong.log
    exit 1
  fi
  sleep 3
  elapsed=$$((elapsed + 3))
done

echo "[KONG] Kong operativo" | tee -a /var/log/kong.log

# IPs de backends
BACKEND_A_IP="${aws_instance.dispatch["a"].private_ip}"
BACKEND_B_IP="${aws_instance.dispatch["b"].private_ip}"

# Esperar backends (health endpoint)
for IP in $${BACKEND_A_IP} $${BACKEND_B_IP}; do
  timeout=300
  elapsed=0
  until curl -sf "http://$${IP}:8080/health" > /dev/null 2>&1; do
    if [ $${elapsed} -ge $${timeout} ]; then
      echo "[WARNING] Backend $${IP} no responde, continuando..." | tee -a /var/log/kong.log
      break
    fi
    sleep 10
    elapsed=$$((elapsed + 10))
  done
done

# Configurar upstream con health checks
curl -sf -X POST http://localhost:8001/upstreams \
  --data name=backend-cluster \
  --data healthchecks.active.type=http \
  --data healthchecks.active.http_path=/health \
  --data healthchecks.active.timeout=3 \
  --data healthchecks.active.interval=10 \
  --data healthchecks.active.healthy.successes=2 \
  --data healthchecks.active.unhealthy.http_failures=3 \
  --data healthchecks.active.unhealthy.timeouts=2

# Agregar targets
curl -sf -X POST http://localhost:8001/upstreams/backend-cluster/targets \
  --data target="$${BACKEND_A_IP}:8080" --data weight=100

curl -sf -X POST http://localhost:8001/upstreams/backend-cluster/targets \
  --data target="$${BACKEND_B_IP}:8080" --data weight=100

# Crear servicio
curl -sf -X POST http://localhost:8001/services \
  --data name=dispatch-service \
  --data host=backend-cluster \
  --data protocol=http \
  --data connect_timeout=60000 \
  --data write_timeout=60000 \
  --data read_timeout=60000

# Crear rutas
curl -sf -X POST http://localhost:8001/services/dispatch-service/routes \
  --data "paths[]=/despachos/reporte" \
  --data strip_path=false \
  --data preserve_host=false

curl -sf -X POST http://localhost:8001/services/dispatch-service/routes \
  --data "paths[]=/health" \
  --data strip_path=false

# Rate limiting
curl -sf -X POST http://localhost:8001/plugins \
  --data name=rate-limiting \
  --data config.second=10 \
  --data config.minute=100 \
  --data config.hour=5000 \
  --data config.policy=local \
  --data config.fault_tolerant=true

# Plugin de logging
curl -sf -X POST http://localhost:8001/plugins \
  --data name=file-log \
  --data config.path=/var/log/kong-requests.log

echo "[KONG] Configuración completada" | tee -a /var/log/kong.log
echo "[KONG] URL principal: http://$$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8000/despachos/reporte"
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
  value       = "http://${aws_instance.kong.public_ip}:8000/despachos/reporte"
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

output "instructions" {
  description = "Instrucciones de uso"
  value       = <<-INSTRUCTIONS

🚀 DESPLIEGUE COMPLETADO EXITOSAMENTE

🔀 ACCESO PRINCIPAL VÍA KONG (CIRCUIT BREAKER + LOAD BALANCER):
   ✨ URL Principal: http://${aws_instance.kong.public_ip}:8000/despachos/reporte
   🏥 Health Check: http://${aws_instance.kong.public_ip}:8000/health
   🔧 Admin API: http://${aws_instance.kong.public_ip}:8001

🖥️  Backends directos (solo para pruebas/debugging):
   Backend A: http://${aws_instance.dispatch["a"].public_ip}:8080/despachos/reporte
   Backend B: http://${aws_instance.dispatch["b"].public_ip}:8080/despachos/reporte

💾 Base de datos PostgreSQL:
   IP privada: ${aws_instance.database.private_ip}:5432
   Usuario: dispatch_user
   Base de datos: dispatch_db

📊 KONG Configuration:
   ✅ Balanceo de carga entre 2 backends (Round Robin)
   ✅ Health checks activos en /health cada 10 segundos
   ⚡ Rate limiting: 10 req/seg, 100 req/min, 5000 req/hora
   🛡️  Circuit breaker: 3 fallos → backend marcado como unhealthy
   🔄 Auto-recuperación de backends fallidos

🔍 COMANDOS ÚTILES (verificación):
   # Probar acceso vía Kong
   curl http://${aws_instance.kong.public_ip}:8000/despachos/reporte
   
   # Ver estado de backends
   curl http://${aws_instance.kong.public_ip}:8001/upstreams/backend-cluster/health
   
   # Ver servicios configurados
   curl http://${aws_instance.kong.public_ip}:8001/services
   
   # Ver rutas configuradas
   curl http://${aws_instance.kong.public_ip}:8001/routes
   
   # Ver targets y su estado
   curl http://${aws_instance.kong.public_ip}:8001/upstreams/backend-cluster/targets

🐛 DEBUG (si algo falla):
   # Ver logs de Kong
   ssh -i tu-key.pem ubuntu@${aws_instance.kong.public_ip}
   tail -f /var/log/kong.log
   
   # Ver logs de backends
   ssh -i tu-key.pem ubuntu@${aws_instance.dispatch["a"].public_ip}
   tail -f /var/log/backend.log
   tail -f /var/log/django.log

📝 NOTAS:
   - Kong tarda ~3-5 minutos en estar completamente operativo
   - El health check endpoint (/health) está configurado automáticamente
   - Kong balanceará automáticamente las peticiones entre ambos backends
   - Si un backend falla, Kong lo sacará del pool hasta que se recupere
   - Populate solo se ejecuta en backend-a para evitar duplicados

INSTRUCTIONS
}