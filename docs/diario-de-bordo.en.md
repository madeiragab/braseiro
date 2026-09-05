> 🇧🇷 [Português](diario-de-bordo.md) · 🇬🇧 **English**

# Build log

What was measured, what broke, and what changed because of it. It's here because
nearly every decision in this project came from a number, not a hunch.

---

## The machine that shaped the project

First thing measured, before a line was written:

```
CPU    Intel i5-10300H, 4 cores / 8 threads
RAM    15.8 GB
GPU    NVIDIA GeForce GTX 1650
Screen Intel UHD Graphics
```

And then, straight from Ollama's own log:

```
library=CUDA compute=7.5 name="NVIDIA GeForce GTX 1650" driver=13.4
type=discrete total="4.0 GiB" available="3.2 GiB"
msg="vram-based default context" default_num_ctx=4096
```

**4 GB on paper, 3.2 GB usable.** That 800 MB gap moved the default `contexto`
from 8192 down to 6144. The original estimate of 8192 assumed the full 4 GB was
free — the display runs on the Intel chip, so the 1650 should be idle. It was,
but the driver reserves part of the memory regardless.

Lesson: don't estimate VRAM. Start the engine and read the log.

---

## Why PowerShell, not Python

The machine had neither Python nor Node. Installing a runtime would have
destroyed the portability premise.

Tested before deciding:

```powershell
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://localhost:17777/")
$l.Start()      # → works without administrator privileges
```

That settled everything at once: an HTTP server, serving the page, and talking to
Ollama — with nothing installed and no CORS.

The alternative considered was a static page using the browser's File System
Access API to read and write the files directly. Dropped: Chrome blocks
`showDirectoryPicker()` on `file://`, so a local server would have been needed
anyway.

## Why not SillyTavern

It's the right tool for local roleplay and has a mature lorebook. Two reasons not
to use it:

1. it needs Node installed — that kills portability;
2. it doesn't write to the campaign. It **reads** a lorebook; it doesn't generate
   a new fact and save it.

Automatic writing was the central requirement. Building was cheaper than adapting.

---

## The CUDA zip that doesn't exist

An instruction given confidently, and **wrong**: download
`ollama-windows-amd64-cuda-v12.zip`.

It doesn't exist. Checking the GitHub API, release v0.33.3:

```
ollama-windows-amd64.zip          1,401 MB   ← CUDA is inside this one
ollama-windows-amd64-rocm.zip       236 MB   ← AMD only
ollama-windows-arm64.zip            201 MB
```

The size alone tells the story: 1.4 GB against ROCm's 236 MB. NVIDIA support is
bundled into the main zip.

Lesson: release asset names change. Query the API, not your memory.

---

## The 96-second timeout

The most valuable find of the whole build. Log from the first `ollama serve` run
off the flash drive:

```
19:48:42  msg="discovering available GPUs..."
19:50:18  msg="llama-server GPU discovery watchdog timed out"
          OLLAMA_LIBRARY_PATH="[...\lib\ollama, ...\lib\ollama\cuda_v12]"
          error="context deadline exceeded"
19:50:21  msg="inference compute" ... libdirs=ollama,cuda_v13 driver=13.4
```

The zip ships **two** CUDA runtimes. The machine's driver is 13.4, so Ollama uses
`cuda_v13` — but it tries `cuda_v12` first, and loading 1.1 GB of DLLs off a
flash drive blows past the watchdog. **96 seconds lost on every launch.**

Deleting `bin/lib/ollama/cuda_v12`:

| | before | after |
|---|---|---|
| GPU ready in | 99.0 s | **4.6 s** |
| disk space | — | **+1.1 GB** |

The honest caveat: on a PC with an older NVIDIA driver (12.x series), `cuda_v12`
is needed and Ollama would fall back to CPU without it. Just re-extract that
folder from the zip.

---

## PowerShell 5.1 reads `.ps1` as ANSI

This cost a full debugging cycle.

A test kept failing, claiming the server delivered corrupted HTML. The bytes on
the wire were perfect — 10,784 of them, with `O que você faz` perfectly legible.
What was corrupted was the **literal inside the test script itself**.

Windows PowerShell 5.1 reads `.ps1` files as ANSI/Windows-1252 when there is no
BOM. Every accented literal turns to garbage, **with no error at all**: `-match`
simply stops matching.

Two defenses adopted:

- the `.ps1` files are written as UTF-8 **with BOM**;
- the code is kept accent-free, with accented text living in data files read with
  an explicit encoding.

This applies to 5.1. PowerShell 7+ assumes UTF-8 and doesn't suffer from it.

---

## Bugs the tests caught

### The lore split in two

The model writes "Gorm" on one turn and "Gorm Martelo-Torto" on the next. Slugging
the name produced `gorm.md` and `gorm-martelo-torto.md` — same person, two files,
half the facts invisible whenever only one was retrieved.

Fixed by comparing key sets before creating a file: if they intersect, reuse it
and accumulate the keys.

### Stacked headings

After the merge, the file looked like this:

```markdown
**Gorm Martelo-Torto**
**Gorm**
Dwarf blacksmith of Vallengard...
```

The cleanup only removed the exact title of the current name. It now removes any
line that is nothing but `**bold text**`.

### The filename pulled the whole book

This was the worst one. The book index took terms from the file path with the
same weight as the heading. The result, in a file named `testes-e-perigos.md`:

```
Testes de atributo  <- exempl, testes, perigo, atribu, teste, ...
Armadilhas          <- exempl, testes, perigo, armadi, desarm, ...
Combate             <- exempl, testes, perigo, combat, inicia, ...
Descanso            <- exempl, testes, perigo, descan, dormir, ...
```

Saying "teste" would pull all four sections at once and burn the entire budget.

Fixed by separating strong terms (heading + `chaves:`, which fire a section) from
weak ones (the path, which only contributes to the score).

### The rule nobody could find

A failing test, and the failure was correct:

```
'saco a espada e parto pra cima do orc'  →  []
```

Not one word in that sentence is "combat". The system was right; the **content**
was badly written. That's what turned the `chaves:` line from an optional detail
into the single most important thing in the rulebook documentation.

---

## Reading PDF with no dependencies

Adding a library would have broken the project's premise, so the extractor is
written by hand in `mestre/pdf.ps1`.

The parts that actually needed care:

- **FlateDecode is zlib, and `DeflateStream` only speaks raw deflate.** Skipping
  the 2-byte header makes it work; the trailing Adler-32 is simply ignored.
- **Octal escapes** are what make `cora\347\343o` come out as `coração`.
- **`TJ` arrays** carry kerning between string fragments. Without turning a value
  below -100 into a space, `[(Att) -300 (ack)] TJ` reads as `Attack` glued to the
  next word.
- **PDFs have no `##`.** Without promoting headings, a whole book would become
  untitled chunks — and untitled chunks are unreachable, since only strong terms
  fire. Hence promoting short ALL-CAPS or blank-line-isolated lines, plus deriving
  terms from the chunk text as a fallback.

It refuses rather than degrade: a scanned PDF and a private-encoding font both
produce a `.pdf.aviso` and index nothing.

Tested against PDFs generated inside the test itself — uncompressed, FlateDecode,
image-only and deliberately unreadable — because that's the only way to exercise
all four paths deterministically.

---

## Platform traps

**`-LiteralPath` doesn't expand wildcards.** `Copy-Item -LiteralPath "folder\*"`
copies zero files and **raises no error**. The `*` is treated as a literal name.

**MAX_PATH still exists.** `Bitmap.Save()` to a path over 260 characters fails
with "generic GDI+ error", never mentioning that length is the problem. `git init`
in a deep folder fails the same way, on `.git/objects` — fixed with
`core.longpaths`.

**`BinaryWriter.Write($byteArray)`** with an array built through `+=` in
PowerShell doesn't bind to the right overload: the `.ico` came out at 118 bytes —
exactly the header, zero content. Fixed with an explicit `[byte[]]` cast,
`Write($arr, 0, $arr.Length)`, and a size assertion.

**PowerShell variables are case-insensitive.** A loop using `$r` silently wiped
`$R`, which held the repository path.

**`Invoke-RestMethod` against `127.0.0.1` can hit the system proxy** and time out.
`Net.WebClient` went straight through.

---

## The `.gguf` that doesn't fit

`ollama create` **copies** the file into its store — it doesn't move or reference
it. Downloading a 7 GB GGUF straight onto a flash drive with 13.7 GB free would
mean 14 GB during the import. It doesn't fit.

That's why `IMPORTAR-MODELO.bat` looks for the file in `Downloads` (on C:), checks
free space at the destination before starting, and reminds you to delete the
original afterwards.

---

## What was left out, and why

| idea | why not |
|---|---|
| semantic search with embeddings | another model resident in VRAM; there's none to spare in 3.2 GB |
| `autorun.inf` for the drive icon | classic virus signature; antivirus quarantines it |
| auto-execution on plug-in | disabled in Windows since 2009, no safe workaround |
| OCR for scanned PDFs | would need a real dependency; "save as text" covers it |
| JSON in the hidden block | 8-12B models get JSON wrong; text delimiters tolerate errors |
| native tool calling | roleplay finetunes usually lose that capability |
