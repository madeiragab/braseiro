> 🇧🇷 **Português** · 🇬🇧 [English](livros.en.md)

# Os livros do sistema

## Onde

**O jeito curto: arraste os arquivos pra cima da janela do Braseiro.** Ele guarda
na campanha aberta, converte o PDF na hora, indexa e te responde no chat dizendo
o que entrou e o que não deu. O botão **📚 adicionar livros do sistema** no painel
faz o mesmo escolhendo pelo Explorador.

Na mão, é dentro da pasta da campanha, em `Documentos/Braseiro/<sua campanha>/`.
Pode ter quantas subpastas você quiser:

```
Documentos/Braseiro/minha-campanha/livros/
├── dnd5e/
│   ├── combate.md
│   ├── magias.md
│   └── condicoes.md
├── tormenta/
│   └── pericias.md
└── meu-cenario/
    └── panteao/
        └── deuses.md
```

Formatos aceitos: **`.pdf`**, `.md`, `.markdown` e `.txt`.

## PDF

Solte o `.pdf` na pasta. Na primeira vez ele vira um `.pdf.txt` do lado, e dali
em diante é texto como qualquer outro. A conversão só refaz se você trocar o PDF.

Livro grande demora — e a conversão travaria a primeira jogada em silêncio. Pra
esses, rode **`CONVERTER-PDF.bat`** antes: converte tudo mostrando progresso.

O `.pdf.txt` é um arquivo comum. **Vale muito a pena abrir e arrumar**: apagar
índice e ficha técnica, ajustar onde o corte de seção ficou errado, e principalmente
acrescentar linhas `chaves:` embaixo dos títulos.

### O que funciona e o que não

| PDF | resultado |
|---|---|
| gerado por editor de texto, LaTeX, InDesign | ✅ extrai |
| comprimido em FlateDecode (a maioria) | ✅ extrai |
| **escaneado** (página é foto) | ❌ não tem texto por baixo; só com OCR |
| fonte com codificação própria, sem mapa `ToUnicode` | ❌ sairia garrancho |

Quando não dá, aparece um `.pdf.aviso` ao lado explicando o motivo, e **nada é
indexado daquele arquivo**. Isso é de propósito: meio livro em garrancho estraga
mais a campanha do que livro nenhum. A aba **livros** no painel lista os dois casos.

Pros que não deram: no leitor de PDF use "Salvar como" → texto, ou copie e cole
só o capítulo que interessa. Quase sempre fica melhor mesmo — livro de RPG é
cheio de arte, índice e tabela que viram ruído.

### Como a extração acha os títulos

PDF não tem `##`. Então o conversor promove a título as linhas curtas (até 60
caracteres) que não terminam em pontuação e estão em CAIXA ALTA ou isoladas por
linha em branco — que é como capítulo de livro de RPG costuma aparecer.

Quando nenhum título é detectado num pedaço, as palavras-chave saem do **próprio
texto** do pedaço (as mais repetidas). Sem isso, texto sem título ficaria
inalcançável, porque só termo forte dispara uma seção.

## Como cortar

Títulos com `#` marcam as seções. Cada seção vira uma entrada indexada
independente.

```markdown
# Combate

## Iniciativa
chaves: iniciativa, ordem, surpresa, emboscada

Role 1d20 + Destreza, do maior pro menor...

## Ataque
chaves: ataque, atacar, acertar, espada, arma, golpe, bater

1d20 + modificador contra a CA do alvo...

## Morrendo
chaves: morrer, morte, inconsciente, caido, sangrando, estabilizar

A 0 pontos de vida o personagem cai...
```

Arquivo **sem nenhum título** também funciona: é fatiado sozinho em pedaços de
~1200 caracteres, cortando em fim de linha. Serve pra colar um capítulo cru e
resolver depois.

Seção **maior que 1200 caracteres** é fatiada do mesmo jeito, e os pedaços ficam
numerados: `Ataque`, `Ataque (2)`, `Ataque (3)`.

## `chaves:` é o que faz funcionar

Esta é a parte que decide se o sistema serve ou não.

O título sozinho não basta. **Ninguém digita "combate" jogando.** Você escreve:

> *saco a espada e parto pra cima do orc*

Nenhuma palavra dessa frase é "combate". Sem `chaves:`, a regra não é encontrada.

```markdown
## Combate
chaves: combate, ataque, atacar, dano, ferido, espada, arma, golpe,
        luta, briga, matar, inimigo, orc, machado, escudo
```

Regra prática: **escreva a lista pensando no que você diria na mesa**, não no
que está escrito no livro. Seja generoso — uma chave a mais custa quase nada,
uma chave a menos custa a regra inteira.

### Como o casamento funciona

Os termos são normalizados (sem acento, minúsculo) e **truncados em 6
caracteres**. Isso resolve plural e conjugação sem esforço:

| você escreveu | vira | casa com |
|---|---|---|
| `armadilha` | `armadi` | armadilha, armadilhas |
| `desarmar` | `desarm` | desarmar, desarmo, desarmei |
| `magia` | `magia` | magia, magias |

Termos com menos de 4 caracteres são descartados, e palavras vazias
(`de`, `da`, `para`, `regra`, `tabela`...) também.

### Forte e fraco

| origem | peso | dispara sozinho? |
|---|---|---|
| título da seção | forte (×3) | ✅ |
| linha `chaves:` | forte (×3) | ✅ |
| nome do arquivo e das pastas | fraco (×1) | ❌ |

O caminho do arquivo pesa pouco **de propósito**. Se pesasse igual, um arquivo
chamado `combate.md` faria a palavra "combate" puxar todas as seções dele de uma
vez e entupir o contexto.

## Orçamento

Por jogada, no máximo:

- **4 seções**
- **2600 caracteres** (~700 tokens)

O que passar disso é descartado, começando pelas seções de menor pontuação. Por
isso vale cortar em seções pequenas e específicas: três seções de 400 caracteres
cabem melhor e são mais úteis que uma de 1200.

## Conferindo

A aba **livros** no painel da direita mostra o índice: quantas seções, de quais
arquivos, com que títulos. Se uma seção que você esperava não está listada, o
corte não pegou — provavelmente o título não começa com `#`.

Salvou um arquivo novo? Ele entra no índice na jogada seguinte. Não precisa
reiniciar nada: o índice se refaz sozinho quando detecta que a data de
modificação de algum arquivo mudou.

## Sobre direitos autorais

O que você põe na pasta `livros/` da sua campanha fica no seu computador, é lido
só pela sua máquina e não vai pra lugar nenhum. Este repositório não distribui livro de
sistema nenhum — o exemplo em `livros/exemplo-d20/` é texto original escrito pra
demonstrar o formato.
