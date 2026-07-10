# Proyecto Mensajería Instantánea — Synapse + Element + Docker

Plataforma de chat autocontenida usando el protocolo **Matrix** (servidor Synapse), el cliente **Element Web**, base de datos **PostgreSQL** y orquestación con **Docker Compose**. Funciona en localhost (desarrollo) y en red local (varias PCs). Todo el stack es open source.

**Integrantes:**
Daila Arcia V-29.841.396
Antonio Blanco V-20.613.680

**Docente:**
Jhoberth Andrés Bravo Viloria


## Requisitos

- Docker Desktop (Windows) con WSL2 habilitado, o Docker Engine en Linux
- PowerShell 5.1+ (Windows) o Bash (Linux/macOS)
- ~2 GB de espacio libre en disco

## Estructura del proyecto

```
proyecto-cp/
├── docker-compose.yml
├── .env                          # Configuración intercambiable
├── .gitignore
├── README.md
├── PLAN.md                       # Documentación completa y plan de proyecto
├── AUDITORIA.md                  # Reporte de auditoría técnica
├── element/
│   └── config.json               # Configuración de Element (generada por script)
├── scripts/
│   ├── generate-config.ps1       # Genera configs según .env
│   └── setup.ps1                 # Bootstrap completo
└── data/                         # Volúmenes Docker (persistencia)
    ├── synapse/
    ├── postgres/
    └── backups/
```

## Inicio rápido

### Modo localhost (una sola PC)

```powershell
# 1. Asegúrate de que .env tenga:
#    SYNAPSE_SERVER_NAME=localhost

# 2. Ejecuta el setup completo
.\scripts\setup.ps1

# 3. Abre http://localhost en tu navegador
#    Usuario admin: admin / admin123
```

### Modo red local (varias PCs)

```powershell
# 1. Obtén tu IP local
ipconfig          # Busca "Dirección IPv4", ej: 192.168.1.10

# 2. Edita .env:
#    SYNAPSE_SERVER_NAME=192.168.1.10

# 3. Ejecuta setup
.\scripts\setup.ps1

# 4. En cualquier PC de la red, abre:
#    http://192.168.1.10
```

## Comandos principales

```powershell
# Iniciar servicios
docker compose up -d

# Detener servicios
docker compose down

# Ver estado de los contenedores
docker compose ps

# Ver logs en tiempo real
docker compose logs -f synapse
docker compose logs -f element
docker compose logs -f postgres-backup

# Crear usuarios manualmente
docker compose exec synapse register_new_matrix_user http://localhost:8008 -c /data/homeserver.yaml -u nombre_usuario -p contraseña

# Crear usuario administrador
docker compose exec synapse register_new_matrix_user http://localhost:8008 -c /data/homeserver.yaml -u admin2 -p admin456 --admin

# Regenerar configuraciones sin redeploy
.\scripts\generate-config.ps1

# Respaldar la base de datos manualmente
docker compose exec postgres-backup backup
```

## Comunicación entre PCs

| PC | Rol | URL |
|---|---|---|
| Host (corre Docker) | Servidor + Cliente | `http://<IP_DEL_HOST>` |
| PC2 (misma red) | Cliente | `http://<IP_DEL_HOST>` |
| PC3 (misma red) | Cliente | `http://<IP_DEL_HOST>` |

1. Cada persona crea su cuenta desde `http://<IP_DEL_HOST>`
2. Un usuario crea una sala e invita a los demás por nombre de usuario
3. Todos los mensajes se sincronizan en tiempo real vía Matrix

## Notas de seguridad

- Esta configuración **no usa SSL/TLS**. Las credenciales viajan en texto plano. Usar solo en redes locales de confianza.
- Para exposición a internet se requiere agregar un reverse proxy con HTTPS (Caddy o Nginx).
- Las credenciales en `.env` son de ejemplo. Cámbialas antes de usar en un entorno compartido.

## Más información

- Documentación completa y plan de proyecto: [PLAN.md](PLAN.md)
- Reporte de auditoría técnica: [AUDITORIA.md](AUDITORIA.md)
- [Documentación oficial de Synapse](https://element-hq.github.io/synapse/latest/)
- [Documentación oficial de Element](https://element.io/)