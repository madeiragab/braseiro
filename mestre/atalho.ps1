# Cria o atalho "Braseiro" na pasta acima desta - a raiz do pendrive,
# se o projeto estiver em X:\MesaRPG.
$ErrorActionPreference = "Stop"

$Raiz = Split-Path -Parent $PSScriptRoot
$Pai  = Split-Path -Parent $Raiz
if (-not $Pai) { $Pai = $Raiz }

$alvo  = Join-Path $Raiz "INICIAR.bat"
$icone = Join-Path $Raiz "mestre\braseiro.ico"
$lnk   = Join-Path $Pai  "Braseiro.lnk"

if (-not (Test-Path -LiteralPath $alvo)) {
  Write-Host "   Nao achei o INICIAR.bat em $Raiz" -ForegroundColor Red
  exit 1
}

$sh = New-Object -ComObject WScript.Shell
$s  = $sh.CreateShortcut($lnk)
$s.TargetPath       = $alvo
$s.WorkingDirectory = $Raiz
$s.Description      = "Braseiro - sua mesa de RPG, local e offline"
$s.WindowStyle      = 1
if (Test-Path -LiteralPath $icone) { $s.IconLocation = "$icone,0" }
$s.Save()

Write-Host ""
Write-Host "   Atalho criado:" -ForegroundColor Green
Write-Host ("     " + $lnk) -ForegroundColor Cyan
Write-Host ("   aponta para " + $alvo) -ForegroundColor DarkGray
if (-not (Test-Path -LiteralPath $icone)) {
  Write-Host "   (sem braseiro.ico - o atalho fica com o icone padrao)" -ForegroundColor Yellow
}
Write-Host ""
