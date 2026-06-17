Write-Host "=== Setup del servidor Matrix ===" -ForegroundColor Cyan

# 1. Generar configuraciones
& ".\scripts\generate-config.ps1"

# 2. Levantar servicios
Write-Host "Levantando contenedores..." -ForegroundColor Yellow
docker compose up -d

# 3. Esperar a que Synapse este listo
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
  Write-Host "Error: Synapse no respondio a tiempo." -ForegroundColor Red
  exit 1
}

Write-Host "Synapse esta listo." -ForegroundColor Green

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
