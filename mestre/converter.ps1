# Converte os PDF de campanha\livros\ em texto, mostrando o progresso.
# Nao e obrigatorio: o Braseiro converte sozinho na primeira jogada depois que
# voce solta o PDF. Isto existe pra livro grande, que demora e travaria a jogada.
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Raiz   = Split-Path -Parent $PSScriptRoot
$Livros = Join-Path $Raiz "campanha\livros"
$UTF8   = New-Object System.Text.UTF8Encoding($false)

. (Join-Path $PSScriptRoot "pdf.ps1")

if (-not (Test-Path -LiteralPath $Livros)) {
  Write-Host "   Nao existe a pasta campanha\livros ainda." -ForegroundColor Yellow
  Read-Host "   Enter pra fechar"; exit 0
}

$pdfs = @(Get-ChildItem -LiteralPath $Livros -Recurse -File -Filter *.pdf -ErrorAction SilentlyContinue)
if ($pdfs.Count -eq 0) {
  Write-Host ""
  Write-Host "   Nenhum PDF em campanha\livros\." -ForegroundColor Yellow
  Write-Host "   Solte os livros la dentro (pode usar subpastas) e rode de novo." -ForegroundColor DarkGray
  Write-Host ""
  Read-Host "   Enter pra fechar"; exit 0
}

Write-Host ""
Write-Host ("   {0} PDF encontrado(s)." -f $pdfs.Count) -ForegroundColor Cyan
Write-Host ""

$ok = 0; $pulados = 0; $ruins = 0
foreach ($p in $pdfs) {
  $nome  = $p.FullName.Substring($Livros.Length).TrimStart('\', '/')
  $cache = $p.FullName + ".txt"
  $aviso = $p.FullName + ".aviso"

  if ((Test-Path -LiteralPath $cache) -and ((Get-Item -LiteralPath $cache).LastWriteTimeUtc -ge $p.LastWriteTimeUtc)) {
    Write-Host ("   -- {0}  (ja convertido)" -f $nome) -ForegroundColor DarkGray
    $pulados++
    continue
  }

  Write-Host ("   .. {0}  ({1:N1} MB)" -f $nome, ($p.Length / 1MB)) -NoNewline
  $t0 = Get-Date
  try { $r = ExtrairTextoPdf $p.FullName } catch { $r = $null }
  $seg = ((Get-Date) - $t0).TotalSeconds

  if ($null -ne $r -and $r.texto) {
    [System.IO.File]::WriteAllText($cache,
      ("<!-- gerado do PDF " + $p.Name + ". Pode editar a vontade: so e refeito se o PDF mudar. -->`r`n`r`n" + $r.texto), $UTF8)
    if (Test-Path -LiteralPath $aviso) { Remove-Item -LiteralPath $aviso -Force }
    $secoes = ([regex]::Matches($r.texto, '(?m)^## ')).Count
    Write-Host ("`r   ok {0}  ->  {1:N0} chars, {2} secoes, {3:N0}s        " -f $nome, $r.texto.Length, $secoes, $seg) -ForegroundColor Green
    $ok++
  } else {
    $m = if ($r) { $r.motivo } else { "erro ao ler o arquivo" }
    [System.IO.File]::WriteAllText($aviso, $m, $UTF8)
    Write-Host ("`r   !! {0}                          " -f $nome) -ForegroundColor Red
    Write-Host ("      " + $m) -ForegroundColor DarkYellow
    $ruins++
  }
}

Write-Host ""
Write-Host ("   {0} convertido(s), {1} ja pronto(s), {2} sem jeito." -f $ok, $pulados, $ruins) -ForegroundColor Cyan
if ($ruins -gt 0) {
  Write-Host ""
  Write-Host "   Pros que nao deram: abra no leitor de PDF e use 'Salvar como' texto," -ForegroundColor DarkGray
  Write-Host "   ou copie e cole o capitulo que interessa num .md ali na pasta." -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "   Os .pdf.txt sao arquivos comuns: da pra abrir e arrumar o corte," -ForegroundColor DarkGray
Write-Host "   e por linhas 'chaves:' embaixo dos titulos." -ForegroundColor DarkGray
Write-Host ""
Read-Host "   Enter pra fechar" | Out-Null
