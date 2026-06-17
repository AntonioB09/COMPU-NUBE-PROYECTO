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

Write-Host "Generando configuracion para: $serverName"

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
  Write-Host "homeserver.yaml ya existe, se omite generacion."
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
