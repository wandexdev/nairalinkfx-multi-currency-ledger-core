# Values match docker-compose.yml (demo credentials only).
$env:PGHOST     = "localhost"
$env:PGPORT     = "5432"
$env:PGUSER     = "pguser"
$env:PGPASSWORD = "pgpass"
$env:MONGO_URI  = "mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0"
$env:MODE       = "docker"     # Portfolio 5 scripts control the Docker containers
$env:PYTHONUTF8 = "1"          
$env:PGCLIENTENCODING = "UTF8"
Write-Host "Environment set: PG $($env:PGUSER)@$($env:PGHOST):$($env:PGPORT), MODE=$($env:MODE)" -ForegroundColor Green
