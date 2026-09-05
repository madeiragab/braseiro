# Extracao de texto de PDF em PowerShell puro, sem dependencia nenhuma.
#
# Da conta de PDF "digital" (gerado por editor de texto/LaTeX/InDesign), que e o
# caso da maioria dos livros de RPG vendidos hoje. NAO da conta de PDF escaneado:
# ali as paginas sao imagem e nao existe texto pra extrair - precisaria de OCR.
#
# O que a funcao faz: acha os content streams, descomprime o que estiver em
# FlateDecode, e percorre os operadores de texto do PDF juntando o que for string.

function InflarZlib([byte[]]$dados) {
  # FlateDecode e zlib: 2 bytes de cabecalho + deflate cru.
  # O DeflateStream do .NET so entende deflate cru, entao pulamos os 2 bytes.
  foreach ($pulo in @(2, 0)) {
    try {
      $ent = New-Object IO.MemoryStream(, $dados)
      $ent.Position = $pulo
      $ds  = New-Object IO.Compression.DeflateStream($ent, [IO.Compression.CompressionMode]::Decompress)
      $sai = New-Object IO.MemoryStream
      $ds.CopyTo($sai)
      $ds.Dispose(); $ent.Dispose()
      $b = $sai.ToArray(); $sai.Dispose()
      if ($b.Length -gt 0) { return $b }
    } catch { }
  }
  $null
}

# ------------------------------------------------------------------ ToUnicode
#
# Fonte embutida vem com subconjunto reindexado: o codigo que aparece no content
# stream nao e o Unicode da letra, e o numero do glifo dentro do subconjunto. O
# PDF carrega o caminho de volta no /ToUnicode de cada fonte. Sem ele o texto sai
# como garrancho e so resta adivinhar deslocamento; com ele sai exato, acento
# incluso.
#
# O detalhe que custou caro: fonte /Subtype /Type0 com /Encoding /Identity-H usa
# codigo de DOIS bytes. Lendo byte a byte, o byte alto virava um caractere solto
# entre cada letra - o texto parecia "e s p a c a d o" e nao era.

function _hexUtf16([string]$h) {
  if ($h.Length % 4 -ne 0) { $h = $h.PadLeft(([int][Math]::Ceiling($h.Length / 4.0)) * 4, '0') }
  $sb = New-Object Text.StringBuilder
  for ($k = 0; $k -lt $h.Length; $k += 4) {
    [void]$sb.Append([char][Convert]::ToInt32($h.Substring($k, 4), 16))
  }
  $sb.ToString()
}

# objNum -> @{ dic; ini; len }.  ini/len apontam pro stream cru; ini = -1 se nao tem.
function IndexarObjetos([string]$s) {
  $ix = @{}
  foreach ($m in [Regex]::Matches($s, '(?<![0-9])(\d+)\s+\d+\s+obj\b')) {
    $num = [int]$m.Groups[1].Value
    $ini = $m.Index + $m.Length
    $fimObj = $s.IndexOf('endobj', $ini)
    if ($fimObj -lt 0) { $fimObj = [Math]::Min($s.Length, $ini + 200000) }
    $st = $s.IndexOf('stream', $ini)
    if ($st -ge 0 -and $st -lt $fimObj) {
      $d = $st + 6
      if ($d -lt $s.Length -and $s[$d] -eq "`r") { $d++ }
      if ($d -lt $s.Length -and $s[$d] -eq "`n") { $d++ }
      $e = $s.IndexOf('endstream', $d)
      $ix[$num] = @{
        dic = $s.Substring($ini, $st - $ini)
        ini = $(if ($e -ge 0) { $d } else { -1 })
        len = $(if ($e -ge 0) { $e - $d } else { 0 })
      }
    } else {
      $ix[$num] = @{ dic = $s.Substring($ini, $fimObj - $ini); ini = -1; len = 0 }
    }
  }
  $ix
}

# Le um CMap /ToUnicode ja descomprimido: codigo do glifo -> texto de verdade.
function LerCMapToUnicode([string]$t) {
  $mapa = @{}
  $largura = 2
  $cs = [Regex]::Match($t, '(?s)begincodespacerange(.*?)endcodespacerange')
  if ($cs.Success) {
    $h = [Regex]::Match($cs.Groups[1].Value, '<([0-9A-Fa-f]+)>')
    if ($h.Success) { $largura = [Math]::Max(1, [int]($h.Groups[1].Value.Length / 2)) }
  }
  foreach ($blk in [Regex]::Matches($t, '(?s)beginbfchar(.*?)endbfchar')) {
    foreach ($m in [Regex]::Matches($blk.Groups[1].Value, '<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>')) {
      $mapa[[Convert]::ToInt32($m.Groups[1].Value, 16)] = _hexUtf16 $m.Groups[2].Value
    }
  }
  foreach ($blk in [Regex]::Matches($t, '(?s)beginbfrange(.*?)endbfrange')) {
    $b = $blk.Groups[1].Value
    # <lo> <hi> <destino> : o destino anda junto com o codigo
    foreach ($m in [Regex]::Matches($b, '<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')) {
      $lo = [Convert]::ToInt32($m.Groups[1].Value, 16)
      $hi = [Convert]::ToInt32($m.Groups[2].Value, 16)
      $dh = $m.Groups[3].Value
      if ($hi -lt $lo -or ($hi - $lo) -gt 65535) { continue }
      if ($dh.Length -gt 4) { $mapa[$lo] = _hexUtf16 $dh; continue }
      $dst = [Convert]::ToInt32($dh, 16)
      for ($k = $lo; $k -le $hi; $k++) { $mapa[$k] = [string][char]($dst + ($k - $lo)) }
    }
    # <lo> <hi> [ <d1> <d2> ... ] : um destino por codigo
    foreach ($m in [Regex]::Matches($b, '(?s)<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[(.*?)\]')) {
      $k = [Convert]::ToInt32($m.Groups[1].Value, 16)
      foreach ($d in [Regex]::Matches($m.Groups[3].Value, '<([0-9A-Fa-f]*)>')) {
        $mapa[$k] = _hexUtf16 $d.Groups[1].Value
        $k++
      }
    }
  }
  @{ mapa = $mapa; largura = $largura }
}

# "/F44" -> @{ mapa; largura }, varrendo os dicionarios de recurso do arquivo.
function MapearFontes([string]$s, [byte[]]$bytes, $lat) {
  $ix = IndexarObjetos $s
  $porObj = @{}
  $fontes = @{}
  foreach ($r in [Regex]::Matches($s, '(?s)/Font\s*<<(.{0,4000}?)>>')) {
    foreach ($e in [Regex]::Matches($r.Groups[1].Value, '/([A-Za-z0-9_.+\-]+)\s+(\d+)\s+\d+\s+R')) {
      $nome = '/' + $e.Groups[1].Value
      $obj  = [int]$e.Groups[2].Value
      if ($fontes.ContainsKey($nome)) { continue }
      if (-not $porObj.ContainsKey($obj)) {
        $porObj[$obj] = $null
        if ($ix.ContainsKey($obj)) {
          $dicF = $ix[$obj].dic
          $largura = $(if ($dicF -match '/Subtype\s*/Type0' -or $dicF -match '/Identity-H') { 2 } else { 1 })
          $mtu = [Regex]::Match($dicF, '/ToUnicode\s+(\d+)\s+\d+\s+R')
          if ($mtu.Success) {
            $oc = [int]$mtu.Groups[1].Value
            if ($ix.ContainsKey($oc) -and $ix[$oc].ini -ge 0 -and $ix[$oc].len -gt 0) {
              $cru = New-Object byte[] $ix[$oc].len
              [Array]::Copy($bytes, $ix[$oc].ini, $cru, 0, $ix[$oc].len)
              $dados = $(if ($ix[$oc].dic -match '/FlateDecode') { InflarZlib $cru } else { $cru })
              if ($dados) {
                $cm = LerCMapToUnicode ($lat.GetString($dados))
                if ($cm.mapa.Count -gt 0) { $porObj[$obj] = @{ mapa = $cm.mapa; largura = $cm.largura } }
              }
            }
          }
          # Type0 sem ToUnicode: pelo menos junta os pares de bytes direito
          if ($null -eq $porObj[$obj] -and $largura -eq 2) { $porObj[$obj] = @{ mapa = @{}; largura = 2 } }
        }
      }
      if ($porObj[$obj]) { $fontes[$nome] = $porObj[$obj] }
    }
  }
  $fontes
}

# Traduz os bytes crus de uma string do content stream usando a fonte da vez.
function _decodStr([string]$raw, $f) {
  if ($null -eq $f) { return $raw }
  $temMapa = $f.mapa.Count -gt 0
  if ($f.largura -eq 1 -and -not $temMapa) { return $raw }
  $sb = New-Object Text.StringBuilder
  if ($f.largura -eq 2) {
    for ($k = 0; ($k + 1) -lt $raw.Length; $k += 2) {
      $v = ([int]$raw[$k] -shl 8) -bor [int]$raw[$k + 1]
      if ($temMapa) {
        if ($f.mapa.ContainsKey($v)) { [void]$sb.Append($f.mapa[$v]) }
      }   # sem mapa o id do glifo nao quer dizer nada: melhor nada que sujeira
    }
  } else {
    foreach ($ch in $raw.ToCharArray()) {
      $v = [int]$ch
      if ($f.mapa.ContainsKey($v)) { [void]$sb.Append($f.mapa[$v]) } else { [void]$sb.Append($ch) }
    }
  }
  $sb.ToString()
}

# Percorre um content stream juntando o texto dos operadores Tj / TJ / ' / "
function TextoDeConteudo([string]$c, $fontes) {
  $sb = New-Object Text.StringBuilder
  $fonteAtual = $null
  $ultimoNum = 0.0
  $i = 0
  $n = $c.Length

  while ($i -lt $n) {
    $ch = $c[$i]

    # --- string literal: (texto), com aninhamento e escapes ---
    if ($ch -eq '(') {
      $raw = New-Object Text.StringBuilder
      $i++
      $prof = 1
      while ($i -lt $n -and $prof -gt 0) {
        $c2 = $c[$i]
        if ($c2 -eq '\') {
          $i++
          if ($i -ge $n) { break }
          $e = $c[$i]
          if ($e -eq 'n')      { [void]$raw.Append("`n") }
          elseif ($e -eq 'r')  { [void]$raw.Append("`n") }
          elseif ($e -eq 't')  { [void]$raw.Append("`t") }
          elseif ($e -eq '(')  { [void]$raw.Append('(') }
          elseif ($e -eq ')')  { [void]$raw.Append(')') }
          elseif ($e -eq '\')  { [void]$raw.Append('\') }
          elseif ($e -match '[0-7]') {
            $oct = [string]$e
            while ($oct.Length -lt 3 -and ($i + 1) -lt $n -and $c[$i + 1] -match '[0-7]') { $i++; $oct += $c[$i] }
            [void]$raw.Append([char][Convert]::ToInt32($oct, 8))
          }
          elseif ($e -eq "`n" -or $e -eq "`r") { }   # quebra de linha escapada: some
          else { [void]$raw.Append($e) }
          $i++
        }
        elseif ($c2 -eq '(') { $prof++; [void]$raw.Append('('); $i++ }
        elseif ($c2 -eq ')') { $prof--; if ($prof -gt 0) { [void]$raw.Append(')') }; $i++ }
        else { [void]$raw.Append($c2); $i++ }
      }
      [void]$sb.Append((_decodStr $raw.ToString() $fonteAtual))
      continue
    }

    # --- dicionario << >>: pula inteiro, com aninhamento ---
    if ($ch -eq '<' -and ($i + 1) -lt $n -and $c[$i + 1] -eq '<') {
      $prof = 0
      while ($i -lt $n) {
        if ($c[$i] -eq '<' -and ($i + 1) -lt $n -and $c[$i + 1] -eq '<') { $prof++; $i += 2; continue }
        if ($c[$i] -eq '>' -and ($i + 1) -lt $n -and $c[$i + 1] -eq '>') { $prof--; $i += 2; if ($prof -le 0) { break }; continue }
        $i++
      }
      continue
    }

    # --- string hexadecimal: <48656C6C6F>  (mas nao o dicionario <<) ---
    if ($ch -eq '<' -and ($i + 1) -lt $n -and $c[$i + 1] -ne '<') {
      $fim = $c.IndexOf('>', $i)
      if ($fim -lt 0) { break }
      $hex = ($c.Substring($i + 1, $fim - $i - 1) -replace '[^0-9A-Fa-f]', '')
      if ($hex.Length % 2 -eq 1) { $hex += '0' }
      $raw = New-Object Text.StringBuilder
      for ($k = 0; $k -lt $hex.Length; $k += 2) {
        [void]$raw.Append([char][Convert]::ToInt32($hex.Substring($k, 2), 16))
      }
      [void]$sb.Append((_decodStr $raw.ToString() $fonteAtual))
      $i = $fim + 1
      continue
    }

    # --- nome de recurso: /F44 12 Tf troca a fonte da vez ---
    if ($ch -eq '/') {
      $j = $i + 1
      while ($j -lt $n -and $c[$j] -match '[A-Za-z0-9_.+\-]') { $j++ }
      if ($j -gt ($i + 1)) {
        $depois = $c.Substring($j, [Math]::Min(40, $n - $j))
        if ($depois -match '^\s*[\d.\-]+\s+Tf') {
          $nomeF = $c.Substring($i, $j - $i)
          $fonteAtual = $(if ($fontes -and $fontes.ContainsKey($nomeF)) { $fontes[$nomeF] } else { $null })
        }
      }
      $i = $j
      continue
    }

    # --- numero: dentro de [ ] TJ, kerning bem negativo e um espaco ---
    if ($ch -eq '-' -or $ch -eq '.' -or ($ch -ge '0' -and $ch -le '9')) {
      $ini = $i
      while ($i -lt $n -and ($c[$i] -eq '-' -or $c[$i] -eq '.' -or ($c[$i] -ge '0' -and $c[$i] -le '9'))) { $i++ }
      $num = 0.0
      if ([double]::TryParse($c.Substring($ini, $i - $ini), [ref]$num)) {
        $ultimoNum = $num
        if ($num -le -100) { [void]$sb.Append(' ') }   # kerning grande = espaco
      }
      continue
    }

    # --- operadores que trocam de linha ---
    if ($ch -eq 'T' -and ($i + 1) -lt $n) {
      $op = $c.Substring($i, 2)
      if ($op -eq 'T*') { [void]$sb.Append("`n"); $i += 2; continue }
      # o Skia posiciona GLIFO A GLIFO com "tx 0 Td": so e linha nova se o ty andou
      if ($op -eq 'Td' -or $op -eq 'TD') {
        if ($ultimoNum -ne 0) { [void]$sb.Append("`n") }
        $i += 2; continue
      }
    }
    if (($ch -eq "'" -or $ch -eq '"')) { [void]$sb.Append("`n"); $i++; continue }
    if ($ch -eq 'E' -and ($i + 1) -lt $n -and $c.Substring($i, 2) -eq 'ET') { [void]$sb.Append("`n"); $i += 2; continue }

    $i++
  }
  $sb.ToString()
}

# Quanto do texto extraido parece texto de verdade (0 a 1).
# Serve pra detectar PDF com fonte de codificacao propria, que sai como garrancho.

# PDF gerado por jsPDF (e outros) costuma embutir a fonte com um subconjunto
# reindexado: cada glifo vira um codigo deslocado, e sem o mapa ToUnicode o
# texto sai como garrancho. Mas o deslocamento e UNIFORME, entao da pra achar
# por forca bruta: aplica cada deslocamento possivel e ve qual produz portugues.
$PALAVRAS_PT = @(' de ', ' que ', ' para ', ' com ', ' uma ', ' dos ', ' nao ',
                 ' por ', ' mais ', ' como ', ' voce ', ' ele ', ' ela ', ' foi ',
                 ' sao ', ' seu ', ' sua ', ' pode ', ' quando ', ' cada ')

function _pontuarPt([string]$t) {
  if (-not $t -or $t.Length -lt 200) { return 0 }
  $amostra = $t.Substring(0, [Math]::Min(20000, $t.Length))
  $baixo = (SemAcentoSimples $amostra)
  $n = 0
  foreach ($p in $PALAVRAS_PT) {
    $i = 0
    while (($i = $baixo.IndexOf($p, $i)) -ge 0) { $n++; $i += $p.Length; if ($n -gt 400) { break } }
  }
  # normaliza pelo tamanho, senao texto grande ganha sempre
  [math]::Round(1000.0 * $n / $amostra.Length, 3)
}

function SemAcentoSimples([string]$s) {
  ([string]$s).ToLowerInvariant()
}

function _aplicarDeslocamento([string]$t, [int]$d) {
  $sb = New-Object Text.StringBuilder
  foreach ($c in $t.ToCharArray()) {
    $v = [int]$c
    if ($v -ge 1 -and $v -le 126) {
      $n = $v + $d
      if ($n -ge 32 -and $n -le 126) { [void]$sb.Append([char]$n) } else { [void]$sb.Append($c) }
    } else { [void]$sb.Append($c) }
  }
  $sb.ToString()
}

# Devolve o texto corrigido, ou $null se nenhum deslocamento produz portugues.
function CorrigirFonteDeslocada([string]$bruto) {
  # Pontua numa AMOSTRA, nao no livro inteiro. Virar 200 mil caracteres 120
  # vezes so pra descobrir qual deslocamento ganha custava minutos; a amostra
  # decide igual e o texto todo so e convertido uma vez, pro vencedor.
  $amostra = $bruto.Substring(0, [Math]::Min(20000, $bruto.Length))
  $base = _pontuarPt $amostra
  $melhorPonto = [Math]::Max($base, 0.5)   # so vale se for claramente melhor
  $melhorD = 0
  foreach ($d in @(-60..-1) + @(1..60)) {
    $p = _pontuarPt (_aplicarDeslocamento $amostra $d)
    if ($p -gt $melhorPonto) { $melhorPonto = $p; $melhorD = $d }
  }
  if ($melhorD -eq 0) { return $null }
  [pscustomobject]@{
    texto = _aplicarDeslocamento $bruto $melhorD
    deslocamento = $melhorD; pontos = $melhorPonto; antes = $base
  }
}

function QualidadeTexto([string]$t) {
  if (-not $t -or $t.Length -eq 0) { return 0.0 }
  $bons = 0
  foreach ($ch in $t.ToCharArray()) {
    if ([char]::IsLetterOrDigit($ch) -or [char]::IsWhiteSpace($ch) -or ".,;:!?()[]-'`"/%&+=*#$@".IndexOf($ch) -ge 0) { $bons++ }
  }
  [double]$bons / $t.Length
}

# Livro de RPG tem titulo em caixa alta ou linha curta isolada. Promove a "## "
# pra que o indexador do Braseiro consiga cortar em secoes.
function PromoverTitulos([string]$t) {
  $linhas = $t -split "`r?`n"
  $saida = New-Object Collections.ArrayList
  for ($i = 0; $i -lt $linhas.Count; $i++) {
    $l = $linhas[$i].Trim()
    if (-not $l) { [void]$saida.Add(""); continue }

    $letras = ([regex]::Matches($l, '\p{L}')).Count
    $curta  = $l.Length -le 60 -and $letras -ge 3
    $semPonto = $l -notmatch '[.,;:]$'
    $anteriorVazia = ($i -eq 0) -or (-not $linhas[$i - 1].Trim())
    $caixaAlta = ($l -ceq $l.ToUpperInvariant()) -and ($l -match '\p{Lu}')

    if ($curta -and $semPonto -and ($caixaAlta -or $anteriorVazia) -and $l -notmatch '^\d+$') {
      [void]$saida.Add("## " + $l)
    } else {
      [void]$saida.Add($l)
    }
  }
  ($saida -join "`n") -replace "`n{3,}", "`n`n"
}

# "BT|Tj|TJ" solto nao serve de filtro: em stream binario (imagem, perfil de cor
# ICC, fonte embutida) esses pares de bytes aparecem por acaso, e o lixo entrava
# como se fosse texto - foi assim que um perfil ICC do Skia virou "texto" e
# derrubou a qualidade dos livros inteiros. Content stream de verdade e quase
# todo ASCII imprimivel e tem BT e ET como operadores isolados.
function EhContentStream([string]$s) {
  if ($s.Length -lt 20) { return $false }
  $amostra = $s.Substring(0, [Math]::Min(4000, $s.Length))
  $bons = 0
  foreach ($c in $amostra.ToCharArray()) {
    $v = [int]$c
    if (($v -ge 32 -and $v -le 126) -or $v -eq 9 -or $v -eq 10 -or $v -eq 13) { $bons++ }
  }
  if (($bons / $amostra.Length) -lt 0.90) { return $false }   # binario cai aqui
  if ($s -notmatch '(?m)(^|[\s>\]])BT([\s]|$)') { return $false }
  if ($s -notmatch '(?m)(^|[\s>\]])ET([\s]|$)') { return $false }
  $true
}
# Devolve um objeto com o texto e o diagnostico. texto = $null quando nao deu.
function ExtrairTextoPdf([string]$caminho) {
  $bytes = [IO.File]::ReadAllBytes($caminho)
  # Latin-1 mapeia byte->char 1:1, entao os indices batem com os do array
  $lat = [Text.Encoding]::GetEncoding(28591)
  $s = $lat.GetString($bytes)

  $fontes = MapearFontes $s $bytes $lat

  $pedacos = New-Object Collections.ArrayList
  $pos = 0
  $streams = 0
  $inflados = 0

  while ($true) {
    $ini = $s.IndexOf("stream", $pos)
    if ($ini -lt 0) { break }
    # "endstream" tambem casa com "stream": pula
    if ($ini -ge 3 -and $s.Substring($ini - 3, 3) -eq "end") { $pos = $ini + 6; continue }

    $dic = $s.Substring([Math]::Max(0, $ini - 700), [Math]::Min(700, $ini))
    $d = $ini + 6
    if ($d -lt $s.Length -and $s[$d] -eq "`r") { $d++ }
    if ($d -lt $s.Length -and $s[$d] -eq "`n") { $d++ }

    $fim = $s.IndexOf("endstream", $d)
    if ($fim -lt 0) { break }
    $pos = $fim + 9
    $streams++

    # imagem e fonte embutida nao tem texto pra tirar
    if ($dic -match '/Subtype\s*/Image' -or $dic -match '/FontFile' -or
        $dic -match '/ICCBased' -or $dic -match '/Subtype\s*/(XML|Type1C|CIDFontType0C|OpenType)' -or
        $dic -match '/Type\s*/(Metadata|ObjStm|XRef)') { continue }

    $len = $fim - $d
    if ($len -le 0) { continue }

    $cru = New-Object byte[] $len
    [Array]::Copy($bytes, $d, $cru, 0, $len)

    if ($dic -match '/FlateDecode') {
      $dec = InflarZlib $cru
      if ($null -eq $dec) { continue }
      $inflados++
      [void]$pedacos.Add($lat.GetString($dec))
    } elseif ($dic -notmatch '/Filter') {
      [void]$pedacos.Add($lat.GetString($cru))
    }
  }

  $bruto = New-Object Text.StringBuilder
  foreach ($p in $pedacos) {
    if (-not (EhContentStream $p)) { continue }
    [void]$bruto.AppendLine((TextoDeConteudo $p $fontes))
  }

  $txt = $bruto.ToString()
  # limpeza: espaco repetido, linha em branco demais
  foreach ($par in @(@([char]0xFB00,'ff'), @([char]0xFB01,'fi'), @([char]0xFB02,'fl'),
                    @([char]0xFB03,'ffi'), @([char]0xFB04,'ffl'), @([char]0xFB05,'st'), @([char]0xFB06,'st'))) {
    $txt = $txt.Replace([string]$par[0], $par[1])
  }
  $txt = $txt -replace '[ \t]{2,}', ' '
  $txt = $txt -replace '(?m)[ \t]+$', ''
  $txt = $txt -replace "`n{3,}", "`n`n"
  $txt = $txt.Trim()

  $q = QualidadeTexto $txt
  $deslocado = 0
  if ($q -lt 0.85 -and $txt.Length -ge 200) {
    $corr = CorrigirFonteDeslocada $txt
    if ($corr) {
      $txt = $corr.texto
      $deslocado = $corr.deslocamento
      $q = QualidadeTexto $txt
    }
  }

  [pscustomobject]@{
    texto     = $(if ($txt.Length -ge 200 -and $q -ge 0.85) { PromoverTitulos $txt } else { $null })
    bruto     = $txt
    qualidade = [math]::Round($q, 3)
    deslocamento = $deslocado
    streams   = $streams
    inflados  = $inflados
    motivo    = $(
      if ($txt.Length -lt 200 -and $streams -gt 0) { "PDF escaneado (paginas sao imagem) ou fonte sem texto extraivel - precisaria de OCR" }
      elseif ($txt.Length -lt 200) { "nenhum content stream de texto encontrado" }
      elseif ($q -lt 0.85) { "texto saiu como garrancho (fonte com codificacao propria, sem mapa ToUnicode)" }
      else { "" }
    )
  }
}