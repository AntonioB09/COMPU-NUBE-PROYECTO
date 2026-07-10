# Reporte de Auditoría — Proyecto Mensajería Instantánea (Synapse + Element + Docker)

**Fecha:** 10 de julio de 2026
**Versión evaluada:** Commit inicial (3 commits en historial)
**Alcance:** Arquitectura, seguridad, configuración, automatización, documentación y calidad operativa.

---

## 1. Resumen ejecutivo

Plataforma de chat autocontenida basada en el protocolo Matrix, que integra servidor Synapse, cliente Element Web, PostgreSQL y backups automatizados, todo orquestado con Docker Compose. Está diseñada para funcionar en localhost (desarrollo) y en red LAN (varias PCs). El proyecto es funcional, bien estructurado para su propósito y destaca por su simplicidad operativa. Presenta deficiencias relevantes en seguridad, idempotencia de scripts y cobertura de configuración que deben atenderse antes de cualquier exposición más allá de un entorno de laboratorio de confianza.

---

## 2. Criterios técnicos — Fortalezas

### 2.1 Arquitectura de servicios bien definida

- Separación clara en 4 servicios Docker (PostgreSQL, Synapse, Element, backups), cada uno con responsabilidad única.
- `docker-compose.yml:56 líneas` — compacto, legible y sin dependencias circulares.
- Healthcheck en PostgreSQL (`pg_isready`) con `depends_on: condition: service_healthy` en Synapse y backups, garantizando orden de arranque correcto.
- `restart: unless-stopped` en todos los servicios para tolerancia a fallos.

### 2.2 Elección tecnológica acertada

- **Matrix** como protocolo abierto y federado — evita vendor lock-in y permite interoperabilidad futura.
- **Synapse** es el servidor de referencia del ecosistema Matrix, con soporte activo de la comunidad.
- **Element Web** es el cliente web oficial, mantenido por el mismo equipo, garantizando compatibilidad total.
- **PostgreSQL 16 Alpine** como backend: base de datos robusta, con soporte nativo en Synapse vía `psycopg2`, muy superior a SQLite para cualquier carga concurrente real.
- **100% open source** y sin costos de licenciamiento.

### 2.3 Automatización del despliegue

- `scripts/setup.ps1` (50 líneas) realiza el ciclo completo: generación de configs → despliegue Docker → espera activa con healthcheck → creación de usuario admin → resumen final.
- `scripts/generate-config.ps1` (64 líneas) transforma un `.env` de 5 variables en dos archivos de configuración (homeserver.yaml + config.json), eliminando configuración manual propensa a errores.
- El polling del endpoint `/_matrix/client/versions` como mecanismo de readiness es correcto y portable.

### 2.4 Respaldo de datos

- Servicio `postgres-backup` con política de retención en 3 niveles:
  - 7 copias diarias
  - 4 copias semanales
  - 6 copias mensuales
- Volumen persistente separado (`./data/backups`) fuera del volumen de datos de PostgreSQL, protegiendo contra corrupción del volumen principal.
- Schedule `@daily` automatizado, sin intervención manual.

### 2.5 Documentación operativa completa

- `PLAN.md` (388 líneas) cubre: estructura, requisitos, paso a paso de creación de archivos, modo localhost, modo LAN, tabla de comunicación multi-PC, comandos útiles y consideraciones de seguridad.
- El documento incluye los contenidos reales de cada archivo del proyecto, facilitando reconstrucción desde cero.
- Las advertencias de seguridad (sin SSL, credenciales en texto plano, solo LAN de confianza) están explícitamente declaradas.

### 2.6 Externalización total de la configuración

- `.env` como único punto de variación: cambiar `SYNAPSE_SERVER_NAME` alterna entre modo localhost y modo LAN sin tocar código ni YAML.
- Todas las credenciales y secretos están parametrizados, no hardcodeados.

### 2.7 Diseño para dos modos de operación

- Modo localhost para desarrollo individual y pruebas rápidas.
- Modo LAN para uso real multi-PC en red local de confianza.
- La transición entre modos está documentada paso a paso en `PLAN.md:329-388`.

---

## 3. Puntos débiles y soluciones propuestas

### 3.1 [CRÍTICO] Credenciales en texto plano

| Aspecto | Detalle |
|---|---|
| **Problema** | `.env` contiene `POSTGRES_PASSWORD`, `POSTGRES_USER`, `POSTGRES_DB` y `SYNAPSE_REGISTRATION_SHARED_SECRET` en texto plano. `PLAN.md` muestra estas credenciales en su contenido inline (líneas 40-49). El usuario admin se crea con `admin/admin123` hardcodeado en `setup.ps1:33`. Las credenciales viajan sin TLS entre cliente y servidor. |
| **Impacto** | Cualquier persona con acceso al repositorio, al archivo `.env`, o que capture tráfico en la red LAN puede obtener todas las credenciales del sistema. |
| **Solución** | 1. Excluir `.env` del control de versiones (agregar al `.gitignore`) y proporcionar `.env.example` con valores placeholder. 2. Usar Docker Secrets para `POSTGRES_PASSWORD` y `SYNAPSE_REGISTRATION_SHARED_SECRET`. 3. Parametrizar la contraseña del usuario admin en `setup.ps1` como variable de entorno o prompt interactivo. 4. Para producción real, agregar un reverse proxy con TLS (Caddy o Nginx + Let's Encrypt). 5. Rotar todas las credenciales actuales inmediatamente si el repositorio es compartido. |

### 3.2 [CRÍTICO] Discrepancia entre configuración real y configuración generada por script

| Aspecto | Detalle |
|---|---|
| **Problema** | El `homeserver.yaml` real en disco (`data/synapse/homeserver.yaml:24-27`) está configurado con **SQLite**, no con PostgreSQL. El script `generate-config.ps1` tiene la lógica para migrar a PostgreSQL, pero solo se ejecuta si el archivo **no existe** (línea 18). Como el archivo ya fue generado, el script omite la migración y el sistema corre con SQLite. De igual forma, `enable_registration` no se habilita y el `registration_shared_secret` permanece con el valor autogenerado en lugar del definido en `.env`. `element/config.json` tiene `disable_guests: false` en lugar de `true` como pretende el script. |
| **Impacto** | Synapse opera con SQLite (bajo rendimiento, no concurrente) ignorando la infraestructura PostgreSQL desplegada. El registro de usuarios puede estar bloqueado. Los backups de PostgreSQL respaldan una base de datos vacía o no usada. |
| **Solución** | 1. Modificar `generate-config.ps1` para que siempre sobrescriba la sección `database` (no solo cuando el archivo no existe). 2. Agregar un modo `--force` que regenere todo desde cero. 3. Eliminar `data/synapse/homeserver.yaml`, `data/synapse/localhost.signing.key` y `data/synapse/localhost.log.config`, luego ejecutar `generate-config.ps1` seguido de `docker compose up -d` para aplicar PostgreSQL. 4. Verificar con `docker compose exec synapse cat /data/homeserver.yaml | grep psycopg2` que el cambio se aplicó. |

### 3.3 [ALTO] Secretos generados automáticamente vs secretos del .env

| Aspecto | Detalle |
|---|---|
| **Problema** | `homeserver.yaml:30` tiene `registration_shared_secret: "~.eBlL1jpofiaz~v7vmd35:8K92,a0lR-.Tfo2+bLBmWAUa.bd"` — valor autogenerado por Synapse, no el `secreto_admin` definido en `.env`. La sustitución en `generate-config.ps1:44` usa regex que puede fallar si el formato generado difiere del esperado. |
| **Impacto** | El secreto de registro definido por el usuario no se aplica. La API de registro administrativo requiere el secreto real, causando confusión. |
| **Solución** | 1. En lugar de usar regex sobre el valor generado, insertar la línea `registration_shared_secret: "<valor>"` al final del archivo YAML (Synapse usa la última ocurrencia). 2. Verificar post-generación con `grep registration_shared_secret data/synapse/homeserver.yaml`. |

### 3.4 [ALTO] Sin verificación post-configuración

| Aspecto | Detalle |
|---|---|
| **Problema** | `setup.ps1` solo verifica que Synapse responda en el endpoint de versiones. No verifica: que PostgreSQL esté configurado como backend, que el registro esté habilitado, que Element apunte al servidor correcto, que los backups estén corriendo. |
| **Impacto** | El setup puede reportar "Servidor listo" con una configuración rota (SQLite en lugar de PostgreSQL, registro deshabilitado, etc.). |
| **Solución** | Agregar assertions post-setup: 1. `docker compose exec synapse cat /data/homeserver.yaml \| grep psycopg2`. 2. `docker compose exec synapse cat /data/homeserver.yaml \| grep 'enable_registration: true'`. 3. `curl http://localhost/_matrix/client/versions` desde el host. 4. `docker compose logs postgres-backup \| grep "Backup completed"`. |

### 3.5 [ALTO] El script setup.ps1 hardcodea localhost para el healthcheck

| Aspecto | Detalle |
|---|---|
| **Problema** | `setup.ps1:16` usa `http://localhost:8008/_matrix/client/versions` para verificar readiness. En modo LAN, `SYNAPSE_SERVER_NAME` es una IP distinta, pero el healthcheck asume localhost. Esto funciona porque el puerto está mapeado en el host, pero no valida que el servidor responda con el `server_name` correcto. |
| **Impacto** | Falso positivo: el healthcheck puede pasar en localhost aunque el servidor esté configurado incorrectamente para LAN. Además, otros PCs en la red no usan `localhost`. |
| **Solución** | Leer `$serverName` del `.env` y usarlo en el healthcheck: `http://${serverName}:8008/_matrix/client/versions`. |

### 3.6 [MEDIO] El script setup.ps1 no carga variables del .env antes de mostrar el resumen

| Aspecto | Detalle |
|---|---|
| **Problema** | `setup.ps1:36` intenta leer `SYNAPSE_SERVER_NAME` de variables de entorno del proceso, pero `setup.ps1` no ejecuta `generate-config.ps1` con dot-sourcing ni carga `.env` directamente. Si `.env` no fue cargado previamente en la sesión, `$serverName` será `$null` y mostrará `localhost` por defecto, ocultando potencialmente el nombre real del servidor. |
| **Impacto** | El resumen final puede mostrar `http://localhost` cuando el servidor real es `http://192.168.1.10`, confundiendo al usuario. |
| **Solución** | Agregar al inicio de `setup.ps1` la misma carga de `.env` que usa `generate-config.ps1`, o hacer dot-sourcing del script de generación para heredar las variables. |

### 3.7 [MEDIO] Inconsistencia element/config.json en disco vs lo que genera el script

| Aspecto | Detalle |
|---|---|
| **Problema** | `element/config.json` en disco (líneas 1-10) contiene: `"disable_guests": false`, `"brand": "Element"`, y tiene `"server_name": "localhost"` anidado en `m.homeserver`. El script `generate-config.ps1:52-64` genera: `disable_guests: true`, `default_country_code: "MX"`, sin campo `brand`, y sin `server_name` en `m.homeserver`. El archivo real no fue generado por el script actual. |
| **Impacto** | El archivo `config.json` está desactualizado respecto a la intención del script. Huéspedes habilitados contradice la configuración deseada. |
| **Solución** | 1. Ejecutar `generate-config.ps1` para regenerar `config.json` con los valores correctos. 2. Unificar el schema de `config.json` entre el script y `PLAN.md`. 3. Agregar `"brand": "Element"` y `"server_name"` al script si son deseados, o eliminarlos si no. |

### 3.8 [MEDIO] Ausencia de .gitignore para .env y datos sensibles

| Aspecto | Detalle |
|---|---|
| **Problema** | No se encontró evidencia de que `.env` esté en `.gitignore`. El archivo `.env` con contraseñas reales podría estar versionado. `data/` sí está en `.gitignore`, pero `.env` es igualmente sensible. |
| **Impacto** | Las credenciales pueden quedar expuestas en el historial de git y en remotos. |
| **Solución** | 1. Agregar `.env` al `.gitignore`. 2. Crear `.env.example` con valores placeholder. 3. Si `.env` ya fue commiteado, usar `git filter-branch` o BFG Repo-Cleaner para purgar el historial y rotar todas las credenciales. |

### 3.9 [MEDIO] Sin separación de redes Docker

| Aspecto | Detalle |
|---|---|
| **Problema** | `docker-compose.yml` no define redes personalizadas. Todos los servicios comparten la red default de Compose. PostgreSQL expone implicitamente su puerto a otros contenedores sin restricción. |
| **Impacto** | Si se agregaran más servicios al compose en el futuro, tendrían acceso directo a PostgreSQL. Principio de mínimo privilegio no aplicado. |
| **Solución** | Definir redes separadas: `backend` (postgres + synapse + backups) y `frontend` (element + synapse). PostgreSQL solo en `backend`. Element solo en `frontend`. Synapse en ambas como puente. |

### 3.10 [MEDIO] Docker Compose sin healthcheck en Element

| Aspecto | Detalle |
|---|---|
| **Problema** | El servicio `element` no tiene healthcheck definido. Si el contenedor de Element arranca pero NGINX interno falla, no hay detección automática. |
| **Impacto** | El sistema puede reportarse como "arriba" (`docker compose ps` muestra "Up") pero Element no servir tráfico. |
| **Solución** | Agregar healthcheck a Element: `test: ["CMD", "curl", "-f", "http://localhost/"]`, `interval: 15s`, `timeout: 5s`, `retries: 3`. |

### 3.11 [BAJO] PLATAFORMA — Sin soporte para Linux/macOS nativo

| Aspecto | Detalle |
|---|---|
| **Problema** | Los scripts están escritos en PowerShell 5.1 (Windows-only). `PLAN.md` documenta sintaxis PowerShell y comandos como `ipconfig`. En Linux/macOS los scripts no funcionan. |
| **Impacto** | Barrera de entrada para usuarios y desarrolladores en otros sistemas operativos. El proyecto es técnicamente portable (Docker), pero la automatización no. |
| **Solución** | 1. Proveer scripts equivalentes en Bash/sh para Linux/macOS. 2. O reescribir en un lenguaje cross-platform (Python). 3. Como alternativa mínima, documentar comandos equivalentes para `docker compose` directo en Linux. |

### 3.12 [BAJO] PLATAFORMA — Dependencia de Docker Desktop con WSL2

| Aspecto | Detalle |
|---|---|
| **Problema** | `PLAN.md:30` especifica "Docker Desktop (Windows) con WSL2 habilitado". Docker Desktop dejó de ser gratuito para uso comercial en organizaciones grandes. WSL2 requiere Windows 10/11 Pro o Enterprise. |
| **Impacto** | Limitación de licenciamiento para equipos corporativos y requisito de edición de Windows. |
| **Solución** | 1. Documentar alternativas: Docker CE en VM Linux sobre Hyper-V/VirtualBox, o Podman Desktop (gratuito y open source). 2. Evaluar migrar el compose a Podman (compatible con sintaxis de Compose). |

### 3.13 [BAJO] Documentación con artefactos de sesión

| Aspecto | Detalle |
|---|---|
| **Problema** | `PLAN.md:327` contiene `New user localpart [root]: anto1`, un remanente de una sesión interactiva pegada accidentalmente. |
| **Impacto** | Mínimo — reduce profesionalismo del documento. |
| **Solución** | Eliminar la línea 327 de `PLAN.md`. |

### 3.14 [BAJO] Sin tests automatizados

| Aspecto | Detalle |
|---|---|
| **Problema** | No hay tests unitarios, de integración ni de humo. No hay validación de que los scripts generan configuraciones correctas. |
| **Impacto** | Los cambios en scripts o configuraciones no tienen red de seguridad. Regresiones silenciosas posibles (como la discrepancia SQLite vs PostgreSQL ya detectada). |
| **Solución** | 1. Agregar tests de humo en `setup.ps1` como assertions post-deploy. 2. Para validación de configuraciones generadas, usar tests con `Pester` (framework de testing para PowerShell). 3. Agregar `docker compose config` como validación de sintaxis del compose antes del deploy. |

### 3.15 [BAJO] Imágenes Docker sin versiones fijas (latest)

| Aspecto | Detalle |
|---|---|
| **Problema** | `synapse` y `element` usan tag `:latest` (`docker-compose.yml:18,32`). PostgreSQL y backups usan `:16` y `:16` respectivamente, que son versiones fijas. |
| **Impacto** | Una actualización inesperada de `latest` puede introducir cambios incompatibles con la configuración actual, rompiendo el despliegue sin previo aviso. |
| **Solución** | Fijar versiones explícitas: `matrixdotorg/synapse:v1.123.0`, `vectorim/element-web:v1.11.95`. Actualizar manualmente con pruebas. |

---

## 4. Matriz de riesgos

| ID | Hallazgo | Severidad | Probabilidad | Riesgo |
|----|----------|-----------|-------------|--------|
| 3.1 | Credenciales en texto plano | Crítico | Cierto | **Crítico** |
| 3.2 | SQLite activo en lugar de PostgreSQL | Crítico | Cierto | **Crítico** |
| 3.3 | Secretos no sincronizados con .env | Alto | Alta | **Alto** |
| 3.4 | Sin verificación post-configuración | Alto | Alta | **Alto** |
| 3.5 | Healthcheck hardcodeado a localhost | Alto | Media | **Medio** |
| 3.6 | Variables de .env no cargadas en setup | Medio | Alta | **Medio** |
| 3.7 | config.json desactualizado | Medio | Cierto | **Medio** |
| 3.8 | .env potencialmente versionado | Medio | Media | **Medio** |
| 3.9 | Sin segmentación de redes Docker | Medio | Baja | **Bajo** |
| 3.10 | Sin healthcheck en Element | Medio | Baja | **Bajo** |
| 3.11 | Sin soporte Linux/macOS | Bajo | Media | **Bajo** |
| 3.12 | Dependencia Docker Desktop WSL2 | Bajo | Baja | **Bajo** |
| 3.13 | Artefacto en documentación | Bajo | Cierto | **Bajo** |
| 3.14 | Sin tests automatizados | Bajo | Alta | **Medio** |
| 3.15 | Tags latest en imágenes | Bajo | Baja | **Bajo** |

---

## 5. Recomendaciones priorizadas (plan de acción)

### Fase 1 — Corrección inmediata (antes del próximo despliegue)

1. **Migrar Synapse a PostgreSQL**: eliminar `data/synapse/homeserver.yaml`, regenerar con `generate-config.ps1`, verificar con `grep psycopg2`.
2. **Regenerar `element/config.json`**: ejecutar `generate-config.ps1` para sobrescribir con valores correctos (`disable_guests: true`).
3. **Agregar `.env` al `.gitignore`** y crear `.env.example`.
4. **Rotar credenciales** en `.env` y actualizar `POSTGRES_PASSWORD` y `SYNAPSE_REGISTRATION_SHARED_SECRET`.
5. **Quitar línea 327** de `PLAN.md`.

### Fase 2 — Robustez (1-2 días)

6. Modificar `generate-config.ps1` para usar modo `--force` que siempre aplique cambios (no solo si el archivo no existe).
7. Agregar assertions post-setup en `setup.ps1` (ver items 3.4).
8. Corregir healthcheck en `setup.ps1` para usar `$serverName` dinámico.
9. Cargar `.env` al inicio de `setup.ps1`.
10. Agregar healthcheck al servicio `element` en `docker-compose.yml`.
11. Definir redes `backend` y `frontend` en `docker-compose.yml`.

### Fase 3 — Madurez (1 semana)

12. Fijar versiones explícitas de imágenes Docker (`synapse`, `element`).
13. Implementar tests de humo automatizados con Pester.
14. Crear scripts Bash equivalentes para Linux/macOS.
15. Documentar alternativa Podman Desktop.
16. Agregar reverse proxy Caddy con HTTPS autogenerado para elevar seguridad en LAN.

---

## 6. Veredicto

El proyecto es una **buena solución** para el problema planteado: mensajería instantánea autocontenida en red local con tecnología open source madura y mínima fricción operativa. La arquitectura es sólida, la elección del stack es acertada y la documentación es completa para su público objetivo.

**No obstante**, en su estado actual presenta dos fallas críticas que impiden su correcto funcionamiento: (a) Synapse opera con SQLite ignorando la infraestructura PostgreSQL desplegada, y (b) las credenciales están expuestas en múltiples puntos. Estas deben resolverse antes de considerar el proyecto operativo.

Con las 7 correcciones de la Fase 1 aplicadas, el proyecto alcanza un nivel aceptable para uso en laboratorio/LAN de confianza. Con las fases 2 y 3 completadas, sería una base sólida para entornos semi-productivos internos.