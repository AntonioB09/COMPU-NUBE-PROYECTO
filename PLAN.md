# Proyecto Mensajería Instantánea — Synapse + Element + Docker

Plataforma de chat autocontenida usando el protocolo Matrix (servidor Synapse), el cliente Element Web, base de datos Postgres y orquestación con Docker Compose. Funciona en localhost (una PC) y en red local (varias PCs).

---

## Estructura del proyecto

```
proyecto-cp/
├── docker-compose.yml           # Orquestación de servicios
├── .env                          # Configuración intercambiable
├── .gitignore
├── PLAN.md                      # Este archivo
├── element/
│   └── config.json               # Configuración de Element (generada por script)
├── scripts/
│   ├── generate-config.ps1       # Genera configs según .env
│   └── setup.ps1                 # Bootstrap completo
└── data/                         # Volúmenes Docker (persistencia)
    ├── synapse/
    └── postgres/
```

---

## Requisitos

- Docker Desktop (Windows) con WSL2 habilitado
- PowerShell 5.1+
- Ningún otro costo — todo es open source

---

## Paso 1: Crear archivos del proyecto

### 1.1 `.env`

```ini
# Cambia según lo que necesites:
#   "localhost"       → solo tu PC
#   "192.168.x.x"     → toda la red local (pon tu IP real)
SYNAPSE_SERVER_NAME=localhost

POSTGRES_PASSWORD=postgres_secreto
POSTGRES_DB=synapse
POSTGRES_USER=synapse
SYNAPSE_REGISTRATION_SHARED_SECRET=secreto_admin
```

### 1.2 `docker-compose.yml`

```yaml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  synapse:
    image: matrixdotorg/synapse:latest
    ports:
      - "8008:8008"
    volumes:
      - ./data/synapse:/data
    environment:
      SYNAPSE_SERVER_NAME: ${SYNAPSE_SERVER_NAME}
      SYNAPSE_REPORT_STATS: "no"
    depends_on:
      postgres:
        condition: service_healthy
    restart: unless-stopped

  element:
    image: vectorim/element-web:latest
    ports:
      - "80:80"
    volumes:
      - ./element/config.json:/app/config.json
    depends_on:
      - synapse
    restart: unless-stopped
```

### 1.3 `element/config.json` (template generado por script)

```json
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "http://${SYNAPSE_SERVER_NAME}:8008"
    },
    "m.identity_server": {
      "base_url": "http://${SYNAPSE_SERVER_NAME}:8008"
    }
  },
  "disable_guests": true,
  "default_country_code": "MX"
}
```

---

## Paso 2: Scripts de automatización

### 2.1 `scripts/generate-config.ps1`

```powershell
param(
  [string]$EnvFile = ".env"
)

# Cargar variables del .env
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*([^#=]+)=(.*)\s*$') {
    [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2])
  }
}

$serverName = [System.Environment]::GetEnvironmentVariable("SYNAPSE_SERVER_NAME")
$sharedSecret = [System.Environment]::GetEnvironmentVariable("SYNAPSE_REGISTRATION_SHARED_SECRET")

Write-Host "Generando configuración para: $serverName"

# --- Generar homeserver.yaml (si no existe) ---
if (-not (Test-Path "data/synapse/homeserver.yaml")) {
  Write-Host "Generando homeserver.yaml..."
  docker compose run --rm -e SYNAPSE_SERVER_NAME=$serverName synapse generate

  $homeserverPath = "data/synapse/homeserver.yaml"
  $content = Get-Content $homeserverPath -Raw

  # Reemplazar database de sqlite a postgres
  $newDbConfig = @"
database:
  name: psycopg2
  args:
    user: $([System.Environment]::GetEnvironmentVariable("POSTGRES_USER"))
    password: $([System.Environment]::GetEnvironmentVariable("POSTGRES_PASSWORD"))
    database: $([System.Environment]::GetEnvironmentVariable("POSTGRES_DB"))
    host: postgres
    port: 5432
    cp_min: 5
    cp_max: 10
"@
  $content = $content -replace '(?s)database:\s*\n\s+name: sqlite3.*?(?=\n\S|\z)', $newDbConfig

  # Habilitar registro
  $content = $content -replace 'enable_registration:\s*false', 'enable_registration: true'

  # Poner shared secret
  $content = $content -replace 'registration_shared_secret:\s*".*?"', "registration_shared_secret: `"$sharedSecret`""

  $content | Set-Content $homeserverPath
  Write-Host "homeserver.yaml generado con postgres."
} else {
  Write-Host "homeserver.yaml ya existe, se omite generación."
}

# --- Generar element/config.json ---
$config = @{
  default_server_config = @{
    m_homeserver     = @{ base_url = "http://${serverName}:8008" }
    m_identity_server = @{ base_url = "http://${serverName}:8008" }
  }
  disable_guests      = $true
  default_country_code = "MX"
}

$jsonPath = "element/config.json"
$config | ConvertTo-Json -Depth 10 | Set-Content $jsonPath
Write-Host "config.json generado en $jsonPath"
```

### 2.2 `scripts/setup.ps1`

```powershell
Write-Host "=== Setup del servidor Matrix ===" -ForegroundColor Cyan

# 1. Generar configuraciones
& ".\scripts\generate-config.ps1"

# 2. Levantar servicios
Write-Host "Levantando contenedores..." -ForegroundColor Yellow
docker compose up -d

# 3. Esperar a que Synapse esté listo
Write-Host "Esperando a que Synapse inicie..." -ForegroundColor Yellow
$ready = $false
$maxRetries = 30
for ($i = 0; $i -lt $maxRetries; $i++) {
  try {
    $response = Invoke-WebRequest -Uri "http://localhost:8008/_matrix/client/versions" -UseBasicParsing -TimeoutSec 2
    if ($response.StatusCode -eq 200) { $ready = $true; break }
  } catch {}
  Start-Sleep 2
}

if (-not $ready) {
  Write-Host "Error: Synapse no respondió a tiempo." -ForegroundColor Red
  exit 1
}

Write-Host "Synapse está listo." -ForegroundColor Green

# 4. Crear usuario admin
Write-Host "Creando usuario admin..." -ForegroundColor Yellow
docker compose exec synapse register_new_matrix_user `
  http://localhost:8008 -c /data/homeserver.yaml `
  -u admin -p admin123 --admin

# 5. Mostrar resumen
$serverName = [System.Environment]::GetEnvironmentVariable("SYNAPSE_SERVER_NAME")
if (-not $serverName) { $serverName = "localhost" }

Write-Host @"

  ============================================

    Servidor listo en http://$serverName

    Usuario admin: admin / admin123

    Accede desde cualquier PC de la red: http://$serverName

  ============================================
"@ -ForegroundColor Green
```

---

## Paso 3: Uso

### Modo localhost (desarrollo)

```powershell
# 1. Asegúrate de que .env tenga: SYNAPSE_SERVER_NAME=localhost
# 2. Ejecuta:
.\scripts\setup.ps1
# 3. Abre http://localhost en tu navegador
```

### Modo red local (varias PCs)

```powershell
# 1. Obtén tu IP local:
ipconfig
#    Busca "Dirección IPv4" — ej: 192.168.1.10

# 2. Edita .env:
#    SYNAPSE_SERVER_NAME=192.168.1.10

# 3. Ejecuta:
.\scripts\setup.ps1

# 4. En cualquier PC de la red abre: http://192.168.1.10
```

---

## Comunicación entre PCs

| PC               | Rol               | URL                                |
|------------------|-------------------|------------------------------------|
| Host (corre Docker) | Servidor + Cliente | `http://localhost` o `http://192.168.x.x` |
| PC2 (misma red)  | Cliente           | `http://192.168.x.x`              |
| PC3 (misma red)  | Cliente           | `http://192.168.x.x`              |

1. Cada usuario crea su cuenta en `http://<IP>`
2. Un usuario crea una sala y comparte el nombre de la sala
3. Los demás se unen buscando la sala por nombre o por invitación
4. Todos los mensajes se sincronizan en tiempo real vía Matrix

---

## Comandos útiles

```powershell
docker compose up -d           # Iniciar servicios
docker compose down            # Detener servicios
docker compose logs -f synapse # Ver logs de Synapse
docker compose logs -f element # Ver logs de Element
docker compose exec synapse register_new_matrix_user http://localhost:8008 -c /data/homeserver.yaml
                               # Crear más usuarios manualmente
```

---

## Consideraciones de seguridad

- Sin SSL — las credenciales viajan en texto plano. Solo para red local de confianza.
- Para producción/internet, agregar Caddy con HTTPS.
- El registro está abierto (`enable_registration: true`). Para producción, cambiarlo a `false` y crear usuarios solo por admin.

---

## Tiempo estimado: ~1 hora
