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

# Onde comeca o bloco de memoria. Exige o marcador INTEIRO (###FICHA###), nao
# so "###": o modelo escreve "### Titulo" como cabecalho markdown no meio da
# narracao, e cortar no "###" solto jogava a cena inteira fora.
$RX_BLOCO = New-Object Regex('###\s*(FICHA|LORE|MUNDO|DIARIO|APAGAR|FIM)\s*###', 'IgnoreCase')
$RESERVA_BLOCO = 14   # chars segurados no streaming pra nao partir o marcador

# Onde a resposta tem que acabar: o bloco de memoria OU a linha de devolver a
# vez pro jogador, o que vier primeiro. Depois do fecho o modelo so consegue
# errar - e o erro que ele comete ali e justamente jogar pelo jogador.
function AcharFecho([string]$t) {
  $a = AcharBloco $t
  $b = $t.IndexOf('Mestre: o que', [StringComparison]::OrdinalIgnoreCase)
  if ($a -lt 0) { return $b }
  if ($b -lt 0) { return $a }
  [Math]::Min($a, $b)
}

function AcharBloco([string]$t) {
  $m = $RX_BLOCO.Match($t)
  if ($m.Success) { $m.Index } else { -1 }
}

# O modelo repete a mesma frase cortada em tamanhos diferentes. Comparacao
# exata deixa passar, e prefixo de tamanho fixo tambem. Entao: e repetido se
# um for comeco do outro, nos dois sentidos.
function EhRepetido([string]$novo, $lista) {
  $a = SemAcento $novo
  if ($a.Length -lt 12) { return $false }
  foreach ($v in $lista) {
    $b = SemAcento $v
    if ($b.Length -lt 12) { continue }
    $n = [Math]::Min($a.Length, $b.Length)
    if ($n -ge 25 -and $a.Substring(0, $n) -eq $b.Substring(0, $n)) { return $true }
  }
  $false
}

# O modelo as vezes ecoa os rotulos do proprio prompt ("PARTE 1 - A CENA").
# Isso e andaime da instrucao, nao narracao: sai antes de chegar na tela.
# Com toda fala levando o nome na frente ("Alysa- sai da frente"), a regra de
# nao falar pelo jogador deixa de depender da memoria do modelo e vira coisa que
# eu checo aqui: linha que comeca com o nome dele nao passa.
# Tira da narracao tudo que o Mestre poe na conta do personagem do jogador:
# fala prefixada com o nome dele, e frase em terceira pessoa ("Liam ergue a"
# arma"). Vive separado porque roda DUAS vezes - no texto final e, mais
# importante, em cada pedaco antes de sair pela rede. Antes o servidor
# transmitia cru e so limpava depois: dava certo no arquivo e errado na tela.
# So as letras, pra comparar duas falas sem tropecar em acento e pontuacao.
function _chaveFala([string]$s) {
  ((SemAcento $s).ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function CortarJogador([string]$t, [string]$nomeJogador, [bool]$avisar, [string]$entrada) {
  if (-not $t -or -not $nomeJogador) { return $t }
  $primeiro = ($nomeJogador -split '\s+')[0]
  if ($primeiro.Length -lt 3) { return $t }
  $rx = '(?im)^[\s<\[(*_"''\u201C]*' + [Regex]::Escape($primeiro) + '[^\r\n]{0,24}?[>\])*_"'']*\s*[-–—:]\s*.*$'
  $cortadas = ([Regex]::Matches($t, $rx)).Count
  if ($cortadas -gt 0) {
    $t = [Regex]::Replace($t, $rx, '')
    if ($avisar) { Write-Host ("   cortei " + $cortadas + " fala(s) posta(s) na boca do jogador") -ForegroundColor DarkYellow }
  }
  $linhas = New-Object Collections.ArrayList
  $tirei = 0
  foreach ($ln in ($t -split "`r?`n")) {
    if ($ln -match '^\s*[^\s-]{2,20}\s*[-–—]\s*\S') { [void]$linhas.Add($ln); continue }
    $fica = New-Object Collections.ArrayList
    foreach ($fr in [Regex]::Split($ln, '(?<=[.!?])\s+')) {
      # O nome pode estar no meio da frase e ainda assim ser o Mestre jogando
      # por ele: '"Para", diz Liam.' Dentro de aspas e outra coisa - um NPC
      # chamando o jogador pelo nome pode e deve acontecer. Entao a decisao e
      # tomada sobre a frase SEM as partes entre aspas.
      # O modelo as vezes poe a fala do JOGADOR na boca de um NPC - a mulher
      # perguntando de volta o que voce acabou de perguntar. Se o que esta
      # entre aspas e a sua propria jogada, a frase inteira cai.
      if ($entrada) {
        $kEnt = _chaveFala $entrada
        if ($kEnt.Length -ge 8) {
          $eco = $false
          foreach ($asp in [Regex]::Matches($fr, '["\u201C][^"\u201C\u201D]{4,}["\u201D]')) {
            $kA = _chaveFala $asp.Value
            if ($kA.Length -ge 8 -and ($kEnt.Contains($kA) -or $kA.Contains($kEnt))) { $eco = $true; break }
          }
          if ($eco) { $tirei++; continue }
        }
      }
      $semFala = [Regex]::Replace($fr, '["\u201C\u201D][^"\u201C\u201D]*["\u201C\u201D]', ' ')
      if ($semFala -match ('(?i)\b' + [Regex]::Escape($primeiro) + '\b')) { $tirei++; continue }
      [void]$fica.Add($fr)
    }
    $sobrou = ($fica -join ' ').Trim()
    if ($sobrou -or -not $ln.Trim()) { [void]$linhas.Add($sobrou) }
  }
  if ($tirei -gt 0) {
    $t = ($linhas -join "`n")
    if ($avisar) { Write-Host ("   cortei " + $tirei + " frase(s) narrando o personagem do jogador") -ForegroundColor DarkYellow }
  }
  $t
}

# Ate onde da pra transmitir sem cortar uma frase pela metade. Sem isso o
# filtro veria "Liam erg" e deixaria passar, porque a frase ainda nao acabou.
function UltimaFronteira([string]$s, [int]$ate) {
  if ($ate -le 0) { return 0 }
  if ($ate -gt $s.Length) { $ate = $s.Length }
  for ($k = $ate - 1; $k -ge 0; $k--) {
    $c = $s[$k]
    if ($c -eq "`n") { return $k + 1 }
    if (($c -eq '.' -or $c -eq '!' -or $c -eq '?') -and (($k + 1) -ge $s.Length -or $s[$k + 1] -match '\s')) { return $k + 1 }
  }
  0
}

function LimparNarracao([string]$t, [string]$nomeJogador, [string]$entrada) {
  if (-not $t) { return "" }
  $t = CortarJogador $t $nomeJogador $true $entrada
  if ($nomeJogador) {
    $ix = $t.IndexOf('Mestre: o que', [StringComparison]::OrdinalIgnoreCase)
    if ($ix -ge 0) { $t = $t.Substring(0, $ix) }
    $t = [Regex]::Replace($t.TrimEnd(), "`r?`n{3,}", "`n`n")
    $t = $t + "`n`nMestre: o que " + (($nomeJogador -split '\s+')[0]) + " diz ou faz?"
  }
  $t = [Regex]::Replace($t, '(?im)^\s*(#{1,4}\s*)?PARTE\s*\d+\s*[-–:]?\s*(A\s+CENA|O\s+BLOCO.*|BLOCO.*)?\s*$', '')
  $t = [Regex]::Replace($t, '(?im)^\s*(#{1,4}\s*)?(A\s+CENA|NARRACAO|NARRAÇÃO)\s*:?\s*$', '')
  $t = [Regex]::Replace($t, '(?im)^\s*-{3,}\s*(fim do )?exemplo.*$', '')
  # o corte por fronteira de frase as vezes junta \"direcao.Alysa\" sem espaco
  $t = [Regex]::Replace($t, '(?<=[.!?])(?=[A-Z\u00C0-\u00DA\u201C"])', ' ')
  $t = [Regex]::Replace($t, "`r?`n{3,}", "`n`n")
  $t.Trim()
}

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
  $script:DirCriaturas = Join-Path $script:Campanha "criaturas"
  $script:DirAliados   = Join-Path $script:Campanha "aliados"
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
function CarregarLore {
  $itens = New-Object Collections.ArrayList
  if (-not (Test-Path -LiteralPath $DirLore)) { return $itens }
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
    [void]$itens.Add([pscustomobject]@{
      arquivo = $f.Name
      base    = SemAcento $f.BaseName
      chaves  = @($chaves)
      corpo   = $corpo.Trim()
    })
  }
  , $itens
}

$TETO_LORE = 10

# Duas etapas. Primeiro as entradas cuja chave foi citada na conversa. Depois UM
# salto pelos [[wikilinks]] que essas entradas contem - e o que faz o irmao do
# Gorm chegar junto com o Gorm, sem ninguem ter citado o irmao. Sem esse salto a
# lore fica plana e o modelo reinventa parentesco a cada sessao.
function LoreRelevante($texto) {
  $todos = CarregarLore
  if ($todos.Count -eq 0) { return "" }
  $alvo = SemAcento $texto

  $diretas = New-Object Collections.ArrayList
  $vistos  = New-Object Collections.Generic.HashSet[string]

  foreach ($i in $todos) {
    foreach ($k in $i.chaves) {
      if ($k.Length -ge 3 -and $alvo.Contains($k)) {
        if ($vistos.Add($i.arquivo)) { [void]$diretas.Add($i) }
        break
      }
    }
  }
  if ($diretas.Count -eq 0) { return "" }

  $ligadas = New-Object Collections.ArrayList

  # ida: [[Nome]] ou [[Nome|apelido]] dentro das entradas citadas
  $alvosLink = New-Object Collections.ArrayList
  foreach ($i in $diretas) {
    foreach ($m in [Regex]::Matches($i.corpo, '\[\[([^\]\|]+?)(?:\|[^\]]*)?\]\]')) {
      [void]$alvosLink.Add((SemAcento $m.Groups[1].Value.Trim()))
    }
  }
  foreach ($l in (@($alvosLink) | Select-Object -Unique)) {
    if (-not $l -or ($diretas.Count + $ligadas.Count) -ge $TETO_LORE) { break }
    foreach ($i in $todos) {
      if ($vistos.Contains($i.arquivo)) { continue }
      if ($i.base -eq $l -or ($i.chaves -contains $l)) {
        [void]$vistos.Add($i.arquivo)
        [void]$ligadas.Add($i)
        break
      }
    }
  }

  # volta (backlink): quem aponta PRA elas. E o que faz "a prima do Gorm" aparecer
  # quando so o Gorm foi citado - o parentesco costuma estar escrito so de um lado.
  $nomesDiretos = New-Object Collections.ArrayList
  foreach ($i in $diretas) {
    [void]$nomesDiretos.Add($i.base)
    foreach ($k in $i.chaves) { if ($k.Length -ge 3) { [void]$nomesDiretos.Add($k) } }
  }
  $nomesDiretos = @($nomesDiretos | Select-Object -Unique)
  foreach ($i in $todos) {
    if (($diretas.Count + $ligadas.Count) -ge $TETO_LORE) { break }
    if ($vistos.Contains($i.arquivo)) { continue }
    $aponta = $false
    foreach ($m in [Regex]::Matches($i.corpo, '\[\[([^\]\|]+?)(?:\|[^\]]*)?\]\]')) {
      if ($nomesDiretos -contains (SemAcento $m.Groups[1].Value.Trim())) { $aponta = $true; break }
    }
    if ($aponta) {
      [void]$vistos.Add($i.arquivo)
      [void]$ligadas.Add($i)
    }
  }

  $t = "## Fatos relevantes agora`n" + ((@($diretas | Select-Object -First $TETO_LORE) | ForEach-Object { $_.corpo }) -join "`n`n")
  if ($ligadas.Count -gt 0) {
    $t += "`n`n### Ligados a eles (nao foram citados, mas importam)`n" + ((@($ligadas) | ForEach-Object { $_.corpo }) -join "`n`n")
  }
  $t
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
function AplicarAtualizacao($bloco, $podeApagar) {
  $mudou = New-Object Collections.ArrayList
  if (-not $bloco) { return $mudou }

  $secao = ""
  $ficha = @{}
  $lores = @()
  $mundo = @()
  $apagar = @()
  $diario = @()
  foreach ($l in ($bloco -split "`r?`n")) {
    $t = $l.Trim()
    if ($t -match '^###\s*FICHA\s*###$')  { $secao = "ficha";  continue }
    if ($t -match '^###\s*LORE\s*###$')   { $secao = "lore";   continue }
    if ($t -match '^###\s*MUNDO\s*###$')  { $secao = "mundo";  continue }
    if ($t -match '^###\s*APAGAR\s*###$') { $secao = "apagar"; continue }
    if ($t -match '^###\s*DIARIO\s*###$') { $secao = "diario"; continue }
    if ($t -match '^###\s*FIM\s*###$')    { $secao = "";       continue }
    if (-not $t -or $t -eq "-") { continue }
    $t = $t -replace '^[-*]\s*', ''
    if ($t -match '^\(?\s*(nada|vazio|nenhum[ao]?|sem mudanca)\s*\)?\.?$') { continue }
    # o modelo as vezes copia a propria linha de exemplo do formato. nao vira lore.
    if ($t -match '(?i)palavras-chave separadas|a frase do fato|so os campos que|so FATO NOVO|uma unica frase') { continue }
    if ($t -match '(?i)^nome\s*\|') { continue }
    if ($t -match '^\s*\(') { continue }
    switch ($secao) {
      "ficha"  { if ($t -match '^([^:]{1,30}):\s*(.+)$') { $ficha[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim() } }
      "lore"   { $lores += $t }
      "mundo"  { $mundo += $t }
      "apagar" { $apagar += $t }
      "diario" { $diario += $t }
    }
  }

  # --- APAGAR: o retcon. Quando o jogador corrige, o erro tem que SAIR dos
  # arquivos, nao ficar empilhado embaixo da correcao. Sem isso a mentira
  # continua sendo lida como verdade em toda jogada seguinte.
  # APAGAR so quando o JOGADOR corrigiu (modo diretor). Sem essa trava o
  # anotador apagava lore por conta propria - e apagou a do Gorm num teste.
  # Retcon e ordem do jogador, nunca iniciativa do modelo.
  if (-not $podeApagar -and $apagar.Count -gt 0) {
    Write-Host ("   ignorei " + $apagar.Count + " pedido(s) de APAGAR fora do modo diretor") -ForegroundColor DarkYellow
    $apagar = @()
  }
  foreach ($a in $apagar) {
    if ($a -notmatch '^\s*(lore|diario|mundo)\s*:\s*(.+)$') { continue }
    $tipo = $Matches[1].ToLowerInvariant()
    $alvo = $Matches[2].Trim()
    if ($alvo.Length -lt 3) { continue }
    $chave = SemAcento $alvo

    if ($tipo -eq "lore") {
      foreach ($lf in @(Get-ChildItem -LiteralPath $DirLore -Filter *.md -File -ErrorAction SilentlyContinue)) {
        $c = Ler $lf.FullName
        $bate = (SemAcento $lf.BaseName) -eq (Slug $alvo) -or (SemAcento $lf.BaseName).Contains($chave)
        if (-not $bate) {
          $mk = [Regex]::Match($c, 'chaves\s*:\s*(.+)')
          if ($mk.Success) {
            $ks = @(($mk.Groups[1].Value -split ',') | ForEach-Object { SemAcento $_.Trim() })
            if ($ks -contains $chave) { $bate = $true }
          }
        }
        if ($bate) {
          Remove-Item -LiteralPath $lf.FullName -Force
          [void]$mudou.Add("APAGUEI lore: " + $lf.BaseName)
        }
      }
    }
    else {
      $arq = if ($tipo -eq "diario") { Join-Path $Campanha "03-diario.md" } else { Join-Path $Campanha "04-mundo.md" }
      $txt = Ler $arq
      if (-not $txt) { continue }
      $fora = 0
      $novas = @()
      foreach ($l in ($txt -split "`r?`n")) {
        if ($l -match '^\s*-\s' -and (SemAcento $l).Contains($chave)) { $fora++; continue }
        $novas += $l
      }
      if ($fora -gt 0) {
        Gravar $arq (($novas -join "`n").TrimEnd() + "`n")
        [void]$mudou.Add("APAGUEI $tipo`: $fora linha(s)")
      }
    }
  }

  # --- ficha: mescla chave a chave em campanha/02-personagem.md
  # SO campo que ja existe na ficha. O modelo copiava numero do exemplo do
  # prompt ("ouro: 3 po") e inventava campo ("classe: 1") em ficha que nem
  # tinha classe. Quem define a ficha e o jogador, nao o modelo.
  if ($ficha.Count -gt 0) {
    $pj  = Join-Path $Campanha "02-personagem.md"
    $txt = Ler $pj
    $atual = @{}
    foreach ($m in [Regex]::Matches($txt, '(?m)^-\s*([^:\r\n]{1,30})\s*:\s*(.*)$')) {
      $atual[$m.Groups[1].Value.Trim().ToLowerInvariant()] = $m.Groups[2].Value.Trim()
    }
    $recusados = @()
    foreach ($k in @($ficha.Keys)) {
      # campo inexistente na ficha, ou com o mesmo valor de antes, nao e mudanca.
      # O anotador vinha devolvendo a ficha inteira e sujando o "gravou:".
      if (-not $atual.ContainsKey($k)) { $ficha.Remove($k); $recusados += $k; continue }
      if ((SemAcento $atual[$k]) -eq (SemAcento $ficha[$k])) { $ficha.Remove($k) }
    }
    if ($recusados.Count -gt 0) { Write-Host ("   ficha: ignorei campo inexistente -> " + ($recusados -join ", ")) -ForegroundColor DarkGray }
  }
  if ($ficha.Count -gt 0) {
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

  # --- mundo: o que aconteceu LONGE do jogador. E o que faz a campanha
  # continuar existindo quando ele nao esta olhando.
  if ($mundo.Count -gt 0) {
    $mj = Join-Path $Campanha "04-mundo.md"
    $txt = (Ler $mj).TrimEnd()
    if (-not $txt) { $txt = "# O mundo enquanto voce nao olha`n`n> Escrito pelo Mestre. Cada linha e algo que aconteceu sem o jogador presente." }
    $recentes = @(($txt -split "`r?`n") | Where-Object { $_ -match '^\s*-\s' } |
                  Select-Object -Last 6 | ForEach-Object { $_ -replace '^\s*-\s*\[[^\]]*\]\s*','' })
    $carimbo = Get-Date -Format "dd/MM HH:mm"
    $novos = 0
    foreach ($m in $mundo) {
      if (EhRepetido $m $recentes) { continue }
      $txt += "`n- [$carimbo] $m"
      $recentes += $m
      $novos++
    }
    Gravar $mj ($txt + "`n")
    if ($novos -gt 0) { [void]$mudou.Add("mundo: " + $novos) }
  }

  # --- diario: sempre append, nunca reescreve
  if ($diario.Count -gt 0) {
    $dj  = Join-Path $Campanha "03-diario.md"
    $txt = (Ler $dj).TrimEnd()
    if ($txt -notmatch '(?m)^\s*-\s') { $txt += "`n" }
    $carimbo = Get-Date -Format "dd/MM HH:mm"
    # o modelo repete a ultima linha com frequencia. entrada igual a alguma das
    # 5 ultimas nao entra: diario com a mesma frase tres vezes nao lembra nada.
    $recentes = @(($txt -split "`r?`n") | Where-Object { $_ -match '^\s*-\s' } |
                  Select-Object -Last 5 | ForEach-Object { $_ -replace '^\s*-\s*\[[^\]]*\]\s*','' })
    $novas = 0
    foreach ($d in $diario) {
      if (EhRepetido $d $recentes) { continue }
      $txt += "`n- [$carimbo] $d"
      $recentes += $d
      $novas++
    }
    Gravar $dj ($txt + "`n")
    if ($novas -gt 0) { [void]$mudou.Add("diario: " + $novas) }
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
Write-Host "   Pra fechar: o botao 'apagar o braseiro' na tela, ou feche esta janela." -ForegroundColor DarkGray
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

    # Sair de verdade: o que come RAM nao e este servidor (uns 60 MB), e o
    # modelo carregado dentro do Ollama - 3,3 GB parados ate o keep_alive
    # vencer. Entao antes de fechar a gente manda descarregar e derruba o motor.
    elseif ($rota -eq "/api/sair") {
      Responder $resp 200 "application/json" '{"ok":true}'
      Write-Host "" 
      Write-Host "   apagando o braseiro..." -ForegroundColor DarkYellow
      try {
        $corpo = ConvertTo-Json @{ model = $Cfg.modelo; keep_alive = 0 } -Compress
        $rq = [Net.HttpWebRequest]::Create("$Ollama/api/generate")
        $rq.Method = "POST"; $rq.ContentType = "application/json"; $rq.Timeout = 10000
        $bb = $UTF8.GetBytes($corpo); $rq.ContentLength = $bb.Length
        $st = $rq.GetRequestStream(); $st.Write($bb, 0, $bb.Length); $st.Close()
        $rq.GetResponse().Close()
        Write-Host "   modelo descarregado da memoria" -ForegroundColor DarkGray
      } catch { Write-Host "   (o motor ja estava fora)" -ForegroundColor DarkGray }
      foreach ($pr in @(Get-Process ollama -ErrorAction SilentlyContinue)) {
        try { $pr.Kill(); Write-Host "   motor encerrado" -ForegroundColor DarkGray } catch {}
      }
      try { $listener.Stop() } catch {}
      break
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

        $nomeJog = if ((Ler (Join-Path $Campanha '02-personagem.md')) -match '(?im)^\s*-\s*nome\s*:\s*(.+)$') { $Matches[1].Trim() } else { '' }
        $full = ""; $emitido = 0; $cortado = $false
        while (-not $rd.EndOfStream) {
          $linha = $rd.ReadLine()
          if (-not $linha) { continue }
          try { $j = $linha | ConvertFrom-Json } catch { continue }
          if ($j.message -and $j.message.content) {
            $full += [string]$j.message.content
            if (-not $cortado) {
              $i = AcharFecho $full
              if ($i -ge 0) {
                if ($i -gt $emitido) {
                  $pedaco = CortarJogador ($full.Substring($emitido, $i - $emitido)) $nomeJog $false $entrada
                  if ($pedaco.Trim()) { $sw.Write("event: texto`ndata: " + (ConvertTo-Json @{ t = $pedaco } -Compress) + "`n`n") }
                }
                $emitido = $i
                $cortado = $true
              } else {
                # segura o fim pra nao partir "###FICHA###" entre dois chunks
                # so ate o fim da ultima frase inteira: o filtro precisa da frase
                # completa pra decidir, e o jogador nao pode ver o que vai sumir.
                $seguro = UltimaFronteira $full ($full.Length - $RESERVA_BLOCO)
                if ($seguro -gt $emitido) {
                  $pedaco = CortarJogador ($full.Substring($emitido, $seguro - $emitido)) $nomeJog $false $entrada
                  if ($pedaco.Trim()) { $sw.Write("event: texto`ndata: " + (ConvertTo-Json @{ t = $pedaco } -Compress) + "`n`n") }
                  $emitido = $seguro
                }
              }
            }
          }
          if ($j.done) { break }
        }
        $rd.Close()
        if (-not $cortado -and $full.Length -gt $emitido) {
          $pedaco = CortarJogador ($full.Substring($emitido)) $nomeJog $false $entrada
          if ($pedaco.Trim()) { $sw.Write("event: texto`ndata: " + (ConvertTo-Json @{ t = $pedaco } -Compress) + "`n`n") }
        }
        # a vez volta pro jogador SEMPRE, escrita pelo servidor. Se o modelo
        # esqueceu, ela aparece do mesmo jeito; se ele escreveu, foi cortada
        # acima e esta e a unica que sobra.
        if ($nomeJog) {
          $fecho = "`n`nMestre: o que " + (($nomeJog -split '\s+')[0]) + " diz ou faz?"
          $sw.Write("event: texto`ndata: " + (ConvertTo-Json @{ t = $fecho } -Compress) + "`n`n")
        }

        # A narracao e tudo. Se o modelo ainda assim cuspir um bloco, corta.
        $i = AcharBloco $full
        $narracao = if ($i -ge 0) { LimparNarracao $full.Substring(0, $i) $nomeJog $entrada } else { LimparNarracao $full $nomeJog $entrada }

        # Segunda chamada, so pra anotar. O jogador ja esta lendo a cena.
        $sw.Write("event: anotando`ndata: {}`n`n")
        # 3 de 3: anotar
        $bloco = PedirBloco $narracao
        $mudou = AplicarAtualizacao $bloco $diretor

        $Historico += @{ papel = "user";      texto = $entrada }
        # guarda o bloco separado: a tela nunca ve, mas ele volta pro modelo
        # nas duas ultimas respostas, como exemplo do formato certo
        $Historico += @{ papel = "assistant"; texto = $narracao; bloco = $bloco }
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
