Write-Host "=== 缫丝厂单机系统 - 构建脚本 ===" -ForegroundColor Cyan

Write-Host "`n1. 构建后端 Rust..." -ForegroundColor Yellow
Set-Location backend
cargo build --release
if ($LASTEXITCODE -ne 0) {
    Write-Host "后端构建失败!" -ForegroundColor Red
    exit 1
}
Write-Host "后端构建成功" -ForegroundColor Green
Set-Location ..

Write-Host "`n2. 构建前端 Elm..." -ForegroundColor Yellow
Set-Location frontend
if (-Not (Test-Path "dist")) {
    New-Item -ItemType Directory -Path "dist" | Out-Null
}
Copy-Item index.html dist/index.html
elm make src/Main.elm --output=dist/main.js --optimize
if ($LASTEXITCODE -ne 0) {
    Write-Host "前端构建失败!" -ForegroundColor Red
    exit 1
}
Write-Host "前端构建成功" -ForegroundColor Green
Set-Location ..

Write-Host "`n=== 构建完成 ===" -ForegroundColor Green
Write-Host "后端二进制: backend\target\release\reeling-factory-backend.exe"
Write-Host "前端静态文件: frontend\dist\"
Write-Host "`n启动命令: cd backend && cargo run"
