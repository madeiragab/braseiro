# Diário de bordo

O que foi medido, o que quebrou, e o que mudou por causa disso. Está aqui porque
quase toda decisão do projeto veio de um número, não de um palpite.

---

## A máquina que definiu o projeto

Primeira coisa medida, antes de escrever qualquer linha:

```
CPU    Intel i5-10300H, 4 núcleos / 8 threads
RAM    15,8 GB
GPU    NVIDIA GeForce GTX 1650
Tela   Intel UHD Graphics
```

E depois, direto do log do Ollama:

```
library=CUDA compute=7.5 name="NVIDIA GeForce GTX 1650" driver=13.4
type=discrete total="4.0 GiB" available="3.2 GiB"
msg="vram-based default context" default_num_ctx=4096
```

**4 GB no papel, 3,2 GB utilizáveis.** Essa diferença de 800 MB mudou o padrão de
`contexto` de 8192 pra 6144. Eu tinha estimado 8192 achando que os 4 GB estavam
livres — a tela roda na Intel, então a 1650 estaria ociosa. Estava, mas o driver
reserva parte da memória de qualquer jeito.

Lição: não estime VRAM. Ligue o motor e leia o log.

---

## Por que PowerShell, e não Python

A máquina não tinha Python nem Node. Instalar runtime destruiria a proposta
de portabilidade.

Testado antes de decidir:

```powershell
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://localhost:17777/")
$l.Start()      # → funciona sem privilégio de administrador
```

Isso resolveu tudo de uma vez: servidor HTTP, servir a página e falar com o
Ollama, sem instalar nada e sem CORS.

A alternativa considerada era uma página estática usando a File System Access API
do navegador pra ler e gravar os arquivos direto. Foi descartada: o Chrome bloqueia
`showDirectoryPicker()` em `file://`, então precisaria de um servidor local de
qualquer jeito.

## Por que não SillyTavern

É a ferramenta certa pra roleplay local e tem lorebook maduro. Duas razões pra
não usar:

1. exige Node instalado — mata a portabilidade;
2. não escreve na campanha. Ele **lê** lorebook; não gera fato novo e grava.

A escrita automática era o requisito central. Foi mais barato construir do que
adaptar.

---

## O zip de CUDA que não existe

Instrução dada com confiança e **errada**: baixar
`ollama-windows-amd64-cuda-v12.zip`.

Não existe. A verificação na API do GitHub, na release v0.33.3:

```
ollama-windows-amd64.zip          1.401 MB   ← CUDA vem dentro
ollama-windows-amd64-rocm.zip       236 MB   ← só AMD
ollama-windows-arm64.zip            201 MB
```

O tamanho já conta a história: 1,4 GB contra 236 MB do ROCm. O suporte a NVIDIA
está embutido no zip principal.

Lição: nome de arquivo de release muda. Consulte a API, não a memória.

---

## O timeout de 96 segundos

O achado mais valioso da montagem. Log do primeiro `ollama serve` rodando do
pendrive:

```
19:48:42  msg="discovering available GPUs..."
19:50:18  msg="llama-server GPU discovery watchdog timed out"
          OLLAMA_LIBRARY_PATH="[...\lib\ollama, ...\lib\ollama\cuda_v12]"
          error="context deadline exceeded"
19:50:21  msg="inference compute" ... libdirs=ollama,cuda_v13 driver=13.4
```

O zip traz **dois** runtimes CUDA. O driver da máquina é 13.4, então o Ollama usa
o `cuda_v13` — mas tenta o `cuda_v12` primeiro, e carregar 1,1 GB de DLL de um
pendrive estoura o watchdog. **96 segundos perdidos a cada abertura.**

Apagar `bin/lib/ollama/cuda_v12`:

| | antes | depois |
|---|---|---|
| GPU pronta em | 99,0 s | **4,6 s** |
| espaço | — | **+1,1 GB** |

A ressalva honesta: em um PC com driver NVIDIA antigo (série 12.x), o `cuda_v12`
faz falta e o Ollama cairia pra CPU. Aí é só reextrair a pasta do zip.

---

## PowerShell 5.1 lê `.ps1` como ANSI

Custou um ciclo inteiro de depuração.

Um teste falhava dizendo que o servidor entregava HTML corrompido. Os bytes na
rede estavam perfeitos — 10.784 bytes, `O que você faz` legível. O que estava
corrompido era o **literal dentro do script de teste**.

Windows PowerShell 5.1 lê arquivos `.ps1` como ANSI/Windows-1252 quando não há
BOM. Todo acento em literal vira lixo, **sem erro nenhum**: o `-match`
simplesmente para de casar.

Duas defesas adotadas:

- os `.ps1` são gravados em UTF-8 **com BOM**;
- o código é mantido sem acentos, com o texto acentuado em arquivos de dados
  lidos com encoding explícito.

Vale pro 5.1. O PowerShell 7+ assume UTF-8 e não sofre disso.

---

## Bugs encontrados pelos testes

### A lore se partia em duas

O modelo escreve "Gorm" numa jogada e "Gorm Martelo-Torto" na outra. O slug do
nome gerava `gorm.md` e `gorm-martelo-torto.md` — mesma pessoa, dois arquivos,
metade dos fatos invisível quando só um fosse recuperado.

Corrigido comparando o conjunto de chaves antes de criar arquivo: se cruza, reusa
e acumula as chaves.

### Cabeçalho empilhado

Depois da fusão, o arquivo ficava assim:

```markdown
**Gorm Martelo-Torto**
**Gorm**
Ferreiro anão de Vallengard...
```

A limpeza removia só o título exato do nome atual. Passou a remover qualquer
linha que seja apenas `**texto em negrito**`.

### O nome do arquivo puxava o livro inteiro

Este era o pior. O índice de livros pegava termos do caminho do arquivo com o
mesmo peso do título. Resultado, num arquivo `testes-e-perigos.md`:

```
Testes de atributo  <- exempl, testes, perigo, atribu, teste, ...
Armadilhas          <- exempl, testes, perigo, armadi, desarm, ...
Combate             <- exempl, testes, perigo, combat, inicia, ...
Descanso            <- exempl, testes, perigo, descan, dormir, ...
```

Dizer "teste" puxaria as quatro seções de uma vez e queimaria o orçamento inteiro.

Corrigido separando termo forte (título + `chaves:`, dispara a seção) de termo
fraco (caminho, só entra na pontuação).

### A regra que ninguém encontrava

Teste que falhou, e a falha estava certa:

```
'saco a espada e parto pra cima do orc'  →  []
```

Nenhuma palavra dessa frase é "combate". O sistema estava correto; o **conteúdo**
é que estava mal escrito. Foi o que transformou a linha `chaves:` de detalhe
opcional em a coisa mais importante da documentação de livros.

---

## Armadilhas de plataforma

**`-LiteralPath` não expande curinga.** `Copy-Item -LiteralPath "pasta\*"` copia
zero arquivos e **não dá erro**. O `*` é tratado como nome literal.

**MAX_PATH ainda existe.** `Bitmap.Save()` num caminho de 260+ caracteres falha
com "Erro genérico de GDI+", sem dizer que o problema é o tamanho do caminho.

**`BinaryWriter.Write($byteArray)`** com um array vindo de `+=` em PowerShell não
liga na sobrecarga certa: o `.ico` saiu com 118 bytes — exatamente o cabeçalho,
zero conteúdo. Resolvido com `[byte[]]` explícito e `Write($arr, 0, $arr.Length)`,
mais uma verificação de tamanho esperado.

**`Invoke-RestMethod` em `127.0.0.1` pode bater no proxy do sistema** e estourar o
timeout. `Net.WebClient` passou direto.

---

## O `.gguf` que não cabe

`ollama create` **copia** o arquivo pro acervo, não move nem referencia. Baixar um
GGUF de 7 GB direto pro pendrive de 13,7 GB livres significaria 14 GB durante a
importação — não cabe.

Por isso o `IMPORTAR-MODELO.bat` procura o arquivo no `Downloads` (no C:), confere
o espaço no destino antes de começar, e no fim lembra de apagar o original.

---

## O que ficou de fora, e por quê

| ideia | por que não |
|---|---|
| busca semântica com embeddings | mais um modelo na VRAM; não sobra em 3,2 GB |
| `autorun.inf` pro ícone do pendrive | assinatura clássica de vírus; antivírus põe em quarentena |
| auto-execução ao plugar | desativado no Windows desde 2009, sem contorno seguro |
| leitura de PDF | exigiria dependência; "salvar como texto" resolve |
| JSON no bloco oculto | modelo de 8-12B erra JSON; delimitador de texto tolera erro |
| tool calling nativo | finetunes de roleplay costumam perder essa capacidade |
