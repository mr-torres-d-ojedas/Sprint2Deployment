# Sprint2Deployment

## 1. Descripción general
Este módulo de Terraform despliega una infraestructura completa y resiliente para la plataforma de despachos (Sprint 2) en AWS. Implementa:

- **Base de datos PostgreSQL** compartida para aplicación y Kong
- **Tres réplicas del backend Django** con auto-recuperación automática
- **Kong API Gateway** como circuit breaker y load balancer inteligente
- **Service Discovery automático** que sincroniza backends dinámicamente
- **Sistema de monitoreo y alertas** vía CloudWatch y SNS
- **Auto-recuperación multi-nivel** (systemd + watchdog + health checks)

La arquitectura garantiza alta disponibilidad, tolerancia a fallos y escalabilidad horizontal.

## 2. Requisitos previos
- **Terraform** ≥ 1.5 instalado y disponible en el `PATH`
- **AWS CLI v2** configurado con credenciales válidas
- **IAM Role** `LabRole` y `LabInstanceProfile` disponibles (AWS Academy)
- **Permisos IAM** para:
  - EC2 (create, describe, terminate instances)
  - VPC y Security Groups (create, modify, delete)
  - SNS (create topics, subscriptions)
  - IAM (read roles y instance profiles)
- **Conectividad a internet** para descargar AMIs, Docker, Kong y dependencias
- **Email válido** para recibir alertas (configurable en `terraform.tfvars`)

## 3. Variables principales
| Variable         | Descripción                                  | Valor por defecto     |
|------------------|----------------------------------------------|-----------------------|
| `region`         | Región AWS donde desplegar                   | `us-east-1`           |
| `project_prefix` | Prefijo estándar para nombrar recursos       | `des`                 |
| `instance_type`  | Tipo de instancia EC2 para DB y backends     | `t2.nano`             |
| `manager_email`  | Email para recibir alertas del sistema      | `dsfafflmao@gmail.com` |

**Personalización**: Cree un archivo `terraform.tfvars`:
```hcl
region         = "us-west-2"
instance_type  = "t2.small"
manager_email  = "tu-email@ejemplo.com"
```

## 4. Arquitectura y componentes desplegados

### 4.1. Base de datos PostgreSQL (`des-db`)
**Instancia**: Ubuntu 24.04 LTS con PostgreSQL 16

**Configuración**:
- **Puerto**: 5432 (accesible desde cualquier IP - ajustar en producción)
- **Bases de datos**:
  - `dispatch_db`: Para aplicación Django (usuario: `dispatch_user`, password: `despacho2025`)
  - `kong`: Para Kong Gateway (usuario: `kong`, password: `kong2025`)
- **Parámetros optimizados**:
  - `max_connections=2000`: Soporta alta concurrencia
  - `listen_addresses='*'`: Acceso remoto habilitado
  - Autenticación MD5 para conexiones remotas

**Scripts automáticos**:
1. Instalación de PostgreSQL 16
2. Creación de usuarios y bases de datos
3. Configuración de acceso remoto (`pg_hba.conf`)
4. Reinicio del servicio

### 4.2. Backends Django (3 réplicas: `des-backend-a`, `des-backend-b`, `des-backend-c`)
**Instancia**: Ubuntu 24.04 LTS, Python 3.12

**Proceso de inicialización automática**:
1. **Configuración de entorno**:
   - Establece `DATABASE_HOST` con IP privada de PostgreSQL
   - Instala dependencias del sistema: Python, pip, venv, git, build-essential, libpq-dev

2. **Despliegue de aplicación**:
   - Clona repositorio: `https://github.com/mr-torres-d-ojedas/Sprint2.git`
   - Crea entorno virtual Python en `/apps/Sprint2/venv`
   - Instala dependencias: `requirements.txt` + `psycopg2-binary`

3. **Configuración de base de datos**:
   - Espera 30 segundos a que PostgreSQL esté disponible
   - Ejecuta `makemigrations` y `migrate`
   - Ejecuta scripts de población: `populate.py` y `populateDespachos.py`

4. **Servicio Django** (puerto 8080):
   - **Systemd service**: `django-backend.service`
   - **Comando**: `python manage.py runserver 0.0.0.0:8080`
   - **Auto-recuperación agresiva**:
     - `Restart=always`: Reinicia siempre que falle
     - `RestartSec=5`: Espera 5 segundos entre reintentos
     - `StartLimitInterval=0` y `StartLimitBurst=0`: Reintentos ilimitados
     - Maneja crashes por SIGKILL, SIGTERM, memoria, etc.
   - **Límites de recursos**:
     - `MemoryMax=500M`: Máximo 500MB de RAM
     - `TasksMax=100`: Máximo 100 tareas concurrentes
   - **Logs**: `/var/log/django.log` (stdout y stderr)

5. **Watchdog de salud** (`django-watchdog.service`):
   - **Frecuencia**: Cada 10 segundos
   - **Endpoint verificado**: `http://localhost:8080/despachos/reporte`
   - **Lógica**:
     - Si recibe HTTP 200 o 302 → OK, resetea contador de fallos
     - Si falla o timeout → Incrementa contador
     - Si 3 fallos consecutivos → Fuerza `systemctl restart`
   - **Logs**: `/var/log/django-watchdog.log`
   - **Auto-recuperación**: El watchdog también se reinicia automáticamente si falla

**Garantías de disponibilidad**:
- Django NUNCA deja de intentar reiniciarse (sin límite de reintentos)
- Systemd reinicia en 5 segundos cualquier crash
- Watchdog detecta endpoints no responsivos en 30 segundos (3 checks × 10s)
- Protección contra saturación de recursos (límites de memoria y tareas)

### 4.3. Kong API Gateway (`des-kong`)
**Instancia**: Ubuntu 24.04 LTS, Docker, Kong Gateway 2.7.2.0-alpine

**Inicialización automática**:
1. **Instalación de componentes**:
   - Docker Engine + Docker Compose
   - AWS CLI v2 (para service discovery)
   - PostgreSQL client (para verificar conectividad)
   - Herramientas: jq, curl, unzip

2. **Configuración de Kong**:
   - **Modo**: Database-backed (PostgreSQL)
   - **Conexión DB**: `kong` database en instancia PostgreSQL
   - **Puertos expuestos**:
     - `8000`: Kong Proxy (punto de entrada principal)
     - `8001`: Kong Admin API (configuración)
     - `8002`: Kong Admin GUI
   - **Migraciones**: Se ejecutan automáticamente al iniciar

3. **Configuración declarativa inicial** (`init-kong.sh`):
   - **Upstream**: `backend-cluster`
     - Algoritmo: Round-Robin
     - Slots: 10,000 (alta capacidad)
     - **Health checks activos**:
       - Intervalo: Cada 10 segundos
       - Path: `/despachos/reporte`
       - Umbral saludable: 2 éxitos consecutivos (HTTP 200/302)
       - Umbral no saludable: 3 fallos consecutivos (HTTP 429/500/503 o timeouts)
     - **Health checks pasivos**:
       - Saludable: 5 éxitos (HTTP 200/201/302)
       - No saludable: 5 fallos (HTTP 429/500/503) o 2 timeouts
     - **Threshold**: 60% de backends deben estar activos

   - **Service**: `dispatch-service`
     - Host: `backend-cluster`
     - Port: 8080
     - Timeouts: 60 segundos (connect, write, read)
     - Retries: 5 intentos por request

   - **Routes**:
     - `/despachos/reporte`: Ruta principal (todos los métodos HTTP)
     - `/`: Ruta raíz (GET, redirige a la app)

   - **Plugins**:
     - **Rate Limiting**: 100 requests/minuto por cliente
     - **Correlation ID**: Agrega `X-Kong-Request-ID` para trazabilidad

4. **Service Discovery dinámico** (`kong-discovery.service`):
   - **Script**: `/opt/kong/discover_backends.sh`
   - **Frecuencia**: Cada 30 segundos
   - **Lógica**:
     1. Consulta AWS EC2 API para instancias con:
        - Tag `Project=${local.project_name}`
        - Tag `Role=backend`
        - Estado: `running`
     2. Obtiene IPs privadas de backends descubiertos
     3. Compara con targets actuales en Kong upstream
     4. **Agrega** targets nuevos con peso 100
     5. **Elimina** targets obsoletos (backends terminados/detenidos)
   - **Ventajas**:
     - Auto-scaling: Detecta backends nuevos sin intervención manual
     - Auto-healing: Elimina backends caídos automáticamente
     - Usa IPs privadas (no afectan cambios de IP pública)
   - **Logs**: `/var/log/kong-discovery.log`

**Flujo de una request**:
```
Cliente → Kong:8000 → Rate Limiting → Correlation ID → 
  → Upstream (Round-Robin) → Health Check → Backend disponible:8080 → 
    → Django → PostgreSQL → Respuesta
```

**Circuit Breaker automático**:
- Si un backend falla 3 health checks consecutivos → Kong lo marca como `unhealthy`
- Kong deja de enviar tráfico a ese backend
- Sigue verificando cada 10 segundos
- Cuando el backend responde 2 veces consecutivas → Vuelve al pool activo

### 4.4. Grupos de seguridad
| Security Group         | Puertos permitidos | Descripción                          |
|------------------------|-------------------|--------------------------------------|
| `des-traffic-django`   | 8080/tcp          | Acceso a backends Django             |
| `des-traffic-db`       | 5432/tcp          | Acceso a PostgreSQL                  |
| `des-traffic-ssh`      | 22/tcp            | Acceso SSH a todas las instancias    |
| `des-traffic-cb`       | 8000, 8001, 8002/tcp | Puertos de Kong (proxy, admin, GUI) |

**Nota de seguridad**: Todos permiten `0.0.0.0/0` (demo). En producción, restrinja a rangos específicos.

### 4.5. Sistema de monitoreo y alertas

**SNS Topic**: `des-backend-alerts`
- **Suscripción**: Email configurado en `manager_email`
- **Confirmación requerida**: AWS envía email de confirmación que debe aceptarse

**Alertas configuradas** (futuras - CloudWatch Alarms):
- ⚠️ **Sistema degradado**: Solo 1 de 3 backends activo
- 🚨 **Sistema caído**: 0 backends activos
- ✅ **Sistema recuperado**: 2+ backends activos nuevamente

**Nota**: Las CloudWatch Alarms requieren configuración adicional post-deployment.

## 5. Pasos de despliegue

### 5.1. Preparación
```bash
cd /path/to/Sprint2Deployment

# Crear archivo de variables (opcional)
cat > terraform.tfvars <<EOF
region        = "us-east-1"
instance_type = "t2.small"
manager_email = "tu-email@dominio.com"
EOF
```

### 5.2. Despliegue
```bash
# 1. Inicializar Terraform (descarga providers)
terraform init

# 2. Formatear código (opcional pero recomendado)
terraform fmt

# 3. Validar configuración
terraform validate

# 4. Previsualizar cambios
terraform plan -out=planfile

# 5. Aplicar infraestructura
terraform apply planfile
# O directamente: terraform apply
# Escribir "yes" cuando se solicite confirmación
```

**Tiempo estimado**: 8-12 minutos
- PostgreSQL: ~2 minutos
- Backends Django: ~3-4 minutos cada uno (paralelo)
- Kong: ~3-5 minutos (instalación Docker + migraciones)

### 5.3. Post-deployment
1. **Confirmar suscripción email**:
   - Revisar bandeja de entrada de `manager_email`
   - Buscar "AWS Notifications"
   - Hacer clic en "Confirm subscription"

2. **Esperar propagación DNS** (~2-3 minutos):
   - Kong tarda en completar inicialización
   - Service discovery necesita primer ciclo (30s)

3. **Verificar outputs**:
```bash
terraform output
```

## 6. Validación y pruebas

### 6.1. Verificación básica
```bash
# Obtener URL principal
KONG_URL=$(terraform output -raw kong_proxy_url)

# Probar endpoint principal
curl -v $KONG_URL

# Verificar estado de backends en Kong
ADMIN_URL=$(terraform output -raw kong_admin_url)
curl $ADMIN_URL/upstreams/backend-cluster/health | jq
```

### 6.2. Verificar service discovery
```bash
# Ver targets descubiertos
curl $ADMIN_URL/upstreams/backend-cluster/targets | jq '.data[] | {target, weight, health}'

# Ver logs de discovery (SSH a Kong)
KONG_IP=$(terraform output -raw kong_public_ip)
ssh ubuntu@$KONG_IP -i tu-llave.pem
tail -f /var/log/kong-discovery.log
```

### 6.3. Probar auto-recuperación de backends
```bash
# SSH a un backend
BACKEND_IP=$(terraform output -json backend_public_ips | jq -r '.a')
ssh ubuntu@$BACKEND_IP -i tu-llave.pem

# Ver estado del servicio Django
systemctl status django-backend.service

# Simular crash (matar proceso)
sudo systemctl kill -s SIGKILL django-backend.service

# Observar reinicio automático
tail -f /var/log/django.log
tail -f /var/log/django-watchdog.log

# Verificar cantidad de reinicios
systemctl show django-backend.service | grep NRestarts
```

### 6.4. Probar circuit breaker
```bash
# Detener un backend manualmente
aws ec2 stop-instances --instance-ids i-xxxxxxxxx --region us-east-1

# Esperar ~60 segundos (30s discovery + 30s health checks)

# Verificar que Kong lo eliminó del pool
curl $ADMIN_URL/upstreams/backend-cluster/health | jq

# Reiniciar backend
aws ec2 start-instances --instance-ids i-xxxxxxxxx --region us-east-1

# Verificar que Kong lo reintegra automáticamente (~60-90s)
```

### 6.5. Simular carga (stress test)
```bash
# Instalar Apache Bench
sudo apt-get install apache2-utils

# Generar carga HTTP
ab -n 10000 -c 100 $KONG_URL

# Observar distribución en backends
for ip in $(terraform output -json backend_public_ips | jq -r '.[]'); do
  echo "Backend $ip:"
  ssh ubuntu@$ip "grep -c 'GET /despachos/reporte' /var/log/django.log"
done
```

## 7. Accesos y URLs

### 7.1. Acceso principal (usuarios finales)
```
🌐 Aplicación: http://<kong_public_ip>:8000/despachos/reporte
🏠 Página raíz: http://<kong_public_ip>:8000/
```

### 7.2. Acceso administrativo
```
🔧 Kong Admin API: http://<kong_public_ip>:8001
📊 Kong Admin GUI: http://<kong_public_ip>:8002
```

### 7.3. Acceso directo a backends (debugging)
```
Backend A: http://<backend_a_public_ip>:8080
Backend B: http://<backend_b_public_ip>:8080
Backend C: http://<backend_c_public_ip>:8080
```

### 7.4. Acceso SSH
```bash
# Kong
ssh ubuntu@<kong_public_ip> -i llave.pem

# Backends
ssh ubuntu@<backend_public_ip> -i llave.pem

# Base de datos
ssh ubuntu@<db_public_ip> -i llave.pem
```

## 8. Monitoreo y logs

### 8.1. Logs de Kong
```bash
ssh ubuntu@<kong_public_ip>

# Logs del contenedor Docker
docker logs -f kong

# Logs del service discovery
tail -f /var/log/kong-discovery.log

# Verificar servicio de discovery
systemctl status kong-discovery.service
```

### 8.2. Logs de backends
```bash
ssh ubuntu@<backend_public_ip>

# Logs de Django
tail -f /var/log/django.log

# Logs del watchdog
tail -f /var/log/django-watchdog.log

# Logs de inicialización
tail -f /var/log/backend.log

# Estado del servicio Django
systemctl status django-backend.service

# Estado del watchdog
systemctl status django-watchdog.service
```

### 8.3. Logs de base de datos
```bash
ssh ubuntu@<db_public_ip>

# Logs de PostgreSQL
sudo tail -f /var/log/postgresql/postgresql-16-main.log

# Logs de inicialización
tail -f /var/log/database.log

# Conectar a PostgreSQL
sudo -u postgres psql -d dispatch_db
```

### 8.4. Métricas de Kong (vía Admin API)
```bash
# Estado de backends
curl http://<kong_public_ip>:8001/upstreams/backend-cluster/health | jq

# Targets activos
curl http://<kong_public_ip>:8001/upstreams/backend-cluster/targets | jq

# Estadísticas del servicio
curl http://<kong_public_ip>:8001/services/dispatch-service | jq

# Configuración de plugins
curl http://<kong_public_ip>:8001/plugins | jq
```

## 9. Comandos útiles de administración

### 9.1. Reiniciar componentes
```bash
# Reiniciar Kong
ssh ubuntu@<kong_public_ip>
docker restart kong

# Reiniciar backend específico
ssh ubuntu@<backend_public_ip>
sudo systemctl restart django-backend.service

# Reiniciar PostgreSQL
ssh ubuntu@<db_public_ip>
sudo systemctl restart postgresql
```

### 9.2. Modificar configuración de Kong
```bash
# Agregar target manualmente
curl -X POST http://<kong_public_ip>:8001/upstreams/backend-cluster/targets \
  -d "target=192.168.1.100:8080&weight=100"

# Eliminar target
curl -X DELETE http://<kong_public_ip>:8001/upstreams/backend-cluster/targets/<target_id>

# Cambiar rate limiting
curl -X PATCH http://<kong_public_ip>:8001/plugins/<plugin_id> \
  -d "config.minute=200"
```

### 9.3. Consultas a PostgreSQL
```bash
ssh ubuntu@<db_public_ip>
sudo -u postgres psql -d dispatch_db

-- Ver usuarios
SELECT usename FROM pg_user;

-- Ver conexiones activas
SELECT * FROM pg_stat_activity;

-- Ver tamaño de base de datos
SELECT pg_database_size('dispatch_db');
```

## 10. Solución de problemas frecuentes

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| `terraform apply` falla | Límites de cuenta EC2/VPC | Revise límites en AWS Console → Service Quotas |
| Kong no responde en puerto 8000 | Inicialización en progreso | Espere 3-5 minutos, revise `docker logs kong` |
| Backends no aparecen en Kong | Service discovery no iniciado | `systemctl status kong-discovery`, revisar logs |
| Error 502 Bad Gateway | Todos los backends caídos | Revisar `systemctl status django-backend` en cada backend |
| Health checks fallan | Endpoint `/despachos/reporte` no responde | Verificar logs de Django, confirmar que app esté corriendo |
| Email de alertas no llega | Suscripción SNS no confirmada | Revisar bandeja de entrada y spam |
| Backend no se auto-recupera | Systemd service detenido manualmente | `systemctl start django-backend.service` |
| Discovery no detecta cambios | IAM permissions insuficientes | Verificar que LabRole tenga permisos EC2:DescribeInstances |
| Kong Admin API no accesible | Security group bloqueando puerto 8001 | Verificar `des-traffic-cb` security group |
| PostgreSQL rechaza conexiones | `pg_hba.conf` mal configurado | Revisar `/etc/postgresql/16/main/pg_hba.conf` |

## 11. Buenas prácticas y recomendaciones

### 11.1. Seguridad
- ✅ **Cambiar contraseñas por defecto** de PostgreSQL (`despacho2025`, `kong2025`)
- ✅ **Restringir Security Groups** a rangos IP específicos (no `0.0.0.0/0`)
- ✅ **Usar VPC privada** para backends y base de datos
- ✅ **Rotar credenciales** periódicamente
- ✅ **Habilitar SSL/TLS** en Kong (certificados Let's Encrypt)
- ✅ **Implementar WAF** (AWS WAF) delante de Kong

### 11.2. Alta disponibilidad
- ✅ **Aumentar backends** a 5-7 instancias en producción
- ✅ **Distribuir en múltiples AZs** (Availability Zones)
- ✅ **Usar RDS Multi-AZ** en lugar de EC2 para PostgreSQL
- ✅ **Implementar Auto Scaling Group** para backends
- ✅ **Configurar backups automáticos** de base de datos (snapshots diarios)

### 11.3. Performance
- ✅ **Usar instancias más grandes**: `t3.small` o `t3.medium` para producción
- ✅ **Habilitar caching** en Kong (plugin response-transformer)
- ✅ **Optimizar queries** PostgreSQL (añadir índices)
- ✅ **Usar ElastiCache Redis** para sesiones Django
- ✅ **Configurar CDN** (CloudFront) delante de Kong

### 11.4. Monitoreo avanzado
- ✅ **CloudWatch Dashboards** para métricas en tiempo real
- ✅ **CloudWatch Alarms** para alertas proactivas
- ✅ **Application Load Balancer** con health checks propios
- ✅ **Prometheus + Grafana** para métricas detalladas
- ✅ **ELK Stack** (Elasticsearch, Logstash, Kibana) para logs centralizados

## 12. Estimación de costos (región us-east-1)

### 12.1. Costos mensuales estimados (24/7)
| Recurso | Cantidad | Tipo | Costo/hora | Costo/mes |
|---------|----------|------|------------|-----------|
| Base de datos | 1 | t2.nano | $0.0058 | ~$4.20 |
| Backends Django | 3 | t2.nano | $0.0058 × 3 | ~$12.60 |
| Kong Gateway | 1 | t2.small | $0.023 | ~$16.70 |
| EBS Storage | ~40 GB | gp3 | $0.08/GB | ~$3.20 |
| Data Transfer | ~10 GB | OUT | $0.09/GB | ~$0.90 |
| **TOTAL** | | | | **~$37.60/mes** |

### 12.2. Optimización de costos
- ⚡ Usar **Reserved Instances** (ahorro hasta 72%)
- ⚡ Apagar instancias fuera de horario (staging/dev)
- ⚡ Usar **Spot Instances** para backends no críticos
- ⚡ Implementar **Auto Scaling** basado en métricas
- ⚡ Revisar **AWS Cost Explorer** mensualmente

**Nota**: Precios aproximados, verificar en [AWS Pricing Calculator](https://calculator.aws/)

## 13. Mantenimiento

### 13.1. Actualizaciones de software
```bash
# Actualizar Kong
ssh ubuntu@<kong_public_ip>
docker pull kong/kong-gateway:latest
docker stop kong
docker rm kong
# Re-ejecutar comando docker run con nueva imagen

# Actualizar backends
ssh ubuntu@<backend_public_ip>
cd /apps/Sprint2
git pull origin main
/apps/Sprint2/venv/bin/pip install -r requirements.txt --upgrade
sudo systemctl restart django-backend.service
```

### 13.2. Backups
```bash
# Backup manual de PostgreSQL
ssh ubuntu@<db_public_ip>
sudo -u postgres pg_dump dispatch_db > /tmp/backup_$(date +%F).sql

# Automatizar backups (cron diario)
echo "0 2 * * * postgres pg_dump dispatch_db > /backups/dispatch_$(date +\%F).sql" | sudo crontab -

# Backup de configuración de Kong
curl http://<kong_public_ip>:8001/config > kong_config_$(date +%F).json
```

### 13.3. Escalado horizontal (agregar backend)
```bash
# 1. Crear nueva instancia con Terraform
# Editar deployment.tf y agregar 'd' al set de backends:
# for_each = toset(["a", "b", "c", "d"])

# 2. Aplicar cambios
terraform plan -out=planfile
terraform apply planfile

# 3. Service discovery detectará automáticamente el nuevo backend en ~30s
# Verificar:
curl http://<kong_public_ip>:8001/upstreams/backend-cluster/targets
```

## 14. Destrucción de infraestructura

### 14.1. Destrucción completa
```bash
# Advertencia: Esto elimina TODOS los recursos
terraform destroy

# Confirmar escribiendo "yes"
```

### 14.2. Destrucción selectiva
```bash
# Eliminar solo backends
terraform destroy -target=aws_instance.dispatch

# Eliminar solo Kong
terraform destroy -target=aws_instance.kong
```

### 14.3. Limpiar state
```bash
# Si hay recursos huérfanos
terraform state list
terraform state rm aws_instance.orphaned_resource
```

## 15. Referencias técnicas

### 15.1. Documentación oficial
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Kong Gateway Documentation](https://docs.konghq.com/gateway/latest/)
- [PostgreSQL 16 Documentation](https://www.postgresql.org/docs/16/)
- [Django Deployment Checklist](https://docs.djangoproject.com/en/5.0/howto/deployment/checklist/)
- [AWS EC2 User Data](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)
- [Systemd Service Management](https://www.freedesktop.org/software/systemd/man/systemd.service.html)

### 15.2. Plugins de Kong relevantes
- [Rate Limiting](https://docs.konghq.com/hub/kong-inc/rate-limiting/)
- [Circuit Breaker](https://docs.konghq.com/hub/kong-inc/circuit-breaker/)
- [Correlation ID](https://docs.konghq.com/hub/kong-inc/correlation-id/)
- [Health Checks](https://docs.konghq.com/gateway/latest/how-kong-works/health-checks-circuit-breakers/)

### 15.3. AWS Services utilizados
- [EC2 Instances](https://aws.amazon.com/ec2/)
- [VPC Security Groups](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_SecurityGroups.html)
- [SNS (Simple Notification Service)](https://aws.amazon.com/sns/)
- [IAM Roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)

## 16. Anexos

### 16.1. Diagrama de arquitectura
```
Internet
    │
    ▼
┌─────────────────┐
│  Kong Gateway   │ :8000 (Proxy)
│   (t2.small)    │ :8001 (Admin)
└─────────────────┘
    │
    │ Round-Robin + Health Checks
    ├─────────┬─────────┬─────────┐
    ▼         ▼         ▼         ▼
┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
│Backend │ │Backend │ │Backend │ │ Future │
│   A    │ │   B    │ │   C    │ │Backend │
│ :8080  │ │ :8080  │ │ :8080  │ │ :8080  │
└────────┘ └────────┘ └────────┘ └────────┘
    │         │         │         │
    └─────────┴─────────┴─────────┘
                │
                ▼
        ┌──────────────┐
        │  PostgreSQL  │
        │    :5432     │
        │ (dispatch_db)│
        │   (kong)     │
        └──────────────┘
```

### 16.2. Flujo de auto-recuperación
```
1. Backend Django se cae (crash, OOM, SIGKILL)
   ↓
2. Systemd detecta fallo en <1 segundo
   ↓
3. Systemd espera 5 segundos (RestartSec)
   ↓
4. Systemd reinicia django-backend.service
   ↓
5. Django inicia en puerto 8080
   ↓
6. Watchdog verifica /despachos/reporte cada 10s
   ↓
7. Si 3 checks fallan → Watchdog fuerza restart
   ↓
8. Kong health check detecta cambio (~10s)
   ↓
9. Kong actualiza estado del backend (healthy/unhealthy)
   ↓
10. Service Discovery sincroniza targets (~30s)
```

### 16.3. Comandos de depuración rápida
```bash
# Verificar estado general desde Kong
ssh ubuntu@$(terraform output -raw kong_public_ip)
sudo docker logs --tail 100 kong
sudo systemctl status kong-discovery
curl localhost:8001/upstreams/backend-cluster/health | jq

# Verificar backend específico
ssh ubuntu@<backend_ip>
sudo systemctl status django-backend
sudo systemctl status django-watchdog
tail -100 /var/log/django.log
curl localhost:8080/despachos/reporte

# Verificar base de datos
ssh ubuntu@$(terraform output -raw database_private_ip)
sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;"
sudo systemctl status postgresql
```

## 17. Licencia y soporte
- **Proyecto académico**: Universidad de los Andes - Arquitectura de Software
- **Repositorio**: [Sprint2](https://github.com/mr-torres-d-ojedas/Sprint2)
- **Soporte**: Issues en GitHub o contactar al equipo docente

---

**Última actualización**: 2025-02  
**Versión**: 2.0.0 (Kong + Service Discovery + Auto-Recovery)