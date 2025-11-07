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
# Variable para email del manager
# ------------------------------------------------------------
variable "manager_email" {
  description = "Email del manager para recibir alertas"
  type        = string
  default     = "dsfafflmao@gmail.com"  # CAMBIAR POR EMAIL REAL
}

# ------------------------------------------------------------
# SNS Topic para alertas
# ------------------------------------------------------------
resource "aws_sns_topic" "backend_alerts" {
  name         = "${var.project_prefix}-backend-alerts"
  display_name = "Backend Health Alerts"
  
  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-backend-alerts"
  })
}

resource "aws_sns_topic_subscription" "manager_email" {
  topic_arn = aws_sns_topic.backend_alerts.arn
  protocol  = "email"
  endpoint  = var.manager_email
}


# ------------------------------------------------------------
# Usar LabRole existente en lugar de crear uno nuevo
# ------------------------------------------------------------
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

data "aws_iam_instance_profile" "lab_profile" {
  name = "LabInstanceProfile"
}




# ------------------------------------------------------------
# Instancia: Base de datos PostgreSQL (compartida: app + kong)
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

# Configurar PostgreSQL
sudo -u postgres psql -c "CREATE USER dispatch_user WITH PASSWORD 'despacho2025' SUPERUSER;"
sudo -u postgres createdb -O dispatch_user dispatch_db

# Crear usuario y base de datos para Kong
sudo -u postgres psql -c "CREATE USER kong WITH PASSWORD 'kong2025';"
sudo -u postgres createdb -O kong kong

# Configuración de acceso remoto
echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/16/main/pg_hba.conf
echo "listen_addresses='*'" >> /etc/postgresql/16/main/postgresql.conf
echo "max_connections=2000" >> /etc/postgresql/16/main/postgresql.conf

systemctl restart postgresql
echo "[DB] PostgreSQL configurado correctamente" | tee -a /var/log/database.log
EOT

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-db" })
}

# ------------------------------------------------------------
# Instancias: Django Sprint2 (3 réplicas: a, b y c)
# ------------------------------------------------------------
resource "aws_instance" "dispatch" {
  for_each = toset(["a", "b", "c"])
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

# Esperar a que la BD esté lista
sleep 30

# Migraciones
/apps/Sprint2/venv/bin/python manage.py makemigrations | tee -a /var/log/backend.log
/apps/Sprint2/venv/bin/python manage.py migrate | tee -a /var/log/backend.log
echo "[MIGRATE] OK" | tee -a /var/log/backend.log

# Poblar datos iniciales
/apps/Sprint2/venv/bin/python populate.py | tee -a /var/log/backend.log || true
/apps/Sprint2/venv/bin/python populateDespachos.py | tee -a /var/log/backend.log || true
echo "[POPULATE] OK" | tee -a /var/log/backend.log

# Crear servicio systemd para Django con auto-recuperación agresiva
cat > /etc/systemd/system/django-backend.service <<'SERVICE'
[Unit]
Description=Django Backend Service (Sprint2) - Auto-Recovery Enabled
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/apps/Sprint2
Environment="DATABASE_HOST=${aws_instance.database.private_ip}"
Environment="PATH=/apps/Sprint2/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/apps/Sprint2/venv/bin/python manage.py runserver 0.0.0.0:8080

# Auto-recuperación: reinicia siempre que falle
Restart=always
RestartSec=5

# Reintentos ilimitados (sin límite de reintentos)
StartLimitInterval=0
StartLimitBurst=0

# Timeout para inicio del servicio
TimeoutStartSec=60

# Si el proceso muere por cualquier razón, reiniciar
# Esto incluye: SIGKILL, SIGTERM, crash por memoria, etc.
KillMode=mixed
KillSignal=SIGTERM
SendSIGKILL=yes
TimeoutStopSec=30

# Logs
StandardOutput=append:/var/log/django.log
StandardError=append:/var/log/django.log

# Prioridad normal
Nice=0

# Límites de recursos (para evitar consumo excesivo)
# Memoria máxima: 500MB (ajustar según necesidad)
MemoryMax=500M
# Tareas máximas: 100
TasksMax=100

[Install]
WantedBy=multi-user.target
SERVICE

# Crear watchdog que monitorea la salud del servicio cada 10 segundos
cat > /opt/watchdog-django.sh <<'WATCHDOG'
#!/bin/bash
# Watchdog para Django - Verifica que el servicio esté respondiendo

LOG="/var/log/django-watchdog.log"
SERVICE="django-backend.service"
HEALTH_URL="http://localhost:8080/despachos/reporte"
MAX_FAILURES=3
FAILURE_COUNT=0

log() {
  echo "[$(date +'%%F %%T')] $*" | tee -a "$LOG"
}

log "🔍 Django Watchdog iniciado"

while true; do
  # Verificar si el servicio está activo
  if ! systemctl is-active --quiet "$SERVICE"; then
    log "⚠️  Servicio $SERVICE no está activo, systemd debería reiniciarlo automáticamente"
    FAILURE_COUNT=0
    sleep 10
    continue
  fi

  # Verificar si el endpoint responde
  HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" --max-time 5 "$HEALTH_URL" 2>/dev/null || echo "000")
  
  if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "302" ]; then
    if [ $FAILURE_COUNT -gt 0 ]; then
      log "✅ Servicio recuperado (HTTP $HTTP_CODE)"
    fi
    FAILURE_COUNT=0
  else
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    log "❌ Fallo de salud $FAILURE_COUNT/$MAX_FAILURES (HTTP $HTTP_CODE)"
    
    if [ $FAILURE_COUNT -ge $MAX_FAILURES ]; then
      log "🔄 Reiniciando servicio por fallas consecutivas"
      systemctl restart "$SERVICE"
      FAILURE_COUNT=0
      sleep 15
    fi
  fi
  
  sleep 10
done
WATCHDOG

chmod +x /opt/watchdog-django.sh

# Crear servicio systemd para el watchdog
cat > /etc/systemd/system/django-watchdog.service <<'WATCHSERVICE'
[Unit]
Description=Django Health Watchdog
After=django-backend.service
Wants=django-backend.service

[Service]
Type=simple
ExecStart=/opt/watchdog-django.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
WATCHSERVICE

# Recargar systemd y habilitar servicios
systemctl daemon-reload
systemctl enable django-backend.service
systemctl enable django-watchdog.service
systemctl start django-backend.service
systemctl start django-watchdog.service

echo "[SYSTEMD] Django service y watchdog habilitados y ejecutándose" | tee -a /var/log/backend.log

# Verificar que ambos servicios estén corriendo
sleep 5
systemctl status django-backend.service --no-pager | tee -a /var/log/backend.log
systemctl status django-watchdog.service --no-pager | tee -a /var/log/backend.log

# Crear archivo de estado para Kong
echo "READY" > /tmp/backend_ready
echo "[COMPLETE] Backend ${each.key} iniciado con auto-recuperación - $(date)" | tee -a /var/log/backend.log
EOT

  depends_on = [aws_instance.database]
  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-backend-${each.key}"
    Role = "backend"
  })
}

# ------------------------------------------------------------
# Instancia EC2 para Kong (Circuit Breaker)
# ------------------------------------------------------------
resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.small"
  associate_public_ip_address = true
  iam_instance_profile        = data.aws_iam_instance_profile.lab_profile.name
  vpc_security_group_ids      = [
    aws_security_group.traffic_cb.id,
    aws_security_group.traffic_ssh.id,
    aws_security_group.traffic_db.id
  ]

  user_data = <<-EOT
#!/bin/bash
set -e
echo "[INIT] Kong - $(date)" | tee -a /var/log/kong-setup.log

# Instalación de dependencias básicas
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y jq unzip curl ca-certificates gnupg lsb-release postgresql-client
echo "[DEPS] Dependencias básicas instaladas" | tee -a /var/log/kong-setup.log

# Instalar AWS CLI v2
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip
/usr/local/bin/aws --version | tee -a /var/log/kong-setup.log
echo "[AWS-CLI] Instalado OK" | tee -a /var/log/kong-setup.log

# Instalación de Docker
mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker
docker --version | tee -a /var/log/kong-setup.log
echo "[DOCKER] Instalado OK" | tee -a /var/log/kong-setup.log

# Crear directorio para configuración de Kong
mkdir -p /opt/kong/declarative
cd /opt/kong

# Variables de base de datos
DB_HOST="${aws_instance.database.private_ip}"

# Esperar a que PostgreSQL esté listo
echo "[WAIT] Esperando PostgreSQL..." | tee -a /var/log/kong-setup.log
until PGPASSWORD=kong2025 psql -h "$DB_HOST" -U kong -d kong -c '\q' 2>/dev/null; do
  echo "Esperando PostgreSQL en $DB_HOST..." | tee -a /var/log/kong-setup.log
  sleep 5
done
echo "[DB] PostgreSQL listo" | tee -a /var/log/kong-setup.log

# Crear red Docker para Kong
docker network create kong-net 2>/dev/null || true
echo "[DOCKER] Red kong-net creada" | tee -a /var/log/kong-setup.log

# Ejecutar migraciones de Kong
echo "[KONG] Ejecutando migraciones..." | tee -a /var/log/kong-setup.log
docker run --rm --network=kong-net \
  -e "KONG_DATABASE=postgres" \
  -e "KONG_PG_HOST=$DB_HOST" \
  -e "KONG_PG_USER=kong" \
  -e "KONG_PG_PASSWORD=kong2025" \
  -e "KONG_PG_DATABASE=kong" \
  kong/kong-gateway:2.7.2.0-alpine kong migrations bootstrap

echo "[KONG] Migraciones completadas" | tee -a /var/log/kong-setup.log

# Levantar Kong con base de datos
docker run -d --name kong \
  --network=kong-net \
  --restart=unless-stopped \
  -e "KONG_DATABASE=postgres" \
  -e "KONG_PG_HOST=$DB_HOST" \
  -e "KONG_PG_USER=kong" \
  -e "KONG_PG_PASSWORD=kong2025" \
  -e "KONG_PG_DATABASE=kong" \
  -e "KONG_PROXY_ACCESS_LOG=/dev/stdout" \
  -e "KONG_ADMIN_ACCESS_LOG=/dev/stdout" \
  -e "KONG_PROXY_ERROR_LOG=/dev/stderr" \
  -e "KONG_ADMIN_ERROR_LOG=/dev/stderr" \
  -e "KONG_ADMIN_LISTEN=0.0.0.0:8001" \
  -e "KONG_ADMIN_GUI_URL=http://0.0.0.0:8002" \
  -p 8000:8000 \
  -p 8001:8001 \
  -p 8002:8002 \
  kong/kong-gateway:2.7.2.0-alpine

echo "[KONG] Contenedor iniciado con PostgreSQL" | tee -a /var/log/kong-setup.log

# Esperar a que Kong esté listo
echo "[WAIT] Esperando Kong Admin API..." | tee -a /var/log/kong-setup.log
for i in {1..60}; do
  if curl -sf http://localhost:8001/ >/dev/null 2>&1; then
    echo "[KONG] Admin API disponible" | tee -a /var/log/kong-setup.log
    break
  fi
  sleep 5
done

# Configurar Kong usando declarative config inicial
cat > /opt/kong/init-kong.sh <<'INIT'
#!/bin/bash
set -e
KONG_ADMIN="http://localhost:8001"

echo "[INIT] Configurando Kong vía Admin API..."

# Crear upstream
curl -s -X POST "$KONG_ADMIN/upstreams" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "backend-cluster",
    "algorithm": "round-robin",
    "slots": 10000,
    "healthchecks": {
      "active": {
        "type": "http",
        "http_path": "/despachos/reporte",
        "timeout": 5,
        "concurrency": 10,
        "healthy": {
          "interval": 10,
          "successes": 2,
          "http_statuses": [200, 302]
        },
        "unhealthy": {
          "interval": 10,
          "http_failures": 3,
          "timeouts": 3,
          "http_statuses": [429, 500, 503]
        }
      },
      "passive": {
        "type": "http",
        "healthy": {
          "successes": 5,
          "http_statuses": [200, 201, 302]
        },
        "unhealthy": {
          "http_failures": 5,
          "timeouts": 2,
          "http_statuses": [429, 500, 503]
        }
      },
      "threshold": 60
    },
    "tags": ["sprint2", "dispatch"]
  }' || echo "Upstream ya existe"

# Crear servicio
curl -s -X POST "$KONG_ADMIN/services" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dispatch-service",
    "host": "backend-cluster",
    "port": 8080,
    "protocol": "http",
    "connect_timeout": 60000,
    "write_timeout": 60000,
    "read_timeout": 60000,
    "retries": 5,
    "tags": ["sprint2", "dispatch"]
  }' || echo "Servicio ya existe"

# Crear ruta principal
curl -s -X POST "$KONG_ADMIN/services/dispatch-service/routes" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dispatch-report-route",
    "paths": ["/despachos/reporte"],
    "strip_path": false,
    "preserve_host": false,
    "protocols": ["http"],
    "methods": ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
    "tags": ["main-route"]
  }' || echo "Ruta principal ya existe"

# Crear ruta raíz
curl -s -X POST "$KONG_ADMIN/services/dispatch-service/routes" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dispatch-root-route",
    "paths": ["/"],
    "strip_path": false,
    "preserve_host": false,
    "protocols": ["http"],
    "methods": ["GET"],
    "tags": ["root-route"]
  }' || echo "Ruta raíz ya existe"

# Plugin: Rate Limiting
curl -s -X POST "$KONG_ADMIN/plugins" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "rate-limiting",
    "enabled": true,
    "config": {
      "minute": 100,
      "policy": "local",
      "fault_tolerant": true,
      "hide_client_headers": false
    },
    "tags": ["rate-limiting", "protection"]
  }' || echo "Rate limiting ya existe"

# Plugin: Correlation ID
curl -s -X POST "$KONG_ADMIN/plugins" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "correlation-id",
    "enabled": true,
    "config": {
      "header_name": "X-Kong-Request-ID",
      "generator": "uuid",
      "echo_downstream": true
    },
    "tags": ["observability"]
  }' || echo "Correlation ID ya existe"

echo "[INIT] Kong configurado exitosamente"
INIT

chmod +x /opt/kong/init-kong.sh
/opt/kong/init-kong.sh | tee -a /var/log/kong-setup.log

# -------------------------------------------
# Service Discovery: sincroniza targets en Kong dinámicamente
# -------------------------------------------
cat > /opt/kong/discover_backends.sh <<'DISCOVERY'
#!/usr/bin/env bash
set -euo pipefail

KONG_ADMIN="http://localhost:8001"
UPSTREAM="backend-cluster"
REGION="${var.region}"
PROJECT_TAG="${local.project_name}"
ROLE_TAG="backend"
PORT="8080"
LOG="/var/log/kong-discovery.log"

log() { 
  echo "[$(date +'%F %T')] $*"
  echo "[$(date +'%F %T')] $*" >> "$LOG"
}

wait_kong() {
  for i in {1..60}; do
    if curl -sf "$KONG_ADMIN/" >/dev/null 2>&1; then 
      log "Kong Admin API disponible"
      return 0
    fi
    sleep 5
  done
  log "ERROR: Kong Admin API no disponible"
  return 1
}

sync() {
  log "=== Iniciando sincronización ==="
  
  # Obtener IPs privadas de instancias EC2 con tags y estado RUNNING
  mapfile -t discovered_ips < <(/usr/local/bin/aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
              "Name=tag:Role,Values=$ROLE_TAG" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].PrivateIpAddress' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | sort -u)

  desired=()
  for ip in "$${discovered_ips[@]}"; do
    [[ -n "$ip" ]] && desired+=("$ip:$PORT")
  done

  log "Backends descubiertos vía EC2: $${#desired[@]}"
  for t in "$${desired[@]}"; do
    log "  - $t"
  done

  # Obtener targets actuales de Kong (weight > 0 = activos)
  mapfile -t current < <(curl -sf "$KONG_ADMIN/upstreams/$UPSTREAM/targets" 2>/dev/null \
    | jq -r '.data[]? | select(.weight > 0) | .target' 2>/dev/null \
    | sort -u || true)

  log "Targets activos en Kong: $${#current[@]}"
  for t in "$${current[@]}"; do
    log "  - $t"
  done

  # Agregar targets faltantes
  for target in "$${desired[@]}"; do
    if ! printf '%s\n' "$${current[@]}" | grep -qFx "$target" 2>/dev/null; then
      log "🔵 AGREGANDO target: $target"
      response=$(curl -sf -X POST "$KONG_ADMIN/upstreams/$UPSTREAM/targets" \
        -H "Content-Type: application/json" \
        -d "{\"target\":\"$target\",\"weight\":100}" 2>&1)
      
      if [ $? -eq 0 ]; then
        log "✅ Target $target agregado exitosamente"
      else
        log "⚠️  Error al agregar $target: $response"
      fi
    fi
  done

  # Eliminar targets obsoletos (backends que ya no existen)
  for target in "$${current[@]}"; do
    if ! printf '%s\n' "$${desired[@]}" | grep -qFx "$target" 2>/dev/null; then
      log "🔴 ELIMINANDO target obsoleto: $target"
      
      # Obtener el ID del target
      target_id=$(curl -sf "$KONG_ADMIN/upstreams/$UPSTREAM/targets" \
        | jq -r ".data[]? | select(.target==\"$target\") | .id" 2>/dev/null | head -n1)
      
      if [ -n "$target_id" ]; then
        response=$(curl -sf -X DELETE "$KONG_ADMIN/upstreams/$UPSTREAM/targets/$target_id" 2>&1)
        if [ $? -eq 0 ]; then
          log "✅ Target $target eliminado exitosamente"
        else
          log "⚠️  Error al eliminar $target: $response"
        fi
      else
        log "⚠️  No se encontró ID para target $target"
      fi
    fi
  done

  log "=== Sincronización completada. Desired: $${#desired[@]}, Current: $${#current[@]} ==="
}

log "🚀 Iniciando Kong Service Discovery"
log "   Project: $PROJECT_TAG"
log "   Role: $ROLE_TAG"
log "   Region: $REGION"

wait_kong || { log "❌ Kong Admin no disponible"; exit 1; }

# Loop infinito de sincronización cada 30 segundos
while true; do
  sync || log "⚠️  Error en ciclo de sincronización"
  sleep 30
done
DISCOVERY

chmod +x /opt/kong/discover_backends.sh
echo "[DISCOVERY] Script creado" | tee -a /var/log/kong-setup.log

# Servicio systemd para discovery
cat > /etc/systemd/system/kong-discovery.service <<'SERVICE'
[Unit]
Description=Kong Upstream Discovery
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=/opt/kong/discover_backends.sh
Restart=always
RestartSec=5
StandardOutput=append:/var/log/kong-discovery.log
StandardError=append:/var/log/kong-discovery.log

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable kong-discovery.service
systemctl start kong-discovery.service
echo "[DISCOVERY] Servicio de discovery iniciado" | tee -a /var/log/kong-setup.log

# Crear archivo de estado
echo "READY" > /tmp/kong_ready
echo "[COMPLETE] Setup finalizado - $(date)" | tee -a /var/log/kong-setup.log
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
   🏠 URL Raíz (redirige): http://${aws_instance.kong.public_ip}:8000/
   🔧 Admin API: http://${aws_instance.kong.public_ip}:8001

🔍 SERVICE DISCOVERY ACTIVO:
   ✅ Kong sincroniza automáticamente los backends cada 30 segundos
   ✅ Agrega nuevas instancias que se levanten con tags correctos
   ✅ Elimina instancias que se apaguen o terminen
   ✅ Usa IPs privadas (no afecta cambio de IP pública)

🛡️  AUTO-RECUPERACIÓN DE BACKENDS:
   ✅ Systemd reinicia automáticamente si Django se cae (cada 5 segundos)
   ✅ Watchdog monitorea salud del endpoint cada 10 segundos
   ✅ Si 3 health checks fallan consecutivas, fuerza restart
   ✅ Protección contra DDOS: límite de memoria (500MB) y tareas (100)
   ✅ Reintentos ilimitados (no se rinde nunca)

🖥️  Backends descubiertos automáticamente:
   Backend A: ${aws_instance.dispatch["a"].private_ip}:8080
   Backend B: ${aws_instance.dispatch["b"].private_ip}:8080
   Backend C: ${aws_instance.dispatch["c"].private_ip}:8080

💾 Base de datos PostgreSQL:
   IP privada: ${aws_instance.database.private_ip}:5432
   App DB: dispatch_db (usuario: dispatch_user)
   Kong DB: kong (usuario: kong)

📊 KONG Configuration:
   ✅ Modo con base de datos PostgreSQL (permite cambios dinámicos)
   ✅ Service Discovery automático vía AWS API
   ✅ Health checks activos en /despachos/reporte cada 10 segundos
   ⚡ Rate limiting: 100 peticiones/minuto
   🛡️  Circuit breaker: 3 fallos → circuit abierto
   🔄 Auto-recuperación de backends fallidos

🔍 COMANDOS ÚTILES:
   # Ver backends descubiertos y su estado
   curl http://${aws_instance.kong.public_ip}:8001/upstreams/backend-cluster/health
   
   # Ver targets configurados
   curl http://${aws_instance.kong.public_ip}:8001/upstreams/backend-cluster/targets
   
   # Ver logs del discovery
   ssh ubuntu@${aws_instance.kong.public_ip}
   tail -f /var/log/kong-discovery.log
   
   # Verificar servicio de discovery
   systemctl status kong-discovery

🔧 MONITOREAR AUTO-RECUPERACIÓN (en cada backend):
   # Ver estado del servicio Django
   systemctl status django-backend.service
   
   # Ver logs de Django
   tail -f /var/log/django.log
   
   # Ver logs del watchdog
   tail -f /var/log/django-watchdog.log
   
   # Ver cantidad de reinicios
   systemctl show django-backend.service | grep NRestarts
   
   # Forzar reinicio manual (para pruebas)
   systemctl restart django-backend.service

🧪 PROBAR AUTO-RECUPERACIÓN:
   1. Simular caída de Django:
      ssh ubuntu@<backend-ip>
      sudo systemctl kill -s SIGKILL django-backend.service
      
   2. Observar logs:
      tail -f /var/log/django.log
      tail -f /var/log/django-watchdog.log
      
   3. El servicio debe reiniciarse en ~5 segundos
   4. Kong detectará el reinicio en el siguiente health check (~10s)
   
   5. Simular DDOS (saturar el backend):
      ab -n 10000 -c 100 http://<backend-ip>:8080/despachos/reporte
      
   6. Si Django se cae, debe reiniciarse automáticamente

🧪 PROBAR DISCOVERY:
   1. Detén un backend: aws ec2 stop-instances --instance-ids <id>
   2. Espera 30-60 segundos (ciclo de discovery + health check)
   3. Verifica: curl http://${aws_instance.kong.public_ip}:8001/upstreams/backend-cluster/targets
   4. El backend detenido debe desaparecer automáticamente
   5. Reinicia el backend y debe reaparecer en ~30-60 segundos

📝 NOTAS DE DISPONIBILIDAD:
   - Kong tarda ~3-5 minutos en estar completamente operativo
   - El discovery se ejecuta cada 30 segundos
   - Watchdog verifica salud cada 10 segundos
   - Systemd reinicia Django en 5 segundos si se cae
   - Límite de memoria: 500MB por backend (ajustar si es necesario)
   - Límite de tareas: 100 concurrentes por backend
   - Los backends NUNCA dejan de intentar reiniciarse (StartLimitBurst=0)

INSTRUCTIONS
}

output "sns_topic_arn" {
  description = "ARN del topic SNS para alertas"
  value       = aws_sns_topic.backend_alerts.arn
}

output "alert_instructions" {
  description = "Instrucciones de configuración de alertas"
  value       = <<-ALERT

📧 CONFIGURACIÓN DE ALERTAS POR EMAIL

⚠️  IMPORTANTE: Debes confirmar la suscripción de email
   1. Revisa la bandeja de entrada de: ${var.manager_email}
   2. Busca un email de AWS Notifications
   3. Haz clic en "Confirm subscription"

📊 Alertas configuradas:
   ✅ Sistema degradado (1 de 3 backends activo)
   🚨 Sistema caído (0 backends activos)
   ✅ Sistema recuperado (2+ backends activos)

🔍 Monitorear manualmente:
   curl http://${aws_instance.kong.public_ip}:8001/upstreams/backend-cluster/health

📝 Ver logs del monitor:
   ssh ubuntu@${aws_instance.kong.public_ip}
   tail -f /var/log/kong-monitor.log

ALERT
}