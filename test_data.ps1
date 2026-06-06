$baseUrl = "http://localhost:3000/api"

Write-Host "=== 生成测试数据 ===" -ForegroundColor Cyan

Write-Host "`n1. 创建批次..." -ForegroundColor Yellow
$batchBody = @{
    cocoon_type = "双宫茧"
    target_reeling_kg = 100.5
    target_temp = 98.0
} | ConvertTo-Json

$batch = Invoke-RestMethod -Uri "$baseUrl/batches" -Method Post -Body $batchBody -ContentType "application/json"
$batchId = $batch.id
Write-Host "批次 #$batchId 创建成功" -ForegroundColor Green

Write-Host "`n2. 写入正常温度曲线 (前10分钟)..." -ForegroundColor Yellow
for ($i = 0; $i -lt 10; $i++) {
    $temp = 97.5 + (Get-Random -Maximum 1.0)
    $body = @{ temp_c = $temp } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/batches/$batchId/boil" -Method Post -Body $body -ContentType "application/json" | Out-Null
    Start-Sleep -Milliseconds 100
}
Write-Host "写入10条正常温度数据" -ForegroundColor Green

Write-Host "`n3. 写入低温曲线 (接下来5分钟，模拟故障)..." -ForegroundColor Yellow
for ($i = 0; $i -lt 5; $i++) {
    $temp = 94.0 + (Get-Random -Maximum 1.5)
    $body = @{ temp_c = $temp } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/batches/$batchId/boil" -Method Post -Body $body -ContentType "application/json" | Out-Null
    Start-Sleep -Milliseconds 100
}
Write-Host "写入5条低温数据 (应该触发 underheat_segment)" -ForegroundColor Green

Write-Host "`n4. 写入浮茧数据 (包含连续低浮茧率)..." -ForegroundColor Yellow
for ($i = 0; $i -lt 15; $i++) {
    if ($i -ge 5 -and $i -lt 10) {
        $ratio = 30.0 + (Get-Random -Maximum 8.0)
    } else {
        $ratio = 50.0 + (Get-Random -Maximum 20.0)
    }
    $body = @{ float_ratio_pct = $ratio } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/batches/$batchId/float" -Method Post -Body $body -ContentType "application/json" | Out-Null
    Start-Sleep -Milliseconds 100
}
Write-Host "写入15条浮茧数据 (其中5-10条 <40%，同期有低温段，应该标记为可疑批次)" -ForegroundColor Green

Write-Host "`n5. 恢复正常温度..." -ForegroundColor Yellow
for ($i = 0; $i -lt 10; $i++) {
    $temp = 97.5 + (Get-Random -Maximum 1.0)
    $body = @{ temp_c = $temp } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/batches/$batchId/boil" -Method Post -Body $body -ContentType "application/json" | Out-Null
    Start-Sleep -Milliseconds 100
}
Write-Host "恢复正常温度" -ForegroundColor Green

Write-Host "`n6. 验证批次状态..." -ForegroundColor Yellow
$updatedBatch = Invoke-RestMethod -Uri "$baseUrl/batches/$batchId" -Method Get
Write-Host "批次状态: $($updatedBatch.batch.status)"
Write-Host "是否可疑: $($updatedBatch.batch.is_suspect)"
Write-Host "低温段数: $($updatedBatch.underheat_segments.Count)"

if ($updatedBatch.batch.is_suspect) {
    Write-Host "`n7. 尝试出库 (应该返回409)..." -ForegroundColor Yellow
    try {
        Invoke-RestMethod -Uri "$baseUrl/batches/$batchId/outbound" -Method Patch
    } catch {
        Write-Host "出库被拒绝，HTTP $($_.Exception.Response.StatusCode.value__): $($_.ErrorDetails.Message)" -ForegroundColor Red
    }
}

Write-Host "`n=== 测试数据生成完成 ===" -ForegroundColor Green
Write-Host "批次ID: $batchId"
Write-Host "查看详情: http://localhost:3000/batch/$batchId"
Write-Host "导出报告: GET $baseUrl/batches/$batchId/report"
