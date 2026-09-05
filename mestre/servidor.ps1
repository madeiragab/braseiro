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
  # Antes de /iniciar campanha o Mestre e so um chat: da pra montar personagem,
  # combinar tom e tirar duvida sem gastar dado nem escrever no diario.
  $script:ArqInicio = Join-Path $script:Campanha ".iniciada"
  $script:Iniciada  = Test-Path -LiteralPath $script:ArqInicio
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
===================== SUA RESPOSTA =====================

Duas partes, sempre, nesta ordem.

1) A CENA. Comece direto pela narracao, sem titulo e sem "##".
   Frases curtas, em batidas. Uma ideia por linha.
   Fala de NPC entre aspas, com a reacao dele: quem esta com raiva soa com
   raiva, quem deve favor hesita, quem foi traido cobra.
   Termine com o que o jogador percebe agora.

2) O BLOCO, logo depois, sem comentario. O jogador nao ve. Obrigatorio em
   toda resposta, mesmo vazio.

###FICHA###
campo: valor  (so campo que JA EXISTE na ficha, so o que mudou nesta cena)
###LORE###
Nome | chaves | o fato novo. Use [[Nome]] pra ligar a quem ja existe.
###MUNDO###
o que andou longe do jogador. Quase sempre vazio.
###DIARIO###
uma frase, no passado, do que aconteceu agora.
###FIM###

=================== NAO INVENTE CANONE ===================

Se um nome, lugar, data ou fato NAO esta no material de consulta, voce nao
sabe. Nao escolha um. Diga, com o rotulo Mestre:, que aquilo ainda nao esta
registrado, e pergunte ao jogador ou deixe vago na narracao.

  Mestre: o nome desse capanga ainda nao esta registrado. Quer batizar ele,
  ou sigo como "o da cicatriz"?

Inventar vira canone errado, e duas cenas depois a historia nao fecha.
Use o rotulo Mestre: sempre que precisar falar fora da ficcao - duvida,
regra, ou aviso. Fora isso, so narracao.

--- exemplo curto do formato ---
O carregador fecha a porta com o ombro.

[Atletismo: 7 + 2 = 9 vs 15 -> falha, a porta bate no seu ombro]

A madeira range. "Sai daqui", ele rosna do outro lado, sem forca na voz.
Passos vem do beco.
###FICHA###
pv: 21/24
###LORE###
Marta Cinza | marta, taverneira | Dona da taverna em [[Vallengard]]. Quer comprar o armazem do vizinho.
###MUNDO###
###DIARIO###
O grupo travou a porta do armazem e ouviu passos no beco.
###FIM###
--- fim ---
'@

$MODO_DIRETOR = @'
ATENCAO: a mensagem a seguir NAO e o personagem falando. E o jogador falando
com voce por fora da ficcao, corrigindo alguma coisa.

Nao narre cena pra ela. Acate a correcao, responda curto com o rotulo Mestre:,
e siga de onde parou em uma ou duas frases.

Se voce escreveu algo errado nos arquivos, DESFACA. Use a secao ###APAGAR###
do bloco, uma linha por item:

  lore: Nome da entrada que estava errada
  diario: um trecho da frase que deve sair
  mundo: um trecho do evento que deve sair

Depois grave a versao certa em ###LORE### ou ###DIARIO### normalmente.
Apagar e reescrever e melhor que empilhar correcao em cima do erro.
'@

function MontarMensagens($entrada, $diretor, $mecanica) {
  $recente = (($Historico | Select-Object -Last 8 | ForEach-Object { $_.texto }) -join " ")
  $lore = LoreRelevante ($recente + " " + $entrada)

  # Detecta cena de risco pelo que foi dito. Serve pra duas coisas: mandar o
  # Mestre rolar, e ALIMENTAR A BUSCA nos livros. O jogador escreve "saco a
  # lanca e parto pra cima" - nenhuma palavra dessa frase e "iniciativa", entao
  # a secao de iniciativa existia no indice e nunca era encontrada.
  $chaveiro = SemAcento ($recente + " " + $entrada)
  $emRisco = $chaveiro -match 'atac|ataqu|lanca|espada|adaga|escudo|golpe|briga|luta|combat|cerca|agarr|derrub|empurr|esquiv|furtiv|escond|arromb|escal|salt|convenc|intimid|persuad|resist|veneno|armadilh|queda|fug'
  $buscaLivros = $recente + " " + $entrada
  if ($emRisco) {
    $buscaLivros += " iniciativa surpresa combate ataque ataques dano critico turno acao rolagem teste dificuldade condicoes defesa"
  }

  # ORDEM IMPORTA. O material de consulta vai no MEIO, cercado, e a ordem do que
  # fazer vem por ultimo. Quando os documentos ficavam soltos com titulos markdown,
  # o modelo reconhecia o formato e CONTINUAVA o documento em vez de narrar -
  # devolvia o cenario reescrito no lugar da cena.
  $sistema = (Ler (Join-Path $Campanha "00-mestre.md")).Trim() + "`n`n"

  $consulta = ""
  $consulta += "[MUNDO]`n" + (Ler (Join-Path $Campanha "01-mundo.md")).Trim() + "`n`n"
  $consulta += "[FICHA DO JOGADOR]`n" + (Ler (Join-Path $Campanha "02-personagem.md")).Trim() + "`n`n"
  if ($lore) { $consulta += "[LORE]`n" + $lore.Trim() + "`n`n" }

  $regras = RegrasRelevantes $buscaLivros 2400
  if ($regras) { $consulta += "[REGRAS]`n" + $regras.Trim() + "`n`n" }

  $diario = (((Ler (Join-Path $Campanha "03-diario.md")) -split "`r?`n") | Where-Object { $_ -match '^\s*-\s' } | Select-Object -Last 22) -join "`n"
  if ($diario) { $consulta += "[O QUE JA ACONTECEU]`n" + $diario.Trim() + "`n`n" }

  $mundo = (((Ler (Join-Path $Campanha "04-mundo.md")) -split "`r?`n") | Where-Object { $_ -match '^\s*-\s' } | Select-Object -Last 12) -join "`n"
  if ($mundo) { $consulta += "[O QUE ANDOU SEM O JOGADOR]`n" + $mundo.Trim() + "`n`n" }

  $sistema += @"
================== INICIO DO MATERIAL DE CONSULTA ==================
Isto e a sua ficha de anotacoes. Serve pra voce SABER as coisas.
Nao e um texto pra continuar, completar, reescrever nem repetir.
NUNCA devolva nenhuma parte disto na sua resposta.
--------------------------------------------------------------------

$($consulta.TrimEnd())

--------------------------------------------------------------------
=================== FIM DO MATERIAL DE CONSULTA ====================

"@

  if ($diretor) { $sistema += $MODO_DIRETOR + "`n" }

  # BRIGA. Um modelo pequeno narra combate como ficcao pura: ninguem rola nada,
  # ninguem tem numero. Quando a cena vira briga, a ordem de rolar tem que ser
  # explicita e estar perto do fim do prompt, senao ele so descreve.
  # Se a calculadora ja resolveu, o narrador nao rola nada: so descreve.
  if ($emRisco -and -not $mecanica) {
    $dados = $script:DadosDaVez
    $sistema += @'

## TEM RISCO NESTA CENA

Voce NAO sabe rolar dado. Entao eu rolei por voce. Estes sao os resultados de
1d20 desta cena, ja sorteados, em ordem:

  __DADOS__

Use um por rolagem, NA ORDEM, sem pular e sem trocar. Se precisar de mais,
peca ao jogador pra rolar.

Formato da linha, entre colchetes:
  [nome da pericia ou defesa: DADO + modificador da ficha = total vs alvo -> resultado]

O dado e o numero que eu te dei. O modificador vem da ficha. O alvo vem das
regras do material. Se o total nao alcanca o alvo, FALHA - e falha e bom,
narre a consequencia ruim. Cena de risco onde tudo da certo e cena sem risco.

Comecou briga? A primeira rolagem e a iniciativa de cada participante, uma
linha por criatura, e depois a ordem de acao. Ataque enfrenta a defesa que as
regras do material mandam, com o nome que elas usam.

'@
    $sistema = $sistema.Replace('__DADOS__', $dados)
  }
  if ($mecanica) {
    $sistema += "`n## JA RESOLVIDO NOS DADOS`nO juiz da mesa ja rolou tudo. Isto ACONTECEU:`n`n" + $mecanica + "`n`nNarre exatamente este resultado. Nao mude numero, nao mude quem acertou ou`nfalhou, nao invente rolagem nova. Mostre as linhas entre colchetes na cena.`n"
  }

  # O RELOGIO. Um modelo pequeno nunca toma a iniciativa de mexer no mundo
  # sozinho: ele so reage ao jogador. Entao de tempos em tempos a gente MANDA.
  # Sem isso os NPCs ficam congelados esperando ser citados.
  $jogadas = [math]::Floor($Historico.Count / 2)
  if (-not $diretor -and $jogadas -ge 2 -and ($jogadas % 3) -eq 0) {
    $sistema += @'

## O MUNDO ANDOU
Escolha UM NPC que ja existe e tinha algo pendente, e faca a agenda dele andar
longe do jogador: cobrou a divida, quebrou a promessa, mudou de lado, sumiu.
Nao invente gente nova.

O jogador nao viu. Ele descobre pelo rastro - porta fechada, comentario de
terceiro, lugar diferente. Narre o que ele ENCONTRA, nao a cena que passou.
Anote no ###MUNDO###.

'@
  }

  # O FORMATO fica por ULTIMO, de proposito. Numa versao anterior o prompt
  # terminava com "responda APENAS com a cena" e o modelo obedecia ao pe da
  # letra: narrava bem e nunca escrevia o bloco de memoria. O que vem por
  # ultimo pesa mais, entao o que vem por ultimo tem que ser a resposta inteira.
  # O FORMATO do bloco NAO entra aqui. Narrar e anotar sao duas tarefas, e um
  # modelo de 4B so faz uma bem por vez: toda vez que as duas vieram juntas,
  # uma comeu a outra. A anotacao vira uma segunda chamada, curta e separada.
  $sistema += @'

## O PERSONAGEM DO JOGADOR E SO DELE

Voce NUNCA fala pelo personagem do jogador. Nunca escreve fala dele entre
aspas. Nunca diz o que ele sente, pensa, decide, percebe por dentro ou como
reage. Nunca resolve a acao dele sozinho nem emenda a proxima acao por ele.

Ele disse o que faz. Voce narra o MUNDO respondendo aquilo, e para.

  ERRADO: __JOGADOR__- deixem ele em paz!   <- nunca escreva o nome dele na frente
  ERRADO: "Deixem-no em paz!", voce grita, avancando furioso.
  ERRADO: Voce percebe que e uma armadilha e recua.
  ERRADO: Voce decide confiar nele.
  CERTO:  O capanga trava o passo. A mao dele ainda esta no cabo da adaga,
          e ele espera voce falar primeiro.

Quem tem fala sao os NPCs. Quem tem vontade propria sao os NPCs. O personagem
do jogador so faz o que o jogador escreveu, nada alem disso.

Quando a vez volta pra ele, PARE. Deixe a cena aberta.

## VOCE JOGA OS NPCS

O aliado nao espera ordem. Ele esta na cena e age por conta propria, do jeito
dele. Monstro atacou o jogador? Ele reage, obvio. O jogador nunca precisa
dizer o que o aliado faz - quem joga com o aliado e VOCE.

Cada NPC tem um "Quer:" e "Lacos:" na ficha. E de la que sai a acao dele, nao
da conveniencia da cena. Eles discordam, discutem, hesitam, fazem besteira,
mentem e as vezes atrapalham.

Se o jogador mandar o aliado fazer algo, isso e um PEDIDO. O aliado atende se
quiser. Contra o que ele ama, deve ou teme, provavelmente nao atende.

## CADA UM FALA DO JEITO DELE

Toda ficha traz "Voz:" e "Fala assim:". Copie o REGISTRO do "Fala assim" -
o tamanho da frase, o palavrao, a gramatica torta, o jeito de chamar as
pessoas. Nao e enfeite: e como aquela pessoa abre a boca.

O erro que voce vai querer cometer e por todo mundo falando o mesmo portugues
correto de narrador. Nao faca isso.

  ERRADO: uma adolescente com raiva dizendo "Fique quieto!"
  CERTO:  "cala a boca, porra" - que e como ela fala de verdade

  ERRADO: um capitao velho dizendo "vamo nessa"
  CERTO:  "Formacao. Agora."

Se a ficha nao tiver "Fala assim", deduza do "Voz:", da idade e de onde a
pessoa foi criada. Um NPC que fala igual ao Mestre e um NPC que voce errou.

## TODA FALA LEVA O NOME NA FRENTE

Fala e sempre uma linha propria: o nome de quem falou, um traco, e o que a
pessoa diz. Cada ficha tem um "Fala assim:" que ja mostra a linha pronta
daquele personagem - siga aquele modelo, com o nome dele.

Nao existe fala solta. Se voce nao sabe quem falou, ninguem falou - corte.
A narracao continua normal, em linha separada, sem nome na frente.

## AGORA
Narre a cena. So a cena, na voz do Mestre, em portugues.
Comece direto, sem titulo e sem cabecalho. Frases curtas, em batidas.
Termine com o que esta na frente dele agora - e pare ai.
'@

  # O nome do personagem sai da ficha, nunca cravado no codigo: cada campanha
  # tem o seu. Sem isso o exemplo ensinaria o modelo o nome errado.
  $nomePj = if ((Ler (Join-Path $Campanha '02-personagem.md')) -match '(?im)^\s*-\s*nome\s*:\s*(.+)$') { $Matches[1].Trim() } else { '' }
  $primeiroPj = if ($nomePj) { ($nomePj -split '\s+')[0] } else { 'o personagem' }
  $sistema = $sistema.Replace('__JOGADOR__', $primeiroPj)
  if ($nomePj) {
    $sistema += "`n## O NOME QUE VOCE NUNCA USA NA FRENTE DE UMA FALA`n" +
                "$primeiroPj`n`nEsse e o personagem do jogador. Todos os outros nomes podem abrir fala.`n"
  }

  $msgs = New-Object Collections.ArrayList
  [void]$msgs.Add(@{ role = "system"; content = $sistema })

  # As duas ultimas respostas do Mestre voltam COM o bloco de memoria colado.
  # Sem isso o modelo olha pro proprio historico, ve respostas sem bloco, e
  # imita a si mesmo: escrevia o bloco na primeira jogada e parava nas seguintes.
  # Exemplo do proprio modelo vale mais que instrucao.
  $janela = @($Historico | Select-Object -Last $MaxHist)
  $comBloco = New-Object Collections.Generic.HashSet[int]
  $achei = 0
  for ($k = $janela.Count - 1; $k -ge 0 -and $achei -lt 2; $k--) {
    if ([string]$janela[$k].papel -eq "assistant" -and [string]$janela[$k].bloco) {
      [void]$comBloco.Add($k); $achei++
    }
  }
  for ($k = 0; $k -lt $janela.Count; $k++) {
    $h = $janela[$k]
    $txt = [string]$h.texto
    if ($comBloco.Contains($k)) { $txt = $txt.TrimEnd() + "`n" + ([string]$h.bloco).Trim() }
    [void]$msgs.Add(@{ role = [string]$h.papel; content = $txt })
  }
  # AS REGRAS DURAS VAO POR ULTIMO, depois da jogada.
  #
  # Isto e o \"post-history instruction\" / \"author's note em profundidade 0\" que o
  # pessoal de SillyTavern usa: quanto mais perto do fim do prompt, mais peso a
  # instrucao tem. Antes essas regras estavam no prompt de sistema, la em cima -
  # e entre elas e a hora de escrever passavam lorebook, fichas e historico. Um
  # modelo de 4B chegava no fim sem lembrar de nenhuma, e cada regra nova que eu
  # somava derrubava outra. Nao era falta de capacidade, era distancia.
  #
  # Por isso aqui e CURTO. Cinco linhas. Se crescer, volta a nao valer nada.
  $duras = New-Object Text.StringBuilder
  [void]$duras.AppendLine("Antes de escrever, as cinco regras da casa:")
  [void]$duras.AppendLine("")
  if ($primeiroPj -ne 'o personagem') {
    [void]$duras.AppendLine("1. NUNCA comece uma frase com $primeiroPj. Ele so pode aparecer dentro da")
    [void]$duras.AppendLine("   fala de outra pessoa. Voce narra o mundo, nunca o que ele faz ou sente.")
  } else {
    [void]$duras.AppendLine("1. O personagem do jogador e dele. So o que ele escreveu acima aconteceu.")
  }
  [void]$duras.AppendLine("2. Os aliados agem sozinhos, no turno deles, sem esperar ordem.")
  [void]$duras.AppendLine("3. Toda fala e uma linha comecando por Nome- e o jeito de falar daquela pessoa.")
  [void]$duras.AppendLine("4. Frases curtas, mas narre a cena inteira: 3 a 6 linhas. Nao repita o que ja esta acima.")
  [void]$duras.AppendLine("5. Termine SEMPRE com esta linha, sozinha, e nao escreva mais nada depois:")
  [void]$duras.AppendLine("   Mestre: o que $primeiroPj diz ou faz?")
  # Coladas NA MENSAGEM DO JOGADOR, nao como mensagem 'system' propria: o
  # template de chat do Gemma nao tem papel system, e o Ollama funde system la
  # pra cima - o que jogava a regra de volta pra longe, que e o bug que eu
  # estava tentando consertar. O SillyTavern faz igual: injecao no papel user.
  [void]$msgs.Add(@{ role = "user"; content = ($entrada + "`n`n---`n" + $duras.ToString().TrimEnd()) })

  , $msgs
}

# Modo conversa: sem dado, sem ficha, sem diario. So papo.
$CONVERSA = @'
Voce ajuda alguem a preparar uma mesa de RPG. A campanha ainda NAO comecou.

Converse normal, em portugues do Brasil. Responda pergunta sobre regra, ajude
a montar personagem, sugira ideia de mundo, discuta tom. Seja direto e curto.

Voce NAO esta narrando nada ainda. Nao descreva cena, nao invente que o
personagem esta em algum lugar, nao role dado, nao fale pelo jogador.

Quando ele quiser comecar de verdade, ele digita /iniciar campanha. Ate la, so
conversa. Se ele parecer pronto, lembre disso numa linha - sem insistir.
'@

$EXTRATOR = @'
Voce e um anotador de mesa de RPG. Nao narra, nao inventa, nao opina.

Vou te dar a ficha atual do personagem e a cena que acabou de acontecer.
Sua unica tarefa e devolver o bloco abaixo, exatamente neste formato, e nada
mais. Sem comentario, sem titulo, sem explicacao.

###FICHA###
campo: valor
###LORE###
Nome | palavras-chave | o fato
###MUNDO###
o que aconteceu longe do personagem
###APAGAR###
lore: nome     (ou)     diario: trecho
###DIARIO###
uma frase no passado
###FIM###

REGRAS DURAS

FICHA: so campo que ja aparece na ficha que eu te mandei, e so se a cena
disser que mudou. Perdeu vida? escreva o pv novo. Nada mudou? deixe vazio.
Nunca invente campo. Nunca copie numero de exemplo.

LORE: so pessoa, lugar ou fato PERMANENTE que apareceu com nome proprio na
cena. Use [[Nome]] pra citar quem ja existe. Acao passageira nao vai aqui.

MUNDO: so o que aconteceu longe do personagem. Quase sempre vazio.

APAGAR: so quando a cena disser explicitamente que algo anterior estava errado.

DIARIO: uma frase, no passado, do que aconteceu nesta cena. Sempre preenchido.

Secao sem nada fica vazia, mas os seis marcadores aparecem sempre.
'@


# Segunda chamada: le a cena que acabou de ser narrada e devolve so o bloco.
# Prompt minusculo, uma tarefa so. Narrar e anotar na mesma chamada nunca
# funcionou num modelo de 4B: a instrucao mais recente sempre comia a outra.
function PedirBloco([string]$narracao) {
  if (-not $narracao -or $narracao.Length -lt 40) { return "" }
  $ficha = Ler (Join-Path $Campanha "02-personagem.md")
  $campos = @([Regex]::Matches($ficha, '(?m)^-\s*([^:\r\n]{1,30})\s*:\s*(.*)$') |
              ForEach-Object { "- " + $_.Groups[1].Value.Trim() + ": " + $_.Groups[2].Value.Trim() }) -join "`n"

  $pedido = "FICHA ATUAL`n$campos`n`nCENA QUE ACABOU DE ACONTECER`n$narracao`n`nDevolva o bloco."
  $msgs = @(
    @{ role = "system"; content = $EXTRATOR },
    @{ role = "user";   content = $pedido }
  )
  $payload = ConvertTo-Json @{
    model = $Cfg.modelo; messages = $msgs; stream = $false
    options = @{ temperature = 0.2; num_ctx = [int]$Cfg.contexto; num_predict = 400 }
    keep_alive = "30m"
  } -Depth 8

  try {
    $r = [Net.HttpWebRequest]::Create("$Ollama/api/chat")
    $r.Method = "POST"; $r.ContentType = "application/json"
    $r.Timeout = 300000; $r.ReadWriteTimeout = 300000
    $pb = $UTF8.GetBytes($payload); $r.ContentLength = $pb.Length
    $os = $r.GetRequestStream(); $os.Write($pb, 0, $pb.Length); $os.Close()
    $resp = (New-Object IO.StreamReader($r.GetResponse().GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
    $b = [string]$resp.message.content
    $k = AcharBloco $b
    if ($k -ge 0) { return $b.Substring($k) }
    return ""
  } catch {
    Write-Host ("   extrator falhou: " + $_.Exception.Message) -ForegroundColor DarkYellow
    return ""
  }
}



# --------------------------------------------------------------- a forja
#
# A Tabua de Kleos e o motor de criacao de monstros do sistema Ascensao dos
# Semideuses. E aritmetica exata, entao QUEM CALCULA E O SERVIDOR. O modelo so
# decide as duas coisas que sao julgamento: qual degrau (Kleos) e qual
# arquetipo. Pedir "+30% de PV sobre 115" pra um 4B e pedir erro.

$TABUA_KLEOS = @{
  1  = @{ pv = 11;  def = 12; atq = 3;  dano = 5;   efeito = 3;  forte = 17; fraca = 14; ataques = 1 }
  2  = @{ pv = 22;  def = 13; atq = 4;  dano = 9;   efeito = 4;  forte = 18; fraca = 15; ataques = 1 }
  3  = @{ pv = 36;  def = 14; atq = 5;  dano = 14;  efeito = 5;  forte = 19; fraca = 15; ataques = 2 }
  4  = @{ pv = 55;  def = 15; atq = 6;  dano = 20;  efeito = 6;  forte = 20; fraca = 16; ataques = 2 }
  5  = @{ pv = 80;  def = 16; atq = 7;  dano = 27;  efeito = 7;  forte = 21; fraca = 16; ataques = 2 }
  6  = @{ pv = 115; def = 17; atq = 8;  dano = 35;  efeito = 8;  forte = 22; fraca = 17; ataques = 2 }
  7  = @{ pv = 155; def = 17; atq = 9;  dano = 45;  efeito = 9;  forte = 23; fraca = 17; ataques = 3 }
  8  = @{ pv = 210; def = 18; atq = 10; dano = 56;  efeito = 10; forte = 24; fraca = 18; ataques = 3 }
  9  = @{ pv = 280; def = 19; atq = 11; dano = 70;  efeito = 11; forte = 25; fraca = 18; ataques = 3 }
  10 = @{ pv = 370; def = 20; atq = 13; dano = 88;  efeito = 13; forte = 27; fraca = 19; ataques = 3 }
  11 = @{ pv = 500; def = 21; atq = 15; dano = 110; efeito = 15; forte = 29; fraca = 20; ataques = 4 }
}

# Arquetipo troca numeros entre si sem mudar o Kleos.
$ARQUETIPOS = @{
  "bruto"       = @{ pv = 1.30; def = -1; ataques =  0; dano = 1.00; nota = "concentra o dano num ataque grande" }
  "veloz"       = @{ pv = 0.75; def =  1; ataques = +1; dano = 1.00; nota = "chega antes e sai antes, +3 m de movimento" }
  "blindado"    = @{ pv = 0.75; def =  2; ataques =  0; dano = 1.00; nota = "dificil de acertar, comum ser imune a veneno e efeito mental" }
  "conjurador"  = @{ pv = 1.00; def =  0; ataques =  0; dano = 0.60; nota = "bate pouco e muda o campo; usa Efeito contra defesa passiva" }
  "sombra"      = @{ pv = 0.80; def =  0; ataques =  0; dano = 1.00; nota = "resiste a dano fisico nao-divino; atravessa, some ou nao pode ser agarrada" }
  "colosso"     = @{ pv = 1.50; def = -2; ataques =  0; dano = 1.00; nota = "ocupa espaco, atinge varios alvos, nao pode ser agarrado nem derrubado" }
  "enxame"      = @{ pv = 1.00; def =  0; ataques =  0; dano = 1.00; nota = "sao muitos: 3 a 6 criaturas de Kleos -2" }
}

function ForjarCriatura($nome, $kleos, $arquetipo, $fortes, $chaves) {
  $k = [int]$kleos
  if ($k -lt 1) { $k = 1 }
  if ($k -gt 11) { $k = 11 }
  $b = $TABUA_KLEOS[$k]

  $a = $null
  $an = ""
  if ($arquetipo) {
    $an = (SemAcento $arquetipo).Trim()
    if ($ARQUETIPOS.ContainsKey($an)) { $a = $ARQUETIPOS[$an] }
  }
  if (-not $a) { $a = @{ pv = 1.00; def = 0; ataques = 0; dano = 1.00; nota = "" }; $an = "" }

  $pv   = [int][Math]::Round($b.pv * $a.pv)
  $def  = $b.def + $a.def
  $nAtq = [Math]::Max(1, $b.ataques + $a.ataques)
  $dano = [int][Math]::Round($b.dano * $a.dano)
  $porAtq = [Math]::Max(1, [int][Math]::Round($dano / $nAtq))

  # duas defesas fortes e uma fraca; o modelo escolhe quais
  $todas = @("Fortitude", "Reflexos", "Vontade")
  $ft = @()
  if ($fortes) { $ft = @(($fortes -split '[,;/ ]+') | ForEach-Object { $_.Trim() } | Where-Object { $todas -contains $_ }) }
  if ($ft.Count -lt 2) { $ft = @("Fortitude", "Vontade") }
  $ft = @($ft | Select-Object -First 2)
  $fr = @($todas | Where-Object { $ft -notcontains $_ })[0]

  $ks = if ($chaves) { $chaves } else { $nome }
  $linhas = New-Object Collections.ArrayList
  $rot = "kleos $k"
  if ($an) { $rot = $rot + ", " + $arquetipo }
  [void]$linhas.Add($rot)
  [void]$linhas.Add("VIDA: $pv PV")
  [void]$linhas.Add("PRA ACERTAR ELE: o ataque precisa alcancar DEF $def")
  [void]$linhas.Add("PRA AFETAR COM EFEITO: $($ft[0]) $($b.forte), $($ft[1]) $($b.forte), $fr $($b.fraca) - o ponto fraco e $fr")
  [void]$linhas.Add("QUANDO ELE ATACA: d20 +$($b.atq) contra a DEF do alvo. Acertou, $porAtq de dano. $nAtq ataque(s) por acao.")
  [void]$linhas.Add("QUANDO ELE USA EFEITO: d20 +$($b.efeito) contra a defesa passiva do alvo.")
  if ($a.nota) { [void]$linhas.Add("tatica: " + $a.nota) }

  $selo = "Kleos $k"
  if ($an) { $selo = $selo + ", " + $arquetipo }

  [pscustomobject]@{
    nome = $nome
    chaves = $ks
    texto = "---`nchaves: $ks`n---`n**$nome**`n" + (($linhas) -join "`n") + "`n"
    resumo = "$nome ($selo): $pv PV, DEF $def, ataque +$($b.atq), $porAtq de dano por golpe"
  }
}



# ------------------------------------------------------ resolvedor de combate
#
# O modelo decide INTENCAO ("Kyros ataca o Capanga A com a lanca"). A conta e
# aqui. Ja tiramos o dado e a Tabua de Kleos das maos dele e funcionou nas duas
# vezes; carregar DEF 13 -> 8 PV -> 2 de dano por quatro operacoes e a terceira
# coisa que ele nao sustenta.

$script:Combate = $null   # @{ vivos = @{ nome = @{ pv; max; ficha } } }

function _numDe($txt, $rx) {
  $m = [Regex]::Match($txt, $rx)
  if ($m.Success) { [int]$m.Groups[1].Value } else { $null }
}

# Le uma ficha (jogador, aliado ou criatura) e devolve os numeros que importam.
function LerFicha($nome, $texto, $ehJogador) {
  $def = _numDe $texto '(?im)(?:alcancar\s+DEF|^\s*-?\s*def)\s*:?\s*(\d+)'
  $pv  = _numDe $texto '(?im)(?:VIDA:\s*|^\s*-?\s*pv\s*:\s*)(\d+)'
  $atq = _numDe $texto '(?im)QUANDO EL[EA] ATACA:\s*d20\s*\+(\d+)'   # ELE ou ELA
  $dano = _numDe $texto '(?im)Acertou,\s*(\d+)\s*de dano'
  $n   = _numDe $texto '(?im)(\d+)\s*ataque\(s\) por acao'
  if ($ehJogador) {
    # ficha de personagem: o bonus de ataque sai da destreza ou forca
    $dex = _numDe $texto '(?im)^\s*-\s*destreza\s*:\s*\+?(\d+)'
    $for = _numDe $texto '(?im)^\s*-\s*forca\s*:\s*\+?(\d+)'
    if ($null -eq $atq) { $atq = [Math]::Max([int]$dex, [int]$for) }
    if ($null -eq $dano) { $dano = 4 + [int]$for }
    if ($null -eq $n) { $n = 1 }
  }
  [pscustomobject]@{
    nome = $nome
    def  = if ($def)  { $def }  else { 12 }
    pv   = if ($pv)   { $pv }   else { 10 }
    atq  = if ($atq)  { $atq }  else { 2 }
    dano = if ($dano) { $dano } else { 3 }
    ataques = if ($n) { $n } else { 1 }
  }
}

# Monta o elenco da cena: jogador, aliados e criaturas citadas.
function ElencoDaCena($texto) {
  $elenco = @{}
  $fj = Ler (Join-Path $Campanha "02-personagem.md")
  $nomeJog = if ($fj -match '(?im)^\s*-\s*nome\s*:\s*(.+)$') { $Matches[1].Trim() } else { "o personagem" }
  $fichaJog = LerFicha $nomeJog $fj $true
  $fichaJog | Add-Member -NotePropertyName lado -NotePropertyValue 'jogador' -Force
  $elenco[$nomeJog] = $fichaJog

  foreach ($d in @($DirAliados, $DirCriaturas)) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    $soCitadas = ($d -eq $DirCriaturas)
    $alvo = SemAcento $texto
    foreach ($f in (Get-ChildItem -LiteralPath $d -Filter *.md -File)) {
      if ($f.BaseName -like "LEIA-ME*") { continue }
      $c = Ler $f.FullName
      $chaves = @(SemAcento $f.BaseName)
      if ($c -match '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n') {
        if ($Matches[1] -match 'chaves\s*:\s*(.+)') {
          $chaves = @(($Matches[1] -split ',') | ForEach-Object { SemAcento $_.Trim() } | Where-Object { $_ })
        }
      }
      $entra = -not $soCitadas
      if ($soCitadas) { foreach ($k in $chaves) { if ($k.Length -ge 3 -and $alvo.Contains($k)) { $entra = $true; break } } }
      if (-not $entra) { continue }
      $nome = if ($c -match '(?m)^\*\*(.+?)\*\*') { $Matches[1].Trim() } else { $f.BaseName }
      $ficha = LerFicha $nome $c $false
      $ficha | Add-Member -NotePropertyName lado -NotePropertyValue $(if ($soCitadas) { 'inimigo' } else { 'aliado' }) -Force
      $elenco[$nome] = $ficha
    }
  }
  $elenco
}

# Acha quem e quem numa linha de intencao, sem exigir nome exato.
function _achar($elenco, $pedaco) {
  if (-not $pedaco) { return $null }
  $p = SemAcento $pedaco
  foreach ($n in $elenco.Keys) {
    $sn = SemAcento $n
    if ($p.Contains($sn) -or $sn.Contains($p)) { return $n }
  }
  foreach ($n in $elenco.Keys) {
    foreach ($palavra in ((SemAcento $n) -split '\s+')) {
      if ($palavra.Length -ge 4 -and $p.Contains($palavra)) { return $n }
    }
  }
  $null
}

# Recebe as linhas de intencao do modelo e resolve tudo com as fichas.
# Uma investida: rola, compara com a DEF, tira PV. Virou funcao porque agora
# roda em dois lugares - nas intencoes do modelo e no turno automatico do aliado.
function _bater($elenco, $estado, $qNome, $aNome, $arma, $log) {
  $q = $elenco[$qNome]; $a = $elenco[$aNome]
  $d = _dado
  $tot = $d + $q.atq
  $comArma = if ($arma) { " com " + ([string]$arma).Trim() } else { "" }
  if ($tot -ge $a.def) {
    $estado[$aNome].pv = [Math]::Max(0, $estado[$aNome].pv - $q.dano)
    [void]$log.Add("[$qNome ataca $aNome$comArma : $d + $($q.atq) = $tot vs DEF $($a.def) -> ACERTA]")
    [void]$log.Add("   dano $($q.dano)  ->  $aNome`: $($estado[$aNome].pv)/$($estado[$aNome].max) PV" +
                   $(if ($estado[$aNome].pv -le 0) { "  CAIU" } else { "" }))
  } else {
    [void]$log.Add("[$qNome ataca $aNome$comArma : $d + $($q.atq) = $tot vs DEF $($a.def) -> ERRA]")
  }
}

# O jogador so faz o que o jogador escreveu. O juiz e um modelo: ele inventa
# acao pro personagem do jogador (o 12B sacou uma espada e atacou quando a
# jogada tinha sido so \"um lestrigao vem pra cima de mim\"). Entao qualquer
# linha de ataque com o jogador como autor passa por esta conferencia contra o
# texto que ELE escreveu - e nao passa se ele nao declarou ataque.
# Palavra que tambem e substantivo fica de fora: 'mato' (sai do mato), 'furo',
# 'acerto'. Verbo ambiguo aqui abre a guarda justamente na jogada mais comum.
$RX_ATAQUE_JOGADOR = '(?i)\b(ataco|atacamos|golpeio|estoco|apunhalo|esfaqueio|disparo|atiro|flecho|revido|investo|derrubo|degolo|esmago)\b|\b(parto|avanco|corro)\s+(pra|para)\s+cima\b|\bdou\s+(um\s+)?(soco|chute|golpe)\b'
$RX_NAO_ATACO     = '(?i)\b(sem revidar|sem atacar|nao revido|nao ataco|nao vou atacar|so me defendo|apenas me defendo|me defendo|nao levanto a arma)\b'

function JogadorDeclarouAtaque([string]$entrada) {
  if (-not $entrada) { return $false }
  $e = SemAcento $entrada
  if ($e -match (SemAcento $RX_NAO_ATACO)) { return $false }
  [bool]($e -match (SemAcento $RX_ATAQUE_JOGADOR))
}

function ResolverCombate([string]$intencoes, [string]$dados, [string]$contexto, [string]$entradaJogador) {
  $elenco = ElencoDaCena $contexto
  if ($elenco.Count -lt 2) { return "" }

  # estado de PV atravessa as rodadas
  if (-not $script:Combate) { $script:Combate = @{} }
  foreach ($n in $elenco.Keys) {
    if (-not $script:Combate.ContainsKey($n)) { $script:Combate[$n] = @{ pv = $elenco[$n].pv; max = $elenco[$n].pv } }
  }

  $fila = @(($dados -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
  $iDado = 0
  function _dado {
    if ($script:_i -lt $script:_fila.Count) { $v = $script:_fila[$script:_i]; $script:_i++; return $v }
    (New-Object Random).Next(1, 21)
  }
  $script:_fila = $fila; $script:_i = 0

  $log = New-Object Collections.ArrayList
  $agiram = New-Object Collections.ArrayList
  foreach ($l in ($intencoes -split "`r?`n")) {
    $s = $l.Trim()
    if (-not $s) { continue }
    # aliado com vontade propria pode nao atacar. Essas linhas passam direto
    # pro narrador, sem conta nenhuma - nao ha o que resolver em hesitar.
    if ($s -match '(?i)^(.{2,40}?)\s+(hesita|recusa|se recusa|protege|defende|foge|congela|chora|grita com|implora|argumenta|desobedece)\b(.*)$') {
      $quem = _achar $elenco $Matches[1]
      if ($quem) { [void]$log.Add($quem + " " + $Matches[2] + $Matches[3]); continue }
    }
    if ($s -notmatch '(?i)^(.{2,40}?)\s+(?:ataca|golpeia|acerta|investe contra|parte pra cima d[eoa])\s+(.{2,40}?)(?:\s+com\s+(.+))?$') { continue }
    $qNome = _achar $elenco $Matches[1]
    $aNome = _achar $elenco $Matches[2]
    $arma  = $Matches[3]
    if (-not $qNome -or -not $aNome -or $qNome -eq $aNome) { continue }
    # o juiz nao pode fazer o personagem do jogador atacar por conta propria
    if ($elenco[$qNome].lado -eq 'jogador' -and -not (JogadorDeclarouAtaque $entradaJogador)) {
      Write-Host ("   recusei: o juiz fez " + $qNome + " atacar sem o jogador mandar") -ForegroundColor DarkYellow
      continue
    }
    if ($script:Combate[$aNome].pv -le 0) { [void]$log.Add("$aNome ja esta caido - $qNome muda de alvo ou espera"); continue }

    _bater $elenco $script:Combate $qNome $aNome $arma $log
    [void]$agiram.Add($qNome)
  }

  # O TURNO DO ALIADO E GARANTIDO AQUI, nao pedido ao modelo.
  #
  # Pelo Guia do Mestre o aliado recorrente tem iniciativa propria e age no
  # turno dele. Isso e regra, nao escolha narrativa - entao nao pode depender
  # de o modelo lembrar. Em toda rodada testada ele descrevia a Alysa falando e
  # nunca atacando; agora, se o juiz nao deu acao pra ela e existe inimigo de
  # pe, o servidor da: ela bate no inimigo mais machucado, que e o que um
  # coadjuvante faz.
  $inimigosDePe = @($elenco.Keys | Where-Object { $elenco[$_].lado -eq 'inimigo' -and $script:Combate[$_].pv -gt 0 })
  if ($inimigosDePe.Count -gt 0) {
    # o @() e obrigatorio: com UM inimigo so, o pipe devolve uma string, e [0]
    # numa string devolve o primeiro CARACTERE - o alvo virava 'L' e sumia.
    $alvo = @($inimigosDePe | Sort-Object { $script:Combate[$_].pv })[0]
    foreach ($n in @($elenco.Keys | Where-Object { $elenco[$_].lado -eq 'aliado' } | Sort-Object)) {
      if ($agiram.Contains($n)) { continue }
      if ($script:Combate[$n].pv -le 0) { continue }
      _bater $elenco $script:Combate $n $alvo $null $log
    }
  }

  if ($log.Count -eq 0) { return "" }

  $vivos = @($script:Combate.Keys | Where-Object { $script:Combate[$_].pv -gt 0 } | Sort-Object)
  $caidos = @($script:Combate.Keys | Where-Object { $script:Combate[$_].pv -le 0 } | Sort-Object)
  $t = ($log -join "`n") + "`n`nDE PE: " + ($vivos -join ", ")
  if ($caidos.Count) { $t += "`nCAIDOS: " + ($caidos -join ", ") }
  $t
}

# ------------------------------------------------------------ o aliado que luta
#
# Regra do Guia do Mestre. Um aliado recorrente NAO se monta no Kleos de um
# heroi: medido, ele sobrevive a 6% dos combates no nivel 9 e a mesa para de se
# importar com ele. Ele usa a linha inteira da Tabua no KLEOS DO GRUPO MENOS 2 -
# PV, DEF, ataque e dano - e nao entra no orcamento do encontro, porque ja esta
# contado como um dos personagens em campo.

function ForjarAliado($nome, $kleosGrupo, $arquetipo, $fortes, $chaves, $eventual) {
  $kg = [int]$kleosGrupo
  if ($kg -lt 3) { $kg = 3 }
  # O livro separa os dois: o recorrente ja esta contado no Kleos do Grupo e usa
  # a linha grupo-2; o eventual (o deus que aparece numa cena e vai embora) monta
  # no proprio Kleos e SOMA no orcamento do encontro.
  $k = $(if ($eventual) { [Math]::Max(1, [int]$kleosGrupo) } else { [Math]::Max(1, $kg - 2) })
  $c = ForjarCriatura $nome $k $arquetipo $fortes $chaves
  $t = $c.texto.TrimEnd() + "`n" + @"
Quer: (o que ele persegue, mesmo contra o grupo)
Lacos: (quem ele ama, deve favor ou teme)
Voz: (idade, de onde veio, como trata os outros)
Fala assim: NOME- (uma frase inteira na boca dele, com os erros e as girias dele)
tipo: $(if ($eventual) { "aliado eventual (kleos proprio $k) - so aparece quando a cena pede" } else { "aliado recorrente (kleos do grupo $kg, linha $k = grupo menos 2)" })
turno: tem iniciativa propria e age no proprio turno, como coadjuvante
orcamento: $(if ($eventual) { "SOMA $k no encontro" } else { "NAO soma no encontro - ja esta contado como um personagem em campo" })
sobe junto: $(if ($eventual) { "nao - some quando a cena acabar" } else { "quando o Kleos do Grupo subir, refaca esta ficha na linha nova" })
"@
  [pscustomobject]@{
    nome = $c.nome
    texto = $t
    resumo = $c.resumo + $(if ($eventual) { " [aliado eventual, kleos $k]" } else { " [aliado, grupo $kg]" })
  }
}

# Aliado recorrente esta em toda cena: entra sempre, nao por palavra-chave.
# O eventual so entra quando a cena o cita - senao um deus de passagem ficaria
# de plantao pra sempre, e ainda somando orcamento.
function AliadosDaMesa($orcamento, $texto) {
  if (-not (Test-Path -LiteralPath $DirAliados)) { return "" }
  $out = New-Object Collections.ArrayList
  $usado = 0
  $alvo = SemAcento ([string]$texto)
  foreach ($f in (Get-ChildItem -LiteralPath $DirAliados -Filter *.md -File | Sort-Object Name)) {
    if ($f.BaseName -like "LEIA-ME*") { continue }
    $c = Ler $f.FullName
    $chaves = @(SemAcento $f.BaseName)
    if ($c -match '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n') {
      if ($Matches[1] -match 'chaves\s*:\s*(.+)') {
        $chaves = @(($Matches[1] -split ',') | ForEach-Object { SemAcento $_.Trim() } | Where-Object { $_ })
      }
      $c = $c.Substring($Matches[0].Length)
    }
    $b = $c.Trim()
    if ($b -match '(?im)^tipo\s*:.*eventual') {
      $citado = $false
      foreach ($k in $chaves) { if ($k.Length -ge 3 -and $alvo.Contains($k)) { $citado = $true; break } }
      if (-not $citado) { continue }
    }
    if ($usado + $b.Length -le $orcamento) { [void]$out.Add($b); $usado += $b.Length }
  }
  if ($out.Count -eq 0) { return "" }
  ($out -join "`n`n")
}

# ---------------------------------------------------------------- criaturas

# Ficha de inimigo. Sem isso o Mestre rola "vs. o bonus de ataque deles" e
# inventa o alvo depois de ver o dado - que e o mesmo que nao rolar.
function CriaturasRelevantes($texto, $orcamento) {
  if (-not (Test-Path -LiteralPath $DirCriaturas)) { return "" }
  $alvo = SemAcento $texto
  $out = New-Object Collections.ArrayList
  $usado = 0
  foreach ($f in (Get-ChildItem -LiteralPath $DirCriaturas -Filter *.md -File)) {
    $c = Ler $f.FullName
    $chaves = @(SemAcento $f.BaseName)
    $corpo = $c
    if ($c -match '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n') {
      $corpo = $c.Substring($Matches[0].Length)
      if ($Matches[1] -match 'chaves\s*:\s*(.+)') {
        $chaves = @(($Matches[1] -split ',') | ForEach-Object { SemAcento $_.Trim() } | Where-Object { $_ })
      }
    }
    foreach ($k in $chaves) {
      if ($k.Length -ge 3 -and $alvo.Contains($k)) {
        $b = $corpo.Trim()
        if ($usado + $b.Length -le $orcamento) { [void]$out.Add($b); $usado += $b.Length }
        break
      }
    }
  }
  if ($out.Count -eq 0) { return "" }
  ($out -join "`n`n")
}

# Decide se a rodada tem mecanica. Cuidado: a lista antiga so tinha verbo de
# acao DO JOGADOR, entao \"um lestrigao sai do mato e vem pra cima de mim\" nao
# ligava o motor - e sem rodada nenhum aliado tem turno pra agir sozinho.
function CenaTemRisco($texto) {
  $t = SemAcento $texto
  if ($t -match 'atac|ataqu|lanca|espada|adaga|escudo|golpe|briga|luta|combat|cerca|agarr|derrub|empurr|esquiv|furtiv|escond|arromb|escal|salt|convenc|intimid|persuad|resist|veneno|armadilh|queda|fug') { return $true }
  # o jogador sendo alvo, que e o caso que faltava
  if ($t -match 'vem pra cima|parte pra cima|vem na minha|investe|avanc|arremet|se joga em|pula em|bote|rosna|urra|rug|mord|garra|presa|ameac|encurral|emboscad|surge d|sai do mato|me pega|me acerta|me derruba|sangr|ferid') { return $true }
  # criatura com ficha presente e risco por definicao: ela age no turno dela,
  # mesmo que o jogador nao tenha encostado nela.
  if (Test-Path -LiteralPath $DirCriaturas) {
    foreach ($f in (Get-ChildItem -LiteralPath $DirCriaturas -Filter *.md -File -EA SilentlyContinue)) {
      if ($f.BaseName -like 'LEIA-ME*') { continue }
      $chaves = @(SemAcento $f.BaseName)
      $c = Ler $f.FullName
      if ($c -match '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n' -and $Matches[1] -match 'chaves\s*:\s*(.+)') {
        $chaves = @(($Matches[1] -split ',') | ForEach-Object { SemAcento $_.Trim() } | Where-Object { $_ })
      }
      foreach ($k in $chaves) { if ($k.Length -ge 4 -and $t.Contains($k)) { return $true } }
    }
  }
  $false
}

$CALCULADOR = @'
Voce e o juiz de regras da mesa. Voce NAO narra, NAO rola dado e NAO calcula
nada. Os dados e as contas sao meus.

Sua unica tarefa: dizer QUEM faz O QUE contra QUEM, em ordem de turno.

Uma linha por acao, exatamente nesta forma e nada mais:

  Nome ataca Nome com arma

Ordem: primeiro o que o JOGADOR disse que faz. Depois os aliados dele. Depois
os inimigos, um por vez.

REGRAS DURAS

- O JOGADOR DECIDE SOZINHO. Escreva so a acao que ele escreveu. Nao invente
  segunda acao pra ele, nao faca ele recuar, gritar, hesitar nem trocar de alvo.
- Use os nomes exatos que aparecem nas fichas que eu te mandei.
- Nao escreva numero nenhum: nem dado, nem dano, nem PV, nem DEF.
- Nao escreva narracao, nem introducao, nem conclusao. So as linhas.
- Quem ja caiu nao age.

CRIATURA SEM FICHA: antes das linhas de acao, monte a ficha. Voce decide so
duas coisas e eu calculo o resto pela Tabua de Kleos do sistema:

  FICHA NOVA: Nome | kleos: N | arquetipo: X | fortes: Defesa, Defesa | chaves: palavras

  kleos     = degrau de 1 a 11. Capanga de bando fica 3 ou 4 degraus abaixo do
              grupo. Inimigo central da sessao fica no degrau do grupo.
  arquetipo = Bruto, Veloz, Blindado, Enxame, Conjurador, Sombra ou Colosso.
  fortes    = as DUAS defesas passivas fortes (Fortitude, Reflexos, Vontade).
  chaves    = palavras que o jogador diria pra citar ela.

  Nao escreva PV, DEF, ataque nem dano: os numeros da Tabua sao meus.

- ALIADO QUE LUTA: aliado age no turno dele, como coadjuvante. Ele entra nas
  linhas tambem, com o nome da ficha dele.
'@


# Primeira das tres chamadas: resolve a mecanica ANTES de narrar.
# O narrador entao so descreve o que ja aconteceu, em vez de inventar numero
# no meio da prosa - que era o motivo de toda rolagem dar sucesso.
function CalcularCena([string]$entrada, [string]$dados) {
  $recente = (($Historico | Select-Object -Last 4 | ForEach-Object { $_.texto }) -join " ")
  $busca = $recente + " " + $entrada

  $ficha = Ler (Join-Path $Campanha "02-personagem.md")
  $campos = @([Regex]::Matches($ficha, '(?m)^-\s*([^:\r\n]{1,30})\s*:\s*(.*)$') |
              ForEach-Object { "- " + $_.Groups[1].Value.Trim() + ": " + $_.Groups[2].Value.Trim() }) -join "`n"
  $bichos = CriaturasRelevantes $busca 1200
  $regras = RegrasRelevantes ($busca + " iniciativa combate ataque dano turno defesa condicoes") 1400

  $p = "FICHA DO PERSONAGEM`n$campos`n`n"
  $amigos = AliadosDaMesa 900 $busca
  if ($amigos) { $p += "ALIADOS QUE LUTAM COM O JOGADOR`n$amigos`n`n" }
  if ($bichos) { $p += "FICHA DAS CRIATURAS PRESENTES`n$bichos`n`n" }
  else { $p += "FICHA DAS CRIATURAS PRESENTES`n(nenhuma registrada ainda - monte a ficha das que aparecerem, com FICHA NOVA)`n`n" }
  if ($regras) { $p += "REGRAS QUE VALEM`n$regras`n`n" }
  $p += "DADOS JA ROLADOS, NESTA ORDEM`n$dados`n`n"
  if ($recente) { $p += "O QUE VINHA ACONTECENDO`n" + $recente.Substring([Math]::Max(0, $recente.Length - 700)) + "`n`n" }
  $p += "O JOGADOR QUER`n$entrada`n`nResolva."

  $payload = ConvertTo-Json @{
    model = $Cfg.modelo
    messages = @(@{ role = "system"; content = $CALCULADOR }, @{ role = "user"; content = $p })
    stream = $false
    options = @{ temperature = 0.15; num_ctx = [int]$Cfg.contexto; num_predict = 350 }
    keep_alive = "30m"
  } -Depth 8

  try {
    $r = [Net.HttpWebRequest]::Create("$Ollama/api/chat")
    $r.Method = "POST"; $r.ContentType = "application/json"
    $r.Timeout = 300000; $r.ReadWriteTimeout = 300000
    $pb = $UTF8.GetBytes($payload); $r.ContentLength = $pb.Length
    $os = $r.GetRequestStream(); $os.Write($pb, 0, $pb.Length); $os.Close()
    $resp = (New-Object IO.StreamReader($r.GetResponse().GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
    $intencoes = ([string]$resp.message.content).Trim()

    # ficha nova primeiro: a criatura precisa existir antes de apanhar
    $novas = GravarFichasNovas $intencoes
    foreach ($nf in $novas) { Write-Host ("   ficha nova: " + $nf) -ForegroundColor DarkCyan }

    # a conta e aqui, com as fichas de verdade e os dados que eu sorteei
    $resolvido = ResolverCombate $intencoes $dados $busca $entrada
    if ($resolvido) { return $resolvido }
    $intencoes
  } catch {
    Write-Host ("   calculadora falhou: " + $_.Exception.Message) -ForegroundColor DarkYellow
    ""
  }
}


# O juiz monta ficha de criatura que ainda nao existe. Aqui ela vira arquivo,
# pra valer pro resto da campanha em vez de ser reinventada toda briga com
# numeros diferentes.
function GravarFichasNovas([string]$mecanica) {
  $feitas = @()
  if (-not $mecanica) { return $feitas }
  # O juiz devolve so o julgamento: nome, Kleos, arquetipo e as defesas fortes.
  # Os numeros saem da Tabua, aqui, com aritmetica de verdade.
  foreach ($m in [Regex]::Matches($mecanica, '(?im)^\s*FICHA\s+NOVA\s*:\s*(.+?)\s*$')) {
    $cab = $m.Groups[1].Value
    $nome = $cab; $kleos = 2; $arq = ""; $fortes = ""; $chaves = ""
    foreach ($p in ($cab -split '\|')) {
      $p = $p.Trim()
      if ($p -match '(?i)^kleos\s*[:=]\s*(\d+)')      { $kleos  = [int]$Matches[1]; continue }
      if ($p -match '(?i)^arquetipo\s*[:=]\s*(.+)$')  { $arq    = $Matches[1].Trim(); continue }
      if ($p -match '(?i)^fortes?\s*[:=]\s*(.+)$')    { $fortes = $Matches[1].Trim(); continue }
      if ($p -match '(?i)^chaves\s*[:=]\s*(.+)$')     { $chaves = $Matches[1].Trim(); continue }
      if ($p -notmatch '[:=]') { $nome = $p }
    }
    if (-not $nome) { continue }
    $arqv = Join-Path $DirCriaturas ((Slug $nome) + ".md")
    if (Test-Path -LiteralPath $arqv) { continue }
    $c = ForjarCriatura $nome $kleos $arq $fortes $chaves
    Gravar $arqv $c.texto
    $feitas += $c.resumo
  }
  $feitas
}

# ------------------------------------------------------------- HTTP helpers

# Sem cabecalho de cache o navegador guardava /api/estado e o ui.html. Trocar
# de campanha parecia nao limpar os livros: a lista vinha do cache, nao do
# disco. O servidor e local, entao cache aqui nao economiza nada e so engana.
function Responder($resp, $codigo, $tipo, $corpo) {
  $b = $UTF8.GetBytes([string]$corpo)
  $resp.StatusCode = $codigo
  try {
    $resp.Headers['Cache-Control'] = 'no-store, no-cache, must-revalidate'
    $resp.Headers['Pragma'] = 'no-cache'
    $resp.Headers['Expires'] = '0'
  } catch {}
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
      $entradaOriginal = $entrada

      # /iniciar campanha e a virada de chave: antes disso e conversa, depois
      # entra tudo - dado, ficha, diario, aliado com turno proprio.
      $comecouAgora = $false
      if (-not $script:Iniciada -and $entrada -match '(?i)^\s*/\s*iniciar\b') {
        Gravar $script:ArqInicio ((Get-Date).ToString('yyyy-MM-dd HH:mm'))
        $script:Iniciada = $true
        $comecouAgora = $true
        $entrada = 'Abra a primeira cena da campanha, onde o personagem esta agora.'
        Write-Host "   a campanha comecou" -ForegroundColor Green
      }

      $resp.ContentType = "text/event-stream; charset=utf-8"
      $resp.Headers.Add("Cache-Control", "no-cache")
      $resp.SendChunked = $true
      $sw = New-Object IO.StreamWriter($resp.OutputStream, $UTF8)
      $sw.AutoFlush = $true

      try {
        # 1 de 3: o juiz resolve os numeros antes de qualquer narracao
        # (so depois de /iniciar campanha - no modo conversa nao se rola nada)
        $rng = New-Object Random
        $sorteados = @(1..8 | ForEach-Object { $rng.Next(1, 21) })
        # se o jogador rolou o proprio dado e informou ("ataco com as correntes / 20"),
        # esse valor vale primeiro. O dado da mesa e dele, nao meu.
        # numero sozinho numa linha, ou marcado com "rolei/tirei/d20".
        # Numero no meio de frase nao conta: "3 capangas" e "20 metros" nao sao dado.
        $meu = [Regex]::Match($entrada, '(?im)(?:^[ \t]*(\d{1,2})[ \t]*$|\b(?:rolei|tirei|deu|saiu|dado|d20)[ \t]*:?[ \t]*(\d{1,2})\b)')
        if ($meu.Success) {
          $v = [int]$(if ($meu.Groups[1].Success) { $meu.Groups[1].Value } else { $meu.Groups[2].Value })
          if ($v -ge 1 -and $v -le 20) {
            $sorteados = @($v) + $sorteados
            Write-Host ("   dado do jogador: " + $v) -ForegroundColor DarkCyan
          }
        }
        $script:DadosDaVez = ($sorteados -join ", ")
        $mecanica = ""
        # ATENCAO ao parenteses: sem o par externo o PowerShell chama a funcao so com
        # o historico e concatena $entrada no RESULTADO - a acao do jogador nunca
        # chegava, e na primeira jogada a calculadora nem rodava.
        $textoDaCena = (($Historico | Select-Object -Last 4 | ForEach-Object { $_.texto }) -join " ") + " " + $entrada
        if ($script:Iniciada -and -not $diretor -and (CenaTemRisco $textoDaCena)) {
          $sw.Write("event: calculando`ndata: {}`n`n")
          # CalcularCena ja grava a ficha nova e ja resolve os numeros
          $mecanica = CalcularCena $entrada $script:DadosDaVez
          if ($mecanica) { Write-Host ("   mecanica: " + ($mecanica -replace "`r?`n", " | ").Substring(0, [Math]::Min(110, $mecanica.Length))) -ForegroundColor DarkGray }
        }

        # 2 de 3: narrar
        if ($script:Iniciada) {
          $msgs = MontarMensagens $entrada $diretor $mecanica
        } else {
          # modo conversa: so o papo e o historico, sem lorebook nem ficha
          $msgs = New-Object Collections.ArrayList
          [void]$msgs.Add(@{ role = 'system'; content = $CONVERSA })
          foreach ($h in @($Historico | Select-Object -Last $MaxHist)) {
            [void]$msgs.Add(@{ role = [string]$h.papel; content = [string]$h.texto })
          }
          [void]$msgs.Add(@{ role = 'user'; content = $entrada })
        }
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

        # no modo conversa o nome fica vazio de proposito: sem corte de fala e
        # sem a linha de devolver a vez, que ali nao faz sentido nenhum.
        $nomeJog = ''
        if ($script:Iniciada -and (Ler (Join-Path $Campanha '02-personagem.md')) -match '(?im)^\s*-\s*nome\s*:\s*(.+)$') { $nomeJog = $Matches[1].Trim() }
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
        $bloco = ''
        $mudou = @()
        if ($script:Iniciada) {
          $sw.Write("event: anotando`ndata: {}`n`n")
          # 3 de 3: anotar
          $bloco = PedirBloco $narracao
          $mudou = AplicarAtualizacao $bloco $diretor
        }

        $Historico += @{ papel = "user";      texto = $entradaOriginal }
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
