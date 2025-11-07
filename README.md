# Sprint2Deployment

## 1. Descripción general
Este módulo de Terraform despliega la infraestructura del Sprint 2 para la plataforma de despachos en AWS. Crea una base de datos PostgreSQL, dos réplicas del backend Django y una instancia Kong Gateway que actúa como circuit breaker y load balancer, distribuyendo el tráfico HTTP entre los backends con health checks automáticos y recuperación ante fallos.

## 2. Requisitos previos
- Terraform ≥ 1.5 instalado y disponible en el `PATH`.
- AWS CLI configurado con credenciales e IAM policy que permita administrar EC2, VPC y Security Groups.
- Llaves SSH generadas para acceder a las instancias si es necesario.
- Permisos de salida a internet para descargar la AMI, Docker y dependencias durante el `user_data`.

## 3. Variables principales
| Variable         | Descripción                                  | Valor por defecto |
|------------------|----------------------------------------------|-------------------|
| `region`         | Región AWS donde desplegar                   | `us-east-1`       |
| `project_prefix` | Prefijo estándar para nombrar recursos       | `des`             |
| `instance_type`  | Tipo de instancia EC2 para DB y backends     | `t2.nano`         |

Para personalizar valores cree un archivo `terraform.tfvars` o exporte variables con `-var`.

## 4. Componentes desplegados
- **Grupos de seguridad**: 
  - Tráfico Django (8080) para backends
  - PostgreSQL (5432) para la base de datos
  - SSH (22) para acceso administrativo
  - Kong (8000 proxy, 8001 admin API) para circuit breaker
- **Instancias EC2**:
  - `des-db`: Ubuntu 24.04 con PostgreSQL 16 inicializado, usuario `dispatch_user`, base de datos `dispatch_db`, `max_connections=2000`.
  - `des-backend-a` y `des-backend-b`: Ubuntu 24.04, clonan `https://github.com/mr-torres-d-ojedas/Sprint2.git`, crean entorno virtual, instalan dependencias, ejecutan migraciones y scripts de población, exponen Django en puerto 8080.
  - `des-kong`: Ubuntu 24.04 con Docker y Kong Gateway 2.7.2.0, configurado como circuit breaker y load balancer con:
    - Balanceo Round-Robin entre backends
    - Health checks activos cada 10 segundos
    - Circuit breaker automático (3 fallos → circuit abierto)
    - Rate limiting: 100 peticiones/minuto
    - Recuperación automática de backends
- **Salidas**: IPs privadas/públicas de todos los componentes y URLs de acceso a Kong para consumo inmediato.

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

## 6. Validación posterior
1. Espere ~3-5 minutos a que Kong y los backends se configuren completamente.
2. Abra la URL entregada en `output.kong_proxy_url` y verifique la carga de la aplicación.
3. Comandos de verificación:
   ```bash
   # Probar acceso vía Kong
   curl http://<KONG_IP>:8000/despachos/reporte
   
   # Ver estado de backends (health checks)
   curl http://<KONG_IP>:8001/upstreams/backend-cluster/health
   
   # Ver configuración de servicios
   curl http://<KONG_IP>:8001/services
   ```
4. Si requiere diagnóstico:
   - Revise `sudo tail -f /var/log/backend.log` o `/var/log/django.log` en cada instancia backend.
   - Revise `sudo tail -f /var/log/kong-setup.log` en la instancia Kong.
   - Compruebe logs de Kong: `sudo docker logs kong`
   - Verifique conectividad a la DB mediante `psql postgresql://dispatch_user:despacho2025@<IP_DB>:5432/dispatch_db`.

## 7. Accesos relevantes
- **Kong Proxy (Acceso principal)**: `http://<kong_public_ip>:8000/despachos/reporte`
- **Kong Admin API**: `http://<kong_public_ip>:8001` (para configuración y monitoreo)
- **Backends directos** (solo para debugging): 
  - Backend A: `http://<backend_a_public_ip>:8080`
  - Backend B: `http://<backend_b_public_ip>:8080`
- **Base de datos**: `<private_ip>:5432` (solo accesible dentro de la VPC)

## 8. Características del Circuit Breaker (Kong)

### Health Checks
- **Activos**: Verificación HTTP cada 10 segundos en `/despachos/reporte`
  - Backend saludable: 2 respuestas exitosas consecutivas (200, 302)
  - Backend no saludable: 3 fallos HTTP o timeouts
- **Pasivos**: Monitoreo del tráfico real
  - Saludable: 5 respuestas exitosas
  - No saludable: 5 fallos o 2 timeouts

### Protecciones
- **Rate Limiting**: 100 peticiones por minuto por cliente
- **Circuit Breaker**: Retira automáticamente backends fallidos del pool
- **Auto-recuperación**: Reintegra backends cuando vuelven a estar saludables
- **Balanceo**: Round-Robin con pesos iguales (100) entre backends
- **Timeouts**: 60 segundos para conexión, lectura y escritura
- **Reintentos**: Hasta 5 intentos automáticos en caso de fallo

### Observabilidad
- **Correlation ID**: Header `X-Kong-Request-ID` en cada petición
- **Logs centralizados**: stdout/stderr para integración con sistemas de monitoreo

## 9. Buenas prácticas y mantenimiento
- Cambie la contraseña por defecto de PostgreSQL y restrinja el SG de la base de datos a rangos privados.
- Considere tamaños `t3.small` o superiores para cargas reales (Kong requiere al menos `t2.small`).
- Automatice backups de PostgreSQL (snapshots o `pg_dump`) según la política de la organización.
- Monitoree el estado de los backends regularmente vía Admin API de Kong.
- Configure alertas basadas en métricas de Kong para detectar degradación del servicio.
- Revise logs de Kong periódicamente para identificar patrones de fallos.
- Mantenga el repositorio actualizado; cualquier cambio en scripts de `user_data` requiere un `terraform taint` o recreación controlada.

## 10. Estimación de costos
- 3 instancias (`t2.nano` para DB y backends, `t2.small` para Kong) ejecutándose 24/7.
- Costos de transferencia de datos y almacenamiento estándar.
- Revise AWS Pricing Calculator y ajuste `instance_type` y horarios para optimizar costos.
- Considere Reserved Instances o Savings Plans para despliegues de larga duración.

## 11. Solución de problemas frecuentes
| Síntoma                                   | Acción recomendada                                                                 |
|-------------------------------------------|-------------------------------------------------------------------------------------|
| `terraform apply` falla al crear recursos | Revise límites de cuenta EC2 y permisos IAM.                                        |
| Kong no responde en puerto 8000           | Verifique que el contenedor Docker esté corriendo: `docker ps`. Revise logs: `docker logs kong` |
| Backends no pasan health check            | Inspeccione logs Django en `/var/log/backend.log` y `/var/log/django.log`; confirme que puerto 8080 esté abierto y respondiendo en `/despachos/reporte`. |
| Error de acceso a DB                      | Verifique que `DATABASE_HOST` corresponda a la IP privada actual de la base de datos. |
| Kong reporta todos los backends como unhealthy | Espere 2-3 minutos para que los backends completen su inicialización. Verifique acceso directo a backends. |
| Rate limiting bloqueando tráfico legítimo | Ajuste la configuración en `kong.yml` y recargue: `docker exec kong kong reload` |
| Cambios en configuración de Kong no aplican | Modifique `/opt/kong/declarative/kong.yml` y ejecute: `docker exec kong kong reload` |

## 12. Comandos útiles de Kong
```bash
# Conectar a la instancia Kong
ssh -i tu-key.pem ubuntu@<KONG_IP>

# Ver logs en tiempo real
docker logs -f kong

# Recargar configuración sin reiniciar
docker exec kong kong reload

# Ver estado de salud del cluster
curl http://localhost:8001/upstreams/backend-cluster/health | jq

# Ver estadísticas de requests
curl http://localhost:8001/status | jq

# Listar todos los plugins activos
curl http://localhost:8001/plugins | jq

# Ver targets individuales
curl http://localhost:8001/upstreams/backend-cluster/targets | jq
```

## 13. Destrucción de la infraestructura
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
Confirme con `yes`. Esto elimina todas las instancias EC2 y Security Groups asociados.

## 14. Referencias
- [Documentación Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Kong Gateway Documentation](https://docs.konghq.com/gateway/latest/)
- [Kong Health Checks & Circuit Breaker](https://docs.konghq.com/gateway/latest/reference/health-checks-circuit-breakers/)
- [Kong Rate Limiting Plugin](https://docs.konghq.com/hub/kong-inc/rate-limiting/)
- [Guía oficial PostgreSQL](https://www.postgresql.org/docs/)
