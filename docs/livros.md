# Os livros do sistema

## Onde

`campanha/livros/`, com quantas subpastas você quiser:

```
campanha/livros/
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

Formatos aceitos: `.md`, `.markdown`, `.txt`. **PDF não.**

Pra converter: no leitor de PDF, "Salvar como" → texto. Ou copie e cole só o
capítulo que interessa — quase sempre é melhor, porque livro de RPG é cheio de
arte, índice e tabela que viram ruído.

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

O que você põe em `campanha/livros/` fica no seu pendrive, é lido só pela sua
máquina e não vai pra lugar nenhum. Este repositório não distribui livro de
sistema nenhum — o exemplo em `livros/exemplo-d20/` é texto original escrito pra
demonstrar o formato.
