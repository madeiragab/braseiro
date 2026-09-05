# Mesa de RPG local - servidor
# Zero dependencia: so PowerShell 5.1 + Ollama rodando em 127.0.0.1:11434
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Raiz = Split-Path -Parent $PSScriptRoot
$UTF8 = New-Object System.Text.UTF8Encoding($false)
# $Campanha, $DirLore e $DirLivros sao resolvidos depois do config,
# porque dependem de qual campanha esta escolhida.

# ---------------------------------------------------------------- utilitarios

function Ler($p) {
  if (Test-Path -LiteralPath $p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } else { "" }
}

function Gravar($p, $t) {
  $d = Split-Path -Parent $p
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  [System.IO.File]::WriteAllText($p, $t, $UTF8)
}

function SemAcento($s) {
  if (-not $s) { return "" }
  $n = ([string]$s).Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $n.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
      [void]$sb.Append($c)
    }
  }
  $sb.ToString().ToLowerInvariant()
}

function Slug($s) {
  $x = SemAcento $s
  $x = [Regex]::Replace($x, "[^a-z0-9]+", "-").Trim("-")
  if ($x.Length -gt 48) { $x = $x.Substring(0, 48).Trim("-") }
  if (-not $x) { $x = "sem-nome" }
  $x
}

# leitura de PDF: ExtrairTextoPdf
. (Join-Path $PSScriptRoot "pdf.ps1")

# ------------------------------------------------------------------- config

$ArqCfg = Join-Path $Raiz "config.txt"
$Cfg = @{
  modelo = "mistral-nemo:12b-instruct-2407-q4_K_M"; contexto = "6144"; camadas_gpu = "auto"
  temperatura = "0.85"; historico = "14"; porta = "11500"
  campanha = "minha-campanha"; pasta_campanhas = ""
}
foreach ($linha in ((Ler $ArqCfg) -split "`r?`n")) {
  if ($linha -match '^\s*([a-z_]+)\s*=\s*(.+?)\s*$') { $Cfg[$Matches[1]] = $Matches[2] }
}
$Porta   = [int]$Cfg.porta
$Ollama  = "http://127.0.0.1:11434"
$MaxHist = [int]$Cfg.historico

function GravarConfig($chave, $valor) {
  $t = Ler $ArqCfg
  $rx = "(?m)^" + [Regex]::Escape($chave) + "=.*$"
  $novo = ($chave + "=" + $valor).Replace('$', '$$')
  if ($t -match $rx) { $t = [Regex]::Replace($t, $rx, $novo) } else { $t = $t.TrimEnd() + "`r`n" + $novo + "`r`n" }
  Gravar $ArqCfg $t
}

# --------------------------------------------------------------- a campanha

# As campanhas NAO vivem no pendrive: vivem em Documentos\Braseiro\<nome>.
# Assim elas sobrevivem a perder o pendrive, entram no backup do Windows, e da
# pra ter varias mesas ao mesmo tempo. O que fica no pendrive e so o programa.
$PastaCampanhas = if ($Cfg.pasta_campanhas) { $Cfg.pasta_campanhas }
                  else { Join-Path ([Environment]::GetFolderPath('MyDocuments')) "Braseiro" }
if (-not (Test-Path -LiteralPath $PastaCampanhas)) {
  New-Item -ItemType Directory -Path $PastaCampanhas -Force | Out-Null
}

function NomeSeguro($n) {
  $x = ([string]$n).Trim()
  $x = [Regex]::Replace($x, '[<>:"/\\|?*\x00-\x1F]', '-')
  $x = $x.Trim('.', ' ', '-')
  if ($x.Length -gt 60) { $x = $x.Substring(0, 60).Trim() }
  if (-not $x) { $x = "minha-campanha" }
  $x
}

function ListarCampanhas {
  @(Get-ChildItem -LiteralPath $PastaCampanhas -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name | ForEach-Object { $_.Name })
}

# Cria a pasta da campanha copiando o modelo que veio junto com o programa.
function SemearCampanha($destino) {
  New-Item -ItemType Directory -Path $destino -Force | Out-Null
  $semente = $null
  foreach ($c in @("modelo", "campanha")) {
    $p = Join-Path $Raiz $c
    if (Test-Path -LiteralPath $p) { $semente = $p; break }
  }
  if ($semente) {
    Get-ChildItem -LiteralPath $semente -Force | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $destino -Recurse -Force
    }
    $h = Join-Path $destino ".historico.json"
    if (Test-Path -LiteralPath $h) { Remove-Item -LiteralPath $h -Force }
  }
}

function AbrirCampanha($nome) {
  $script:NomeCampanha = NomeSeguro $nome
  $script:Campanha     = Join-Path $PastaCampanhas $script:NomeCampanha
  if (-not (Test-Path -LiteralPath $script:Campanha)) { SemearCampanha $script:Campanha }
  $script:DirLore   = Join-Path $script:Campanha "lore"
  $script:DirLivros = Join-Path $script:Campanha "livros"
  $script:ArqHist   = Join-Path $script:Campanha ".historico.json"
  $script:Historico = @()
  if (Test-Path -LiteralPath $script:ArqHist) {
    try { $script:Historico = @((Ler $script:ArqHist) | ConvertFrom-Json) } catch { $script:Historico = @() }
  }
  $script:LivrosIdx  = $null      # o indice e por campanha
  $script:LivrosSelo = $null
}

AbrirCampanha $Cfg.campanha

function SalvarHist { Gravar $ArqHist (ConvertTo-Json @($Historico) -Depth 5 -Compress) }

# ----------------------------------------------------------------- lorebook

# Le campanha/lore/*.md e devolve so as entradas cujas chaves aparecem no texto recente.
# E isso que segura campanha longa sem estourar contexto.
function LoreRelevante($texto) {
  $alvo = SemAcento $texto
  $out  = New-Object Collections.ArrayList
  if (-not (Test-Path -LiteralPath $DirLore)) { return "" }
  foreach ($f in (Get-ChildItem -LiteralPath $DirLore -Filter *.md -File)) {
    $c = Ler $f.FullName
    $chaves = @()
    $corpo  = $c
    if ($c -match '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n') {
      $fm = $Matches[1]
      $corpo = $c.Substring($Matches[0].Length)
      if ($fm -match 'chaves\s*:\s*(.+)') {
        $chaves = ($Matches[1] -split ',') | ForEach-Object { SemAcento $_.Trim() } | Where-Object { $_ }
      }
    } else {
      $chaves = @(SemAcento $f.BaseName)
    }
    foreach ($k in $chaves) {
      if ($k.Length -ge 3 -and $alvo.Contains($k)) { [void]$out.Add($corpo.Trim()); break }
    }
  }
  if ($out.Count -eq 0) { return "" }
  "## Fatos relevantes agora`n" + (($out | Select-Object -First 12) -join "`n`n")
}

# -------------------------------------------------------------- os livros

# campanha\livros\ aceita subpastas a vontade. Cada .md/.txt e cortado em secoes
# pelos titulos (#, ##, ###) e cada secao ganha palavras-chave tiradas do titulo
# e do caminho do arquivo. So a secao citada na conversa entra no contexto:
# um livro inteiro nunca caberia em 6144 tokens.
$script:LivrosIdx  = $null
$script:LivrosSelo = $null

function TermosDe($txt) {
  if (-not $txt) { return @() }
  $t = SemAcento $txt
  $t = [Regex]::Replace($t, "[^a-z0-9]+", " ")
  $fora = @("de","da","do","das","dos","os","as","um","uma","para","por","com","sem","que",
            "the","and","for","of","capitulo","parte","secao","tabela","regra","regras")
  @(($t -split "\s+") |
      Where-Object { $_.Length -ge 4 -and $fora -notcontains $_ } |
      ForEach-Object { $_.Substring(0, [Math]::Min($_.Length, 6)) } |
      Select-Object -Unique)
}

# termos tirados do proprio texto, pra secao que nao tem titulo (o caso do PDF
# convertido, onde nem sempre da pra detectar cabecalho)
function TermosFrequentes($txt, $quantos) {
  if (-not $txt) { return @() }
  $t = SemAcento $txt
  $t = [Regex]::Replace($t, "[^a-z0-9]+", " ")
  $fora = @("para","como","pelo","pela","mais","cada","pode","quando","onde","esse","essa",
            "isso","aquele","seus","suas","este","esta","entre","sobre","todos","todas","ser",
            "que","uma","dos","das","nao","com","por","sem","the","and","for","you","your")
  $c = @{}
  foreach ($p in ($t -split "\s+")) {
    if ($p.Length -lt 5 -or $fora -contains $p) { continue }
    $k = $p.Substring(0, [Math]::Min($p.Length, 6))
    if ($c.ContainsKey($k)) { $c[$k]++ } else { $c[$k] = 1 }
  }
  @($c.GetEnumerator() | Where-Object { $_.Value -ge 2 } |
      Sort-Object -Property @{e={$_.Value};Descending=$true} |
      Select-Object -First $quantos | ForEach-Object { $_.Key })
}

# PDF vira um .pdf.txt do lado, uma vez so. Dali pra frente e texto como qualquer
# outro. Se a extracao nao prestar, grava um .pdf.aviso e NAO indexa nada:
# meio livro em garrancho estraga mais a campanha do que livro nenhum.
$script:PdfConvertidos = @()
$script:PdfFalhos      = @()

function ConverterPdfs {
  $script:PdfConvertidos = @()
  $script:PdfFalhos      = @()
  if (-not (Test-Path -LiteralPath $DirLivros)) { return }
  foreach ($p in @(Get-ChildItem -LiteralPath $DirLivros -Recurse -File -Filter *.pdf -ErrorAction SilentlyContinue)) {
    $cache = $p.FullName + ".txt"
    $aviso = $p.FullName + ".aviso"
    $nome  = $p.FullName.Substring($DirLivros.Length).TrimStart('\', '/')

    $atual = (Test-Path -LiteralPath $cache) -and ((Get-Item -LiteralPath $cache).LastWriteTimeUtc -ge $p.LastWriteTimeUtc)
    $jaFalhou = (Test-Path -LiteralPath $aviso) -and ((Get-Item -LiteralPath $aviso).LastWriteTimeUtc -ge $p.LastWriteTimeUtc)
    if ($atual) { $script:PdfConvertidos += $nome; continue }
    if ($jaFalhou) { $script:PdfFalhos += ($nome + " - " + ((Ler $aviso) -split "`r?`n")[0]); continue }

    try { $r = ExtrairTextoPdf $p.FullName } catch { $r = $null }
    if ($null -ne $r -and $r.texto) {
      Gravar $cache ("<!-- gerado do PDF " + $p.Name + ". Pode editar a vontade: so e refeito se o PDF mudar. -->`n`n" + $r.texto)
      if (Test-Path -LiteralPath $aviso) { Remove-Item -LiteralPath $aviso -Force }
      $script:PdfConvertidos += $nome
    } else {
      $m = if ($r) { $r.motivo } else { "erro ao ler o arquivo" }
      Gravar $aviso $m
      $script:PdfFalhos += ($nome + " - " + $m)
    }
  }
}

function IndexarLivros {
  if (-not (Test-Path -LiteralPath $DirLivros)) {
    $script:LivrosIdx = @(); $script:LivrosSelo = "vazio"; return
  }
  ConverterPdfs
  $arqs = @(Get-ChildItem -LiteralPath $DirLivros -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(md|markdown|txt)$' })
  $selo = (($arqs | ForEach-Object { $_.FullName + $_.LastWriteTimeUtc.Ticks }) -join "|")
  if ($selo -eq $script:LivrosSelo) { return }   # nada mudou, usa o indice em memoria

  $idx = New-Object Collections.ArrayList
  foreach ($f in $arqs) {
    $rel   = $f.FullName.Substring($DirLivros.Length).TrimStart('\', '/')
    $livro = ($rel -replace '\.[^.]+$', '') -replace '[\\/]', ' / '
    $termosArq = TermosDe ($rel -replace '[\\/_.-]', ' ')

    $titulo = $f.BaseName
    $chaves = ""
    $buf    = New-Object Text.StringBuilder
    $linhas = (Ler $f.FullName) -split "`r?`n"

    for ($i = 0; $i -le $linhas.Count; $i++) {
      $linha = if ($i -lt $linhas.Count) { $linhas[$i] } else { $null }
      $novo  = $null
      if ($null -ne $linha -and $linha -match '^\s{0,3}#{1,4}\s+(.+?)\s*#*\s*$') { $novo = $Matches[1].Trim() }

      if ($null -eq $linha -or $novo) {
        $corpo = $buf.ToString().Trim()
        if ($corpo.Length -ge 40) {
          # secao grande vira varios pedacos, cortando em fim de linha
          $pos = 0; $parte = 0
          while ($pos -lt $corpo.Length) {
            $fim = [Math]::Min($pos + 1200, $corpo.Length)
            if ($fim -lt $corpo.Length) {
              $q = $corpo.LastIndexOf("`n", $fim - 1)
              if ($q -gt $pos + 300) { $fim = $q }
            }
            $pedaco = $corpo.Substring($pos, $fim - $pos).Trim()
            $pos = $fim
            $parte++
            if ($pedaco.Length -lt 40) { continue }
            $rot = if ($parte -gt 1) { "$titulo ($parte)" } else { $titulo }
            # termos FORTES (titulo + chaves) sao os unicos que disparam a secao.
            # os do caminho do arquivo sao FRACOS: valem so pra desempate, senao
            # uma palavra do nome do arquivo puxaria o livro inteiro de uma vez.
            $fortes = @(@(TermosDe $titulo) + @(TermosDe $chaves) | Select-Object -Unique)
            # pedaco sem titulo de verdade (PDF convertido costuma cair aqui) ficaria
            # inalcancavel, porque so termo forte dispara. Entao tira do proprio texto.
            if ($titulo -eq $f.BaseName) {
              $fortes = @($fortes + @(TermosFrequentes $pedaco 8) | Select-Object -Unique)
            }
            [void]$idx.Add([pscustomobject]@{
              titulo = $rot
              livro  = $livro
              corpo  = $pedaco
              termos = $fortes
              fracos = @($termosArq)
            })
          }
        }
        [void]$buf.Clear()
        $chaves = ""
        if ($novo) { $titulo = $novo }
        continue
      }

      if ($linha -match '^\s*chaves\s*:\s*(.+)$') { $chaves = $Matches[1]; continue }
      [void]$buf.AppendLine($linha)
    }
  }
  $script:LivrosIdx  = @($idx)
  $script:LivrosSelo = $selo
}

function RegrasRelevantes($texto, $orcamento) {
  IndexarLivros
  if (-not $script:LivrosIdx -or $script:LivrosIdx.Count -eq 0) { return "" }
  $alvo = SemAcento $texto
  $marcados = New-Object Collections.ArrayList
  foreach ($s in $script:LivrosIdx) {
    $forte = 0
    foreach ($t in $s.termos) { if ($alvo.Contains($t)) { $forte++ } }
    if ($forte -eq 0) { continue }          # sem titulo/chave batendo, a secao nao entra
    $fraco = 0
    foreach ($t in $s.fracos) { if ($alvo.Contains($t)) { $fraco++ } }
    [void]$marcados.Add([pscustomobject]@{ pontos = ($forte * 3 + $fraco); sec = $s })
  }
  if ($marcados.Count -eq 0) { return "" }

  $sel = New-Object Collections.ArrayList
  $usado = 0
  foreach ($m in ($marcados | Sort-Object -Property pontos -Descending)) {
    $b = "**{0}** ({1})`n{2}" -f $m.sec.titulo, $m.sec.livro, $m.sec.corpo
    if ($usado + $b.Length -gt $orcamento) { continue }
    [void]$sel.Add($b)
    $usado += $b.Length
    if ($sel.Count -ge 4) { break }
  }
  if ($sel.Count -eq 0) { return "" }
  "## Do livro do sistema (vale como regra)`n" + ($sel -join "`n`n")
}

function ResumoLivros {
  IndexarLivros
  if (-not $script:LivrosIdx -or $script:LivrosIdx.Count -eq 0) {
    return @"
Nenhum livro indexado ainda.

Coloque arquivos .md ou .txt em:

  campanha\livros\

Pode usar subpastas a vontade:

  campanha\livros\dnd5e\combate.md
  campanha\livros\dnd5e\magias.md
  campanha\livros\meu-cenario\deuses.md

COMO CORTAR O TEXTO
Use titulos com # para marcar as secoes. O Mestre nao le o livro inteiro:
ele puxa so a secao cujas palavras aparecem na conversa. Um manual de 300
paginas nao cabe em 6144 tokens - por isso o corte importa.

  ## Armadilhas
  chaves: armadilha, desarmar, ladino, alcapao, cofre, fio, trava
  Para desarmar, teste Destreza (Ferramentas) contra a CD da armadilha...

A LINHA "chaves:" E O QUE FAZ ISTO FUNCIONAR DE VERDADE
So o titulo nao basta. Ninguem digita "combate" - o jogador escreve
"saco a espada e parto pra cima do orc". Entao ponha em chaves: as palavras
que voce REALMENTE vai dizer jogando: espada, arma, golpe, luta, briga, orc.
Quanto mais generosa a lista, mais o Mestre acerta a hora de usar a regra.

O nome do arquivo e da pasta contam pouco de proposito: se contassem igual,
uma palavra so puxaria o livro inteiro de uma vez e entupiria o contexto.

Arquivo sem nenhum titulo e cortado sozinho em pedacos de ~1200 caracteres.

Salvou um arquivo novo? Ele entra no indice na jogada seguinte, sem reiniciar.

PDF FUNCIONA. Solte o .pdf aqui e ele vira um .pdf.txt do lado, uma vez so.
Da certo com PDF gerado por editor de texto. NAO da certo com PDF escaneado
(pagina que e foto, sem texto por baixo) - ali so com OCR, que nao tem aqui.
Quando nao da, aparece um .pdf.aviso explicando, e nada e indexado: meio livro
em garrancho estraga mais a campanha do que livro nenhum.

O .pdf.txt e um arquivo comum: pode abrir, arrumar o corte e por linhas
"chaves:". Ele so e refeito se voce trocar o PDF.
"@
  }
  $porLivro = @($script:LivrosIdx | Group-Object livro | Sort-Object Name)
  $t = "{0} secoes indexadas, em {1} arquivo(s).`nO Mestre puxa no maximo 4 por jogada - so as citadas.`n`n" -f $script:LivrosIdx.Count, $porLivro.Count
  if ($script:PdfConvertidos.Count -gt 0) {
    $t += "PDF convertido em texto:`n"
    foreach ($n in $script:PdfConvertidos) { $t += "  ok  $n`n" }
    $t += "`n"
  }
  if ($script:PdfFalhos.Count -gt 0) {
    $t += "PDF que NAO deu pra ler:`n"
    foreach ($n in $script:PdfFalhos) { $t += "  !!  $n`n" }
    $t += "`nPra esses, abra no leitor de PDF e use 'Salvar como' texto, ou copie`ne cole o capitulo que interessa num .md aqui.`n`n"
  }
  foreach ($g in $porLivro) {
    $t += "## {0}   ({1} secoes)`n" -f $g.Name, $g.Count
    foreach ($s in $g.Group) { $t += "  - {0}`n" -f $s.titulo }
    $t += "`n"
  }
  $t
}

# ------------------------------------------- aplicar o bloco de atualizacao

# O modelo termina cada resposta com ###FICHA### / ###LORE### / ###DIARIO### / ###FIM###
# O jogador nao ve esse bloco: ele vira escrita nos arquivos da campanha.
function AplicarAtualizacao($bloco) {
  $mudou = New-Object Collections.ArrayList
  if (-not $bloco) { return $mudou }

  $secao = ""
  $ficha = @{}
  $lores = @()
  $diario = @()
  foreach ($l in ($bloco -split "`r?`n")) {
    $t = $l.Trim()
    if ($t -match '^###\s*FICHA\s*###$')  { $secao = "ficha";  continue }
    if ($t -match '^###\s*LORE\s*###$')   { $secao = "lore";   continue }
    if ($t -match '^###\s*DIARIO\s*###$') { $secao = "diario"; continue }
    if ($t -match '^###\s*FIM\s*###$')    { $secao = "";       continue }
    if (-not $t -or $t -eq "-") { continue }
    $t = $t -replace '^[-*]\s*', ''
    if ($t -match '^\(?\s*(nada|vazio|nenhum[ao]?|sem mudanca)\s*\)?\.?$') { continue }
    switch ($secao) {
      "ficha"  { if ($t -match '^([^:]{1,30}):\s*(.+)$') { $ficha[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim() } }
      "lore"   { $lores += $t }
      "diario" { $diario += $t }
    }
  }

  # --- ficha: mescla chave a chave em campanha/02-personagem.md
  if ($ficha.Count -gt 0) {
    $pj  = Join-Path $Campanha "02-personagem.md"
    $txt = Ler $pj
    foreach ($k in $ficha.Keys) {
      $rx   = "(?im)^-\s*" + [Regex]::Escape($k) + "\s*:.*$"
      $nova = ("- {0}: {1}" -f $k, $ficha[$k]).Replace('$', '$$')
      if ($txt -match $rx) {
        $txt = [Regex]::Replace($txt, $rx, $nova)
      } elseif ($txt -match '(?m)^##\s*Ficha\s*$') {
        $txt = [Regex]::Replace($txt, '(?m)^(##\s*Ficha\s*)$', "`$1`n`n$nova", 1)
      } else {
        $txt = $txt.TrimEnd() + "`n" + $nova + "`n"
      }
    }
    Gravar $pj $txt
    [void]$mudou.Add("ficha: " + (($ficha.Keys | Sort-Object) -join ", "))
  }

  # --- lore: "Nome | chave, chave | descricao" -> campanha/lore/nome.md
  foreach ($e in $lores) {
    $p = $e -split '\s*\|\s*'
    if ($p.Count -lt 2) { continue }
    $nome = $p[0].Trim()
    if ($p.Count -ge 3) {
      $chaves = $p[1]
      $desc   = ($p[2..($p.Count - 1)] -join " | ").Trim()
    } else {
      $chaves = $nome
      $desc   = $p[1].Trim()
    }
    if (-not $nome -or -not $desc) { continue }
    $listaCh = (@($nome) + ($chaves -split ',')) | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique

    # a mesma pessoa escrita de outro jeito ("Gorm" vs "Gorm Martelo-Torto") tem que
    # cair no arquivo que ja existe, senao a lore se parte em dois
    $arq = $null
    if (Test-Path -LiteralPath $DirLore) {
      $novasCh = @($listaCh | ForEach-Object { SemAcento $_ })
      foreach ($lf in (Get-ChildItem -LiteralPath $DirLore -Filter *.md -File)) {
        $lc = Ler $lf.FullName
        $mfm = [Regex]::Match($lc, '(?s)^---\s*\r?\n(.*?)\r?\n---')
        if (-not $mfm.Success) { continue }
        $mk = [Regex]::Match($mfm.Groups[1].Value, 'chaves\s*:\s*(.+)')
        if (-not $mk.Success) { continue }
        $velhasCh = @(($mk.Groups[1].Value -split ',') | ForEach-Object { SemAcento $_.Trim() } | Where-Object { $_ })
        $bate = @($velhasCh | Where-Object { $novasCh -contains $_ })
        if ($bate.Count -gt 0) {
          $arq = $lf.FullName
          $listaCh = (@($listaCh) + @(($mk.Groups[1].Value -split ',') | ForEach-Object { $_.Trim() })) | Where-Object { $_ } | Select-Object -Unique
          break
        }
      }
    }
    if (-not $arq) { $arq = Join-Path $DirLore ((Slug $nome) + ".md") }

    $anterior = ""
    if (Test-Path -LiteralPath $arq) {
      $c = Ler $arq
      if ($c -match '(?s)^---.*?\r?\n---\s*\r?\n(.*)$') { $anterior = $Matches[1].Trim() } else { $anterior = $c.Trim() }
      # tira o titulo em negrito (inclusive o de um apelido antigo) pra nao empilhar
      $anterior = [Regex]::Replace($anterior, '(?m)^\*\*[^*\r\n]+\*\*[ \t]*\r?\n?', '')
      $anterior = ((($anterior -split "`r?`n") | Where-Object { $_.Trim() }) -join "`n").Trim()
    }
    # nunca apaga o que ja sabia: so acrescenta se o fato for mesmo novo
    if (-not $anterior) { $corpo = $desc }
    elseif ((SemAcento $anterior).Contains((SemAcento $desc))) { $corpo = $anterior }
    else { $corpo = $anterior + "`n" + $desc }

    Gravar $arq ("---`nchaves: {0}`n---`n**{1}**`n{2}`n" -f (($listaCh -join ", ")), $nome, $corpo)
    [void]$mudou.Add("lore: $nome")
  }

  # --- diario: sempre append, nunca reescreve
  if ($diario.Count -gt 0) {
    $dj  = Join-Path $Campanha "03-diario.md"
    $txt = (Ler $dj).TrimEnd()
    if ($txt -notmatch '(?m)^\s*-\s') { $txt += "`n" }
    $carimbo = Get-Date -Format "dd/MM HH:mm"
    foreach ($d in $diario) { $txt += "`n- [$carimbo] $d" }
    Gravar $dj ($txt + "`n")
    [void]$mudou.Add("diario: " + $diario.Count)
  }

  $mudou
}

# ------------------------------------------------------- montagem do prompt

$FORMATO = @'

# COMO TERMINAR TODA RESPOSTA (obrigatorio)

Depois da narracao, escreva o bloco abaixo. O jogador NAO ve esse bloco: ele grava os
arquivos da campanha. Nunca comente sobre ele. Nunca escreva nada depois do ###FIM###.

###FICHA###
so os campos que MUDARAM nesta jogada, um por linha, formato  campo: valor
(use exatamente os mesmos nomes que ja existem na Ficha do personagem: pv, ouro,
condicoes, nivel, ca, nome, classe, inventario)
###LORE###
so FATO NOVO e permanente do mundo, um por linha, formato:
Nome | palavras-chave separadas por virgula | a frase do fato
(pessoa, lugar, segredo, divida, promessa, inimizade. Nada de acao passageira aqui.)
###DIARIO###
uma unica frase, no passado, resumindo o que de fato aconteceu nesta jogada
###FIM###

Secao sem novidade fica vazia. Nunca invente numero de ficha que o jogador nao
ganhou nem perdeu na cena. Nunca repita na LORE um fato que ja esta escrito.
'@

$MODO_DIRETOR = @'

ATENCAO: a mensagem a seguir NAO e o personagem falando. E o jogador falando com voce
por fora da ficcao, corrigindo alguma coisa. Nao narre resposta pra ela como se fosse
cena. Acate a correcao, ajuste o que precisar nos arquivos pelo bloco do fim, e siga
a cena de onde parou em uma ou duas frases.
'@

function MontarMensagens($entrada, $diretor) {
  $recente = (($Historico | Select-Object -Last 8 | ForEach-Object { $_.texto }) -join " ")
  $lore = LoreRelevante ($recente + " " + $entrada)

  $sistema  = (Ler (Join-Path $Campanha "00-mestre.md")) + "`n`n"
  $sistema += "# O Mundo`n" + (Ler (Join-Path $Campanha "01-mundo.md")) + "`n`n"
  $sistema += "# O personagem do jogador`n" + (Ler (Join-Path $Campanha "02-personagem.md")) + "`n`n"
  if ($lore) { $sistema += $lore + "`n`n" }

  # regras do sistema: so as secoes citadas, com teto de tamanho
  $regras = RegrasRelevantes ($recente + " " + $entrada) 2600
  if ($regras) { $sistema += $regras + "`n`n" }

  # o diario e a memoria longa: entram so as ultimas entradas
  $diario = (((Ler (Join-Path $Campanha "03-diario.md")) -split "`r?`n") | Where-Object { $_ -match '^\s*-\s' } | Select-Object -Last 25) -join "`n"
  if ($diario) { $sistema += "# O que ja aconteceu (do mais antigo pro mais recente)`n$diario`n`n" }

  $sistema += $FORMATO
  if ($diretor) { $sistema += "`n" + $MODO_DIRETOR }

  $msgs = New-Object Collections.ArrayList
  [void]$msgs.Add(@{ role = "system"; content = $sistema })
  foreach ($h in ($Historico | Select-Object -Last $MaxHist)) {
    [void]$msgs.Add(@{ role = [string]$h.papel; content = [string]$h.texto })
  }
  [void]$msgs.Add(@{ role = "user"; content = $entrada })
  , $msgs
}

# ------------------------------------------------------------- HTTP helpers

function Responder($resp, $codigo, $tipo, $corpo) {
  $b = $UTF8.GetBytes([string]$corpo)
  $resp.StatusCode = $codigo
  $resp.ContentType = $tipo
  $resp.ContentLength64 = $b.Length
  $resp.OutputStream.Write($b, 0, $b.Length)
  $resp.OutputStream.Close()
}

function CorpoDe($req) {
  $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
  $t = $sr.ReadToEnd()
  $sr.Close()
  $t
}

# ------------------------------------------------------------------- servir

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Porta/")
$listener.Start()

Write-Host ""
Write-Host "   BRASEIRO" -ForegroundColor DarkYellow
Write-Host "   aberto em http://localhost:$Porta" -ForegroundColor Green
Write-Host "   Modelo:   $($Cfg.modelo)   contexto: $($Cfg.contexto)" -ForegroundColor DarkGray
Write-Host "   Campanha: $NomeCampanha" -ForegroundColor DarkGray
Write-Host "   Gravando em $Campanha" -ForegroundColor DarkGray
Write-Host "   Feche esta janela pra apagar o braseiro." -ForegroundColor DarkGray
Write-Host ""

while ($listener.IsListening) {
  try {
    $ctx  = $listener.GetContext()
    $req  = $ctx.Request
    $resp = $ctx.Response
    $rota = $req.Url.AbsolutePath

    if ($rota -eq "/" -or $rota -eq "/index.html") {
      Responder $resp 200 "text/html; charset=utf-8" (Ler (Join-Path $PSScriptRoot "ui.html"))
    }

    elseif ($rota -eq "/api/estado") {
      $arqs = @()
      foreach ($f in (Get-ChildItem -LiteralPath $Campanha -Filter *.md -File | Sort-Object Name)) {
        $arqs += @{ id = $f.Name; nome = $f.BaseName; texto = (Ler $f.FullName) }
      }
      if (Test-Path -LiteralPath $DirLore) {
        foreach ($f in (Get-ChildItem -LiteralPath $DirLore -Filter *.md -File | Sort-Object Name)) {
          $arqs += @{ id = "lore/" + $f.Name; nome = "lore/" + $f.BaseName; texto = (Ler $f.FullName) }
        }
      }
      $arqs += @{ id = "__livros"; nome = "livros"; texto = (ResumoLivros) }
      $hist = @($Historico | ForEach-Object { @{ papel = [string]$_.papel; texto = [string]$_.texto } })
      Responder $resp 200 "application/json; charset=utf-8" (ConvertTo-Json @{
        arquivos = $arqs; historico = $hist; modelo = $Cfg.modelo
        campanha = $NomeCampanha; campanhas = @(ListarCampanhas); pasta = $Campanha
      } -Depth 6)
    }

    elseif ($rota -eq "/api/campanha") {
      # troca de mesa (cria se ainda nao existir) e grava a escolha no config
      $d = (CorpoDe $req) | ConvertFrom-Json
      $novo = NomeSeguro $d.nome
      AbrirCampanha $novo
      GravarConfig "campanha" $novo
      Responder $resp 200 "application/json; charset=utf-8" (ConvertTo-Json @{
        ok = $true; campanha = $NomeCampanha; campanhas = @(ListarCampanhas); pasta = $Campanha
      } -Depth 4)
    }

    elseif ($rota -eq "/api/livros/soltar") {
      # recebe um arquivo arrastado pra janela e guarda em livros/ da campanha.
      # o corpo e o arquivo cru; o nome vem na query pra nao ter que fazer multipart.
      $nome = [string]$req.QueryString["nome"]
      $nome = Split-Path $nome -Leaf                     # nunca aceita caminho
      $nome = [Regex]::Replace($nome, '[<>:"/\\|?*\x00-\x1F]', '-')
      $ext  = [IO.Path]::GetExtension($nome).ToLowerInvariant()

      if ($nome -match '^\s*$' -or $nome -match '\.\.') {
        Responder $resp 400 "application/json; charset=utf-8" (ConvertTo-Json @{ ok = $false; nome = $nome; erro = "nome invalido" })
      }
      elseif ($ext -notin @(".pdf", ".md", ".markdown", ".txt")) {
        Responder $resp 400 "application/json; charset=utf-8" (ConvertTo-Json @{ ok = $false; nome = $nome; erro = "so aceito .pdf, .md ou .txt" })
      }
      else {
        if (-not (Test-Path -LiteralPath $DirLivros)) { New-Item -ItemType Directory -Path $DirLivros -Force | Out-Null }
        $destino = Join-Path $DirLivros $nome
        # grava direto em disco, sem passar pela memoria: livro grande nao derruba
        $fs = [IO.File]::Create($destino)
        try { $req.InputStream.CopyTo($fs) } finally { $fs.Close() }
        $tam = (Get-Item -LiteralPath $destino).Length

        $r = @{ ok = $true; nome = $nome; bytes = $tam; convertido = $true; motivo = "" }
        if ($ext -eq ".pdf") {
          try { $x = ExtrairTextoPdf $destino } catch { $x = $null }
          if ($null -ne $x -and $x.texto) {
            Gravar ($destino + ".txt") ("<!-- gerado do PDF " + $nome + ". Pode editar a vontade: so e refeito se o PDF mudar. -->`n`n" + $x.texto)
            $av = $destino + ".aviso"
            if (Test-Path -LiteralPath $av) { Remove-Item -LiteralPath $av -Force }
          } else {
            $r.convertido = $false
            $r.motivo = if ($x) { $x.motivo } else { "erro ao ler o arquivo" }
            Gravar ($destino + ".aviso") $r.motivo
          }
        }
        $script:LivrosSelo = $null      # forca reindexar na proxima leitura
        Responder $resp 200 "application/json; charset=utf-8" (ConvertTo-Json $r -Depth 4)
      }
    }

    elseif ($rota -eq "/api/abrir-pasta") {
      Start-Process explorer.exe $Campanha | Out-Null
      Responder $resp 200 "application/json" '{"ok":true}'
    }

    elseif ($rota -eq "/api/salvar") {
      $d  = (CorpoDe $req) | ConvertFrom-Json
      $id = ([string]$d.id) -replace '\\', '/'
      if ($id -match '\.\.' -or $id -notmatch '^(lore/)?[^/]+\.md$') {
        Responder $resp 400 "text/plain; charset=utf-8" "id invalido"
      } else {
        Gravar (Join-Path $Campanha $id) ([string]$d.texto)
        Responder $resp 200 "application/json" '{"ok":true}'
      }
    }

    elseif ($rota -eq "/api/apagar-conversa") {
      $Historico = @()
      SalvarHist
      Responder $resp 200 "application/json" '{"ok":true}'
    }

    elseif ($rota -eq "/api/turno") {
      $d       = (CorpoDe $req) | ConvertFrom-Json
      $entrada = [string]$d.texto
      $diretor = [bool]$d.diretor

      $resp.ContentType = "text/event-stream; charset=utf-8"
      $resp.Headers.Add("Cache-Control", "no-cache")
      $resp.SendChunked = $true
      $sw = New-Object IO.StreamWriter($resp.OutputStream, $UTF8)
      $sw.AutoFlush = $true

      try {
        $msgs = MontarMensagens $entrada $diretor
        $opts = @{
          temperature = [double]$Cfg.temperatura
          num_ctx     = [int]$Cfg.contexto
          top_p       = 0.92
          repeat_penalty = 1.08
        }
        if ($Cfg.camadas_gpu -ne "auto") { $opts["num_gpu"] = [int]$Cfg.camadas_gpu }
        $payload = ConvertTo-Json @{
          model = $Cfg.modelo; messages = @($msgs); stream = $true; options = $opts; keep_alive = "30m"
        } -Depth 8

        $r = [Net.HttpWebRequest]::Create("$Ollama/api/chat")
        $r.Method = "POST"
        $r.ContentType = "application/json"
        $r.Timeout = 900000
        $r.ReadWriteTimeout = 900000
        $pb = $UTF8.GetBytes($payload)
        $r.ContentLength = $pb.Length
        $os = $r.GetRequestStream(); $os.Write($pb, 0, $pb.Length); $os.Close()
        $rd = New-Object IO.StreamReader($r.GetResponse().GetResponseStream(), [Text.Encoding]::UTF8)

        $full = ""; $emitido = 0; $cortado = $false
        while (-not $rd.EndOfStream) {
          $linha = $rd.ReadLine()
          if (-not $linha) { continue }
          try { $j = $linha | ConvertFrom-Json } catch { continue }
          if ($j.message -and $j.message.content) {
            $full += [string]$j.message.content
            if (-not $cortado) {
              $i = $full.IndexOf("###")
              if ($i -ge 0) {
                if ($i -gt $emitido) {
                  $sw.Write("event: texto`ndata: " + (ConvertTo-Json @{ t = $full.Substring($emitido, $i - $emitido) } -Compress) + "`n`n")
                }
                $emitido = $i
                $cortado = $true
              } else {
                # segura os 3 ultimos chars pra nao cortar um "###" no meio
                $seguro = $full.Length - 3
                if ($seguro -gt $emitido) {
                  $sw.Write("event: texto`ndata: " + (ConvertTo-Json @{ t = $full.Substring($emitido, $seguro - $emitido) } -Compress) + "`n`n")
                  $emitido = $seguro
                }
              }
            }
          }
          if ($j.done) { break }
        }
        $rd.Close()
        if (-not $cortado -and $full.Length -gt $emitido) {
          $sw.Write("event: texto`ndata: " + (ConvertTo-Json @{ t = $full.Substring($emitido) } -Compress) + "`n`n")
        }

        $i = $full.IndexOf("###")
        if ($i -ge 0) { $narracao = $full.Substring(0, $i).TrimEnd(); $bloco = $full.Substring($i) }
        else          { $narracao = $full.TrimEnd();                  $bloco = "" }

        $mudou = AplicarAtualizacao $bloco

        $Historico += @{ papel = "user";      texto = $entrada }
        $Historico += @{ papel = "assistant"; texto = $narracao }
        if ($Historico.Count -gt 120) { $Historico = @($Historico | Select-Object -Last 120) }
        SalvarHist

        $sw.Write("event: fim`ndata: " + (ConvertTo-Json @{ mudou = @($mudou) } -Compress -Depth 3) + "`n`n")
      }
      catch {
        $m = $_.Exception.Message
        if ($m -match 'refus|conect|connect|remoto|remote') {
          $m = "Nao consegui falar com o Ollama. Ele terminou de carregar o modelo? Olhe a outra janela preta."
        }
        try { $sw.Write("event: erro`ndata: " + (ConvertTo-Json @{ msg = $m } -Compress) + "`n`n") } catch {}
      }
      finally { try { $sw.Close() } catch {} }
    }

    else { Responder $resp 404 "text/plain; charset=utf-8" "nao existe" }
  }
  catch {
    Write-Host ("   erro: " + $_.Exception.Message) -ForegroundColor DarkRed
  }
}
