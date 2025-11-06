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

# Configurar PostgreSQL
sudo -u postgres psql -c "CREATE USER dispatch_user WITH PASSWORD 'despacho2025' SUPERUSER;"
sudo -u postgres createdb -O dispatch_user dispatch_db

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
# Instancias: Django Sprint2 (2 réplicas: a, b y c)
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
# Instancia EC2 para Kong (Circuit Breaker)
# ------------------------------------------------------------
resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.small"
  associate_public_ip_address = true
  iam_instance_profile        = data.aws_iam_instance_profile.lab_profile.name
  vpc_security_group_ids      = [
    aws_security_group.traffic_cb.id, 
    aws_security_group.traffic_ssh.id
  ]

  user_data = <<-EOT
#!/bin/bash
set -e
echo "[INIT] Kong - $(date)" | tee -a /var/log/kong-setup.log

# Instalación de dependencias básicas
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y jq unzip curl ca-certificates gnupg lsb-release
echo "[DEPS] Dependencias básicas instaladas" | tee -a /var/log/kong-setup.log

# Instalar AWS CLI v2 (método oficial para Ubuntu 24.04)
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

# Crear configuración declarativa de Kong
cat > /opt/kong/declarative/kong.yml <<'KONGCONFIG'
_format_version: "2.1"

# ============================================================
# UPSTREAMS (Pool de backends con health checks)
# ============================================================
upstreams:
  - name: backend-cluster
    algorithm: round-robin
    slots: 10000
    healthchecks:
      active:
        type: http
        http_path: /despachos/reporte
        timeout: 5
        concurrency: 10
        healthy:
          interval: 10
          successes: 2
          http_statuses:
            - 200
            - 302
        unhealthy:
          interval: 10
          http_failures: 3
          timeouts: 3
          http_statuses:
            - 429
            - 500
            - 503
      passive:
        type: http
        healthy:
          successes: 5
          http_statuses:
            - 200
            - 201
            - 302
        unhealthy:
          http_failures: 5
          timeouts: 2
          http_statuses:
            - 429
            - 500
            - 503
      threshold: 33
    tags:
      - sprint2
      - dispatch

# ============================================================
# TARGETS (Backends específicos)
# ============================================================
targets:
  - target: "${aws_instance.dispatch["a"].private_ip}:8080"
    upstream: backend-cluster
    weight: 100
    tags:
      - backend-a

  - target: "${aws_instance.dispatch["b"].private_ip}:8080"
    upstream: backend-cluster
    weight: 100
    tags:
      - backend-b
    
  - target: "${aws_instance.dispatch["c"].private_ip}:8080"
    upstream: backend-cluster
    weight: 100
    tags:
      - backend-c

# ============================================================
# SERVICES
# ============================================================
services:
  - name: dispatch-service
    host: backend-cluster
    port: 8080
    protocol: http
    connect_timeout: 60000
    write_timeout: 60000
    read_timeout: 60000
    retries: 5
    tags:
      - sprint2
      - dispatch

    routes:
      - name: dispatch-report-route
        paths:
          - /despachos/reporte
        strip_path: false
        preserve_host: false
        protocols:
          - http
        methods:
          - GET
          - POST
          - PUT
          - DELETE
          - PATCH
          - OPTIONS
        tags:
          - main-route

      - name: dispatch-root-route
        paths:
          - /
        strip_path: false
        preserve_host: false
        protocols:
          - http
        methods:
          - GET
        tags:
          - root-route

# ============================================================
# PLUGINS GLOBALES
# ============================================================
plugins:
  - name: rate-limiting
    enabled: true
    config:
      minute: 100
      policy: local
      fault_tolerant: true
      hide_client_headers: false
    tags:
      - rate-limiting
      - protection

  - name: request-termination
    service: dispatch-service
    enabled: false
    config:
      status_code: 503
      message: "Service Degraded: Limited capacity available"
    tags:
      - degradation

  - name: correlation-id
    enabled: true
    config:
      header_name: X-Kong-Request-ID
      generator: uuid
      echo_downstream: true
    tags:
      - observability
KONGCONFIG

echo "[CONFIG] Kong YML creado" | tee -a /var/log/kong-setup.log

# Script de monitoreo de degradación
cat > /opt/kong/monitor_health.sh <<'MONITOR'
#!/bin/bash
# Script de monitoreo de health de backends

KONG_ADMIN="http://localhost:8001"
SNS_TOPIC_ARN="${aws_sns_topic.backend_alerts.arn}"
ALERT_SENT_FILE="/tmp/degradation_alert_sent"

# Obtener la IP pública de esta instancia
KONG_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

while true; do
  # Obtener estado de targets
  HEALTH_JSON=$(curl -s "$KONG_ADMIN/upstreams/backend-cluster/health")
  
  TOTAL=$(echo "$HEALTH_JSON" | jq '.data | length')
  HEALTHY=$(echo "$HEALTH_JSON" | jq '[.data[] | select(.health == "HEALTHY")] | length')
  
  echo "[$(date)] Total: $TOTAL, Healthy: $HEALTHY" >> /var/log/kong-monitor.log
  
  # Lógica de degradación
  if [ "$HEALTHY" -eq 1 ] && [ "$TOTAL" -eq 3 ]; then
    echo "[DEGRADED] Solo 1 backend activo de 3" >> /var/log/kong-monitor.log
    
    if [ ! -f "$ALERT_SENT_FILE" ]; then
      /usr/local/bin/aws sns publish \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "⚠️ ALERTA: Sistema en Modo Degradado" \
        --message "ALERTA CRÍTICA: Solo 1 de 3 backends está operativo.

Backends activos: $HEALTHY/$TOTAL
Timestamp: $(date)
IP Kong: $KONG_PUBLIC_IP

El sistema continúa operando pero con capacidad limitada.
Se recomienda revisar los backends caídos inmediatamente.

Backends:
- Backend A: ${aws_instance.dispatch["a"].private_ip}
- Backend B: ${aws_instance.dispatch["b"].private_ip}
- Backend C: ${aws_instance.dispatch["c"].private_ip}

Para verificar estado:
curl http://$KONG_PUBLIC_IP:8001/upstreams/backend-cluster/health" \
        --region ${var.region}
      
      touch "$ALERT_SENT_FILE"
      echo "[ALERT] Notificación enviada" >> /var/log/kong-monitor.log
    fi
    
  elif [ "$HEALTHY" -eq 0 ]; then
    echo "[CRITICAL] Todos los backends caídos" >> /var/log/kong-monitor.log
    
    /usr/local/bin/aws sns publish \
      --topic-arn "$SNS_TOPIC_ARN" \
      --subject "🚨 CRÍTICO: Sistema Completamente Caído" \
      --message "ALERTA CRÍTICA: Todos los backends están caídos.

Backends activos: 0/$TOTAL
Timestamp: $(date)
IP Kong: $KONG_PUBLIC_IP

El sistema NO está operativo. Se requiere intervención inmediata.

Backends:
- Backend A: ${aws_instance.dispatch["a"].private_ip}
- Backend B: ${aws_instance.dispatch["b"].private_ip}
- Backend C: ${aws_instance.dispatch["c"].private_ip}

Acciones recomendadas:
1. Verificar logs de backends
2. Reiniciar servicios Django
3. Verificar conectividad de red" \
      --region ${var.region}
      
  else
    if [ -f "$ALERT_SENT_FILE" ]; then
      rm -f "$ALERT_SENT_FILE"
      
      /usr/local/bin/aws sns publish \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "✅ RECUPERACIÓN: Sistema Operativo Normal" \
        --message "El sistema ha vuelto a la normalidad.

Backends activos: $HEALTHY/$TOTAL
Timestamp: $(date)
IP Kong: $KONG_PUBLIC_IP

Todos los backends están operativos nuevamente." \
        --region ${var.region}
      
      echo "[RECOVERY] Sistema recuperado, notificación enviada" >> /var/log/kong-monitor.log
    fi
  fi
  
  sleep 30
done
MONITOR

chmod +x /opt/kong/monitor_health.sh
echo "[MONITOR] Script de monitoreo creado" | tee -a /var/log/kong-setup.log

# Crear servicio systemd para el monitor
cat > /etc/systemd/system/kong-monitor.service <<'SERVICE'
[Unit]
Description=Kong Backend Health Monitor
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/opt/kong/monitor_health.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable kong-monitor.service
systemctl start kong-monitor.service
echo "[MONITOR] Health monitor iniciado" | tee -a /var/log/kong-setup.log

# Crear red Docker para Kong
docker network create kong-net 2>/dev/null || true
echo "[DOCKER] Red kong-net creada" | tee -a /var/log/kong-setup.log

# Esperar a que los backends estén listos
echo "[WAIT] Esperando backends..." | tee -a /var/log/kong-setup.log
sleep 60

# Levantar Kong
docker run -d --name kong \
  --network=kong-net \
  --restart=unless-stopped \
  -v /opt/kong/declarative:/kong/declarative/ \
  -e "KONG_DATABASE=off" \
  -e "KONG_DECLARATIVE_CONFIG=/kong/declarative/kong.yml" \
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

echo "[KONG] Contenedor iniciado" | tee -a /var/log/kong-setup.log

# Verificar que Kong esté corriendo
sleep 15
if docker ps | grep -q kong; then
  echo "[SUCCESS] Kong está corriendo" | tee -a /var/log/kong-setup.log
  docker ps | tee -a /var/log/kong-setup.log
else
  echo "[ERROR] Kong no está corriendo" | tee -a /var/log/kong-setup.log
  docker logs kong | tee -a /var/log/kong-setup.log
fi

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

🖥️  Backends directos (solo para pruebas/debugging):
   Backend A: http://${aws_instance.dispatch["a"].public_ip}:8080/despachos/reporte
   Backend B: http://${aws_instance.dispatch["b"].public_ip}:8080/despachos/reporte
   Backend C: http://${aws_instance.dispatch["c"].public_ip}:8080/despachos/reporte  

💾 Base de datos PostgreSQL:
   IP privada: ${aws_instance.database.private_ip}:5432
   Usuario: dispatch_user
   Base de datos: dispatch_db

📊 KONG Configuration:
   ✅ Balanceo de carga entre 2 backends (Round Robin)
   ✅ Health checks activos en /despachos/reporte cada 10 segundos
   ⚡ Rate limiting: 100 peticiones/minuto
   🛡️  Circuit breaker: 3 fallos → circuit abierto
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
   tail -f /usr/local/kong/logs/error.log
   
   # Verificar estado de Kong
   kong health

📝 NOTAS:
   - Kong tarda ~3-5 minutos en estar completamente operativo
   - Los backends deben responder en /despachos/reporte para que el health check funcione
   - Kong balanceará automáticamente las peticiones entre ambos backends
   - Si un backend falla, Kong lo sacará del pool hasta que se recupere

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

INSTRUCTIONS
}