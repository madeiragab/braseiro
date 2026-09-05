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

# Percorre um content stream juntando o texto dos operadores Tj / TJ / ' / "
function TextoDeConteudo([string]$c) {
  $sb = New-Object Text.StringBuilder
  $i = 0
  $n = $c.Length

  while ($i -lt $n) {
    $ch = $c[$i]

    # --- string literal: (texto), com aninhamento e escapes ---
    if ($ch -eq '(') {
      $i++
      $prof = 1
      while ($i -lt $n -and $prof -gt 0) {
        $c2 = $c[$i]
        if ($c2 -eq '\') {
          $i++
          if ($i -ge $n) { break }
          $e = $c[$i]
          if ($e -eq 'n')      { [void]$sb.Append("`n") }
          elseif ($e -eq 'r')  { [void]$sb.Append("`n") }
          elseif ($e -eq 't')  { [void]$sb.Append("`t") }
          elseif ($e -eq '(')  { [void]$sb.Append('(') }
          elseif ($e -eq ')')  { [void]$sb.Append(')') }
          elseif ($e -eq '\')  { [void]$sb.Append('\') }
          elseif ($e -match '[0-7]') {
            $oct = [string]$e
            while ($oct.Length -lt 3 -and ($i + 1) -lt $n -and $c[$i + 1] -match '[0-7]') { $i++; $oct += $c[$i] }
            [void]$sb.Append([char][Convert]::ToInt32($oct, 8))
          }
          elseif ($e -eq "`n" -or $e -eq "`r") { }   # quebra de linha escapada: some
          else { [void]$sb.Append($e) }
          $i++
        }
        elseif ($c2 -eq '(') { $prof++; [void]$sb.Append('('); $i++ }
        elseif ($c2 -eq ')') { $prof--; if ($prof -gt 0) { [void]$sb.Append(')') }; $i++ }
        else { [void]$sb.Append($c2); $i++ }
      }
      continue
    }

    # --- string hexadecimal: <48656C6C6F>  (mas nao o dicionario <<) ---
    if ($ch -eq '<' -and ($i + 1) -lt $n -and $c[$i + 1] -ne '<') {
      $fim = $c.IndexOf('>', $i)
      if ($fim -lt 0) { break }
      $hex = ($c.Substring($i + 1, $fim - $i - 1) -replace '[^0-9A-Fa-f]', '')
      if ($hex.Length % 2 -eq 1) { $hex += '0' }
      for ($k = 0; $k -lt $hex.Length; $k += 2) {
        $v = [Convert]::ToInt32($hex.Substring($k, 2), 16)
        if ($v -ne 0) { [void]$sb.Append([char]$v) }
      }
      $i = $fim + 1
      continue
    }

    # --- numero: dentro de [ ] TJ, kerning bem negativo e um espaco ---
    if ($ch -eq '-' -or $ch -eq '.' -or ($ch -ge '0' -and $ch -le '9')) {
      $ini = $i
      while ($i -lt $n -and ($c[$i] -eq '-' -or $c[$i] -eq '.' -or ($c[$i] -ge '0' -and $c[$i] -le '9'))) { $i++ }
      $num = 0.0
      if ([double]::TryParse($c.Substring($ini, $i - $ini), [ref]$num)) {
        if ($num -le -100) { [void]$sb.Append(' ') }
      }
      continue
    }

    # --- operadores que trocam de linha ---
    if ($ch -eq 'T' -and ($i + 1) -lt $n) {
      $op = $c.Substring($i, 2)
      if ($op -eq 'T*' -or $op -eq 'Td' -or $op -eq 'TD') { [void]$sb.Append("`n"); $i += 2; continue }
    }
    if (($ch -eq "'" -or $ch -eq '"')) { [void]$sb.Append("`n"); $i++; continue }
    if ($ch -eq 'E' -and ($i + 1) -lt $n -and $c.Substring($i, 2) -eq 'ET') { [void]$sb.Append("`n"); $i += 2; continue }

    $i++
  }
  $sb.ToString()
}

# Quanto do texto extraido parece texto de verdade (0 a 1).
# Serve pra detectar PDF com fonte de codificacao propria, que sai como garrancho.
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

# Devolve um objeto com o texto e o diagnostico. texto = $null quando nao deu.
function ExtrairTextoPdf([string]$caminho) {
  $bytes = [IO.File]::ReadAllBytes($caminho)
  # Latin-1 mapeia byte->char 1:1, entao os indices batem com os do array
  $lat = [Text.Encoding]::GetEncoding(28591)
  $s = $lat.GetString($bytes)

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
    if ($dic -match '/Subtype\s*/Image' -or $dic -match '/FontFile') { continue }

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
    if ($p -notmatch 'BT|Tj|TJ') { continue }   # so content stream interessa
    [void]$bruto.AppendLine((TextoDeConteudo $p))
  }

  $txt = $bruto.ToString()
  # limpeza: espaco repetido, linha em branco demais
  $txt = $txt -replace '[ \t]{2,}', ' '
  $txt = $txt -replace '(?m)[ \t]+$', ''
  $txt = $txt -replace "`n{3,}", "`n`n"
  $txt = $txt.Trim()

  $q = QualidadeTexto $txt

  [pscustomobject]@{
    texto     = $(if ($txt.Length -ge 200 -and $q -ge 0.85) { PromoverTitulos $txt } else { $null })
    bruto     = $txt
    qualidade = [math]::Round($q, 3)
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
