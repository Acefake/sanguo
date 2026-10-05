param([string]$Model = 'qwen3:1.7b')
$ErrorActionPreference = 'Stop'
$ollamaCommand = Get-Command ollama -ErrorAction SilentlyContinue
$ollamaExecutable = if ($ollamaCommand) { $ollamaCommand.Source } else { Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe' }
if (-not (Test-Path -LiteralPath $ollamaExecutable)) {
    throw 'Install Ollama from https://ollama.com/download/windows, then run this script again.'
}
try {
    $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2
} catch {
    Start-Process -FilePath $ollamaExecutable -ArgumentList 'serve' -WindowStyle Hidden
    $serviceReady = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        try {
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2
            $serviceReady = $true
            break
        } catch { }
    }
    if (-not $serviceReady) { throw 'Ollama did not start on port 11434.' }
}
$installedModels = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3
if (-not ($installedModels.models | Where-Object { $_.name -eq $Model -or $_.model -eq $Model })) {
    & $ollamaExecutable pull $Model
    if ($LASTEXITCODE -ne 0) { throw 'Model download failed. Check the local proxy and Ollama download log.' }
}
$warmupBody = @{ model = $Model; stream = $false; think = $false; messages = @(@{ role = 'user'; content = 'Reply OK.' }); options = @{ num_ctx = 4096; num_predict = 8 }; keep_alive = '10m' } | ConvertTo-Json -Depth 8
$null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/chat' -Method Post -ContentType 'application/json' -Body $warmupBody -TimeoutSec 120
Write-Host "Ready: $Model. In game Settings, select the local Ollama preset, detect, then save."
