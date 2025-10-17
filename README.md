# Sprint2Deployment
## 1. Descripción general
Este módulo de Terraform despliega la infraestructura del Sprint 2 para la plataforma de despachos en AWS. Crea una base de datos PostgreSQL, dos réplicas del backend Django y un Application Load Balancer (ALB) que distribuye el tráfico HTTP.

## 2. Requisitos previos
- Terraform ≥ 1.5 instalado y disponible en el `PATH`.
- AWS CLI configurado con credenciales e IAM policy que permita administrar EC2, ELBv2, VPC y SG.
- Llaves SSH generadas para acceder a las instancias si es necesario.
- Permisos de salida a internet para descargar la AMI y dependencias durante el `user_data`.

## 3. Variables principales
| Variable         | Descripción                                  | Valor por defecto |
|------------------|----------------------------------------------|-------------------|
| `region`         | Región AWS donde desplegar                   | `us-east-1`       |
| `project_prefix` | Prefijo estándar para nombrar recursos       | `des`             |
| `instance_type`  | Tipo de instancia EC2 para DB y backends     | `t2.nano`         |

Para personalizar valores cree un archivo `terraform.tfvars` o exporte variables con `-var`.

## 4. Componentes desplegados
- **Grupos de seguridad**: tráfico HTTP (80), Django (8080), PostgreSQL (5432) y SSH (22).
- **Instancias EC2**:
  - `des-db`: Ubuntu 24.04 con PostgreSQL 16 inicializado, usuario `dispatch_user`, `dispatch_db`, `max_connections=2000`.
  - `des-backend-a` y `des-backend-b`: Ubuntu 24.04, clonan `https://github.com/mr-torres-d-ojedas/Sprint2.git`, crean entorno virtual, instalan dependencias, ejecutan migraciones y scripts de población, exponen Django en 8080.
- **Load Balancer**: ALB público que enruta tráfico HTTP (80) hacia ambas réplicas mediante health checks Round-Robin.
- **Salidas**: IPs privadas/públicas y DNS del ALB para consumo inmediato.

## 5. Pasos de despliegue
```bash
terraform init        # Descarga providers y prepara backend local
terraform fmt         # Normaliza formato (opcional)
terraform validate    # Verifica sintaxis y dependencias
terraform plan        # Previsualiza cambios (use -out=planfile si desea aplicar posteriormente)
terraform apply       # Confirma despliegue; escriba yes cuando se solicite
```
Durante `apply`, el `user_data` automatiza la configuración sin intervención manual.

## 6. Validación posterior
1. Espere ~2-3 minutos a que el DNS del ALB se propague.
2. Abra la URL entregada en `output.application_url` y verifique la carga de la app.
3. Si requiere diagnóstico:
   - Revise `sudo tail -f /var/log/backend.log` o `/var/log/django.log` en cada instancia.
   - Compruebe conectividad a la DB mediante `psql postgresql://dispatch_user:despacho2025@<IP_DB>:5432/dispatch_db`.

## 7. Accesos relevantes
- **Load Balancer**: `http://${aws_lb.main.dns_name}`
- **Backends directos**: `http://<public_ip>:8080`
- **Base de datos**: `<private_ip>:5432` (solo accesible dentro de la VPC; expuesto por seguridad a `0.0.0.0/0`, ajuste según políticas internas).

## 8. Buenas prácticas y mantenimiento
- Cambie la contraseña por defecto de PostgreSQL y restrinja el SG de la base de datos a rangos privados.
- Considere tamaños `t3.small` o superiores para cargas reales.
- Automatice backups de PostgreSQL (snapshots o `pg_dump`) según la política de la organización.
- Mantenga el repositorio actualizado; cualquier cambio en scripts de `user_data` requiere un `terraform taint` o recreación controlada.

## 9. Estimación de costos
- 3 instancias `t2.nano` ejecutándose 24/7, ALB y almacenamiento estándar. Revise AWS Pricing Calculator y ajuste `instance_type` y horarios para optimizar costos.

## 10. Solución de problemas frecuentes
| Síntoma                                   | Acción recomendada                                                                 |
|-------------------------------------------|-------------------------------------------------------------------------------------|
| `terraform apply` falla al crear recursos | Revise límites de cuenta (EC2/ELB) y permisos IAM.                                 |
| Backends no pasan health check             | Inspeccione `systemctl status` de PostgreSQL y logs Django; confirme que puerto 8080 esté abierto. |
| Error de acceso a DB                      | Verifique que `DATABASE_HOST` corresponda a la IP privada actual de la base de datos. |
| DNS no resuelve                           | Espere propagación o valide entradas en `terraform output load_balancer_dns`.       |

## 11. Destrucción de la infraestructura
```bash
terraform destroy
```
Confirme con `yes`. Esto elimina instancias, LB y SG asociados.

## 12. Referencias
- [Documentación Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Guía oficial PostgreSQL](https://www.postgresql.org/docs/)
- [AWS Load Balancer Health Checks](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/)