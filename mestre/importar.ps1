# Importa um .gguf baixado pelo navegador pra dentro do acervo do pendrive.
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Raiz   = Split-Path -Parent $PSScriptRoot
$Ollama = Join-Path $Raiz "bin\ollama.exe"
$UTF8   = New-Object System.Text.UTF8Encoding($false)

$env:OLLAMA_MODELS = Join-Path $Raiz "models"
$env:OLLAMA_HOST   = "127.0.0.1:11434"

if (-not (Test-Path -LiteralPath $Ollama)) {
  Write-Host "   Nao achei bin\ollama.exe. Veja o LEIA-ME." -ForegroundColor Red
  Read-Host "   Enter pra fechar"; exit 1
}

# ---- procura .gguf nos lugares provaveis ----
$locais = @(
  (Join-Path $env:USERPROFILE "Downloads"),
  (Join-Path $Raiz "gguf"),
  $Raiz
)
$achados = @()
foreach ($l in $locais) {
  if (Test-Path -LiteralPath $l) {
    $achados += @(Get-ChildItem -LiteralPath $l -Filter *.gguf -File -ErrorAction SilentlyContinue)
  }
}
$achados = @($achados | Sort-Object FullName -Unique)

if ($achados.Count -eq 0) {
  Write-Host ""
  Write-Host "   Nenhum arquivo .gguf encontrado." -ForegroundColor Yellow
  Write-Host "   Procurei em:"
  foreach ($l in $locais) { Write-Host ("     " + $l) -ForegroundColor DarkGray }
  Write-Host ""
  Write-Host "   Baixe um destes pelo navegador (salve em Downloads):"
  Write-Host "     Qwen3 8B   (4,7 GB, mais rapido)" -ForegroundColor Cyan
  Write-Host "       https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf?download=true" -ForegroundColor DarkGray
  Write-Host "     Mistral Nemo 12B  (7,0 GB, portugues melhor)" -ForegroundColor Cyan
  Write-Host "       https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q4_K_M.gguf?download=true" -ForegroundColor DarkGray
  Write-Host ""
  Read-Host "   Enter pra fechar"; exit 1
}

# ---- escolhe ----
if ($achados.Count -eq 1) {
  $arq = $achados[0]
} else {
  Write-Host ""
  Write-Host "   Achei mais de um .gguf:" -ForegroundColor Cyan
  for ($i = 0; $i -lt $achados.Count; $i++) {
    "     [{0}] {1,-52} {2,6:N2} GB" -f ($i+1), $achados[$i].Name, ($achados[$i].Length/1GB) | Write-Host
  }
  Write-Host ""
  $e = Read-Host "   Qual numero"
  $n = 0
  if (-not [int]::TryParse($e, [ref]$n) -or $n -lt 1 -or $n -gt $achados.Count) {
    Write-Host "   Numero invalido." -ForegroundColor Red; Read-Host "   Enter pra fechar"; exit 1
  }
  $arq = $achados[$n-1]
}

# ---- nome curto pro modelo ----
$nome = $arq.BaseName.ToLowerInvariant()
$nome = $nome -replace '[^a-z0-9._-]', '-' -replace '-+', '-'
$nome = $nome.Trim('-')
if ($nome.Length -gt 48) { $nome = $nome.Substring(0, 48).Trim('-') }

Write-Host ""
Write-Host ("   Arquivo: " + $arq.Name) -ForegroundColor Cyan
Write-Host ("   Tamanho: {0:N2} GB" -f ($arq.Length/1GB)) -ForegroundColor DarkGray
Write-Host ("   Virara o modelo: " + $nome) -ForegroundColor Cyan
Write-Host ("   Destino: " + $env:OLLAMA_MODELS) -ForegroundColor DarkGray

# ---- cabe? ----
$destino = (Get-Item $Raiz).PSDrive
$livre = (Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $destino.Name + ":'")).FreeSpace
Write-Host ("   Livre no destino: {0:N2} GB" -f ($livre/1GB)) -ForegroundColor DarkGray
if ($livre -lt $arq.Length * 1.05) {
  Write-Host ""
  Write-Host "   [!] Nao cabe. O ollama COPIA o arquivo pro acervo." -ForegroundColor Red
  Write-Host "       Libere espaco ou aponte o acervo pro C:." -ForegroundColor Red
  Read-Host "   Enter pra fechar"; exit 1
}
if ($arq.FullName.StartsWith($Raiz, [StringComparison]::OrdinalIgnoreCase)) {
  Write-Host ""
  Write-Host "   [!] Aviso: o .gguf ja esta no pendrive e sera COPIADO," -ForegroundColor Yellow
  Write-Host "       ocupando o dobro ate voce apagar o original." -ForegroundColor Yellow
}

Write-Host ""
Read-Host "   Enter pra importar (leva alguns minutos)" | Out-Null

# ---- sobe o motor se preciso ----
$ligado = $false
try { (New-Object Net.Sockets.TcpClient).Connect('127.0.0.1', 11434); $ligado = $true } catch {}
if (-not $ligado) {
  Write-Host "   Ligando o motor..." -ForegroundColor DarkGray
  Start-Process -FilePath $Ollama -ArgumentList "serve" -WindowStyle Minimized | Out-Null
  $fim = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $fim) {
    try { (New-Object Net.Sockets.TcpClient).Connect('127.0.0.1', 11434); $ligado = $true; break } catch { Start-Sleep -Milliseconds 500 }
  }
  if (-not $ligado) { Write-Host "   Motor nao subiu." -ForegroundColor Red; Read-Host "   Enter"; exit 1 }
}

# ---- Modelfile minimo: o proprio .gguf ja carrega o template de chat ----
$mf = Join-Path $env:TEMP "braseiro-modelfile"
[System.IO.File]::WriteAllText($mf, ("FROM " + $arq.FullName + "`n"), $UTF8)

Write-Host ""
& $Ollama create $nome -f $mf
if ($LASTEXITCODE -ne 0) {
  Write-Host "   Falhou ao criar o modelo." -ForegroundColor Red
  Read-Host "   Enter pra fechar"; exit 1
}
Remove-Item -LiteralPath $mf -Force -ErrorAction SilentlyContinue

# ---- o template de chat veio junto? sem ele a narracao sai torta ----
$tpl = (& $Ollama show $nome --template 2>&1 | Out-String).Trim()
Write-Host ""
if ($tpl.Length -lt 10 -or $tpl -match '^Error') {
  Write-Host "   [!] Esse .gguf nao trouxe template de chat embutido." -ForegroundColor Yellow
  Write-Host "       Ele funciona, mas pode responder de forma estranha." -ForegroundColor Yellow
} else {
  Write-Host "   [ok] Template de chat detectado no arquivo." -ForegroundColor Green
}

# ---- aponta o config.txt pro modelo novo ----
$cfgPath = Join-Path $Raiz "config.txt"
$cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
$antigo = if ($cfg -match '(?m)^modelo=(.+)$') { $Matches[1].Trim() } else { "(nenhum)" }
$cfg = [Regex]::Replace($cfg, '(?m)^modelo=.*$', ("modelo=" + $nome))
[System.IO.File]::WriteAllText($cfgPath, $cfg, $UTF8)

Write-Host ""
Write-Host "   ============================================" -ForegroundColor Green
Write-Host "   Pronto." -ForegroundColor Green
Write-Host ("   config.txt: " + $antigo) -ForegroundColor DarkGray
Write-Host ("           ->  " + $nome) -ForegroundColor Green
Write-Host "   ============================================" -ForegroundColor Green
Write-Host ""
Write-Host ("   Agora pode APAGAR o arquivo original pra liberar {0:N2} GB:" -f ($arq.Length/1GB)) -ForegroundColor Cyan
Write-Host ("     " + $arq.FullName) -ForegroundColor DarkGray
Write-Host ""
Write-Host "   Feche isto e clique no Braseiro." -ForegroundColor Cyan
Write-Host ""
Read-Host "   Enter pra fechar" | Out-Null
