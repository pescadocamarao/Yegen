# Yegen nativo — iPhone

O **Yegen** é o gerador de Site Rules pro **Yealico**: você cola o
código-fonte (HTML) da página de lista e da página de detalhe de um site,
ele descobre os seletores testando tudo em modo estrito (do mesmo jeito
que o Yealico lê) e monta a rule em JSON, pronta pra importar.

Esta é a **versão nativa pra iPhone (v1.0)** do Yegen — o mesmo motor da
versão web, rodando no aparelho, sem depender de navegador.

## O que tem dentro

Sete abas, em português:

- **Entradas** — nome da rule, URLs e os três HTMLs (lista, detalhe e
  página de vídeo opcional), com botões Colar/Limpar/Copiar e o botão
  **Analisar tudo**. Cole a URL da página 2 sem medo: o motor reconhece
  que é página N, normaliza pra página 1 e monta o modelo de paginação.
- **Lista** — o bloco de itens detectado (assinatura repetida), título,
  capa e idCode com o resultado do teste estrito (ex.: 8/8 itens) e o
  exemplo extraído do item 1. O idCode segue a **lei do seletor mínimo**:
  `a` simples sempre que ele extrai a URL certa.
- **Detalhe** — título (h1 > og:title), capa (og:image ou imagem de
  conteúdo fora dos blocos da lista) emitida com **selector "this"**, e
  os candidatos de vídeo ranqueados: config MacCMS `player_aaaa`, regex
  de corpo **unificada .m3u8/.mp4** com replacement `"$1"` puro (os dois
  padrões do guia: iframe `url=` e barras escapadas), `og:video` e
  `<video>/<source>`. Tocar num candidato troca a escolha — **a seleção
  manual é soberana**. Com vídeo escolhido, a **desc do detalhe espelha
  a URL do stream**, pra conferir a extração dentro do Yealico.
- **Categorias** — o grupo de links de menu/categorias vira as abas
  (`pages`) da rule; desmarque as que não quiser. Links dos próprios
  itens nunca são tratados como categoria.
- **JSON** — a rule montada na ordem canônica (par
  `isEditable`/`isEncrypted` após `version`, `flags` como string e
  `"default"` nas pages, `headers` com Referer quando o stream mora em
  outro host), com botão **Copiar JSON**, mais o relatório **Debug 🐞**
  copiável.
- **Salvos** — testes guardados no aparelho (nome, data, site), pra
  reabrir e continuar depois. Ficam em
  `Documents/yegen-salvos.json`, só no seu iPhone.
- **Guia** — as leis do Yegen em resumo curto.

> A aba **Navegar** (seletor visual tocando na página) e o **Modo
> Wizard** chegam na **v1.1** — a v1.0 é o motor completo de gerar rule.

## Bibliotecas

- **SwiftSoup** (via Swift Package Manager) — parse de HTML e seletores
  CSS; é o equivalente nativo do DOMParser/querySelector da versão web.
- SwiftUI + Foundation (sistema). Nada além disso.

## Como buildar

O projeto é gerado pelo **XcodeGen** a partir do `project.yml`:

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Yegen.xcodeproj -scheme Yegen \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

O repositório já traz o workflow **Build IPA**
(`.github/workflows/build-ipa.yml`): a cada push na `main` (ou disparo
manual), o GitHub Actions gera o projeto, compila sem assinatura e
publica o artifact **Yegen-unsigned-ipa** (`Yegen-unsigned.ipa`).

- Bundle ID: `com.seidao.yegen`
- iOS mínimo: 16.0

## Como instalar no iPhone

1. Baixe o `Yegen-unsigned.ipa` do artifact da build no GitHub.
2. Assine e instale com o **iLoader** (ou ESign/AltStore/SideStore),
   do mesmo jeito que o BaixaVídeos.
3. Abra o app, cole os HTMLs na aba Entradas e gere a rule.

## Ícone

O ícone definitivo (o toque dourado, modelo 2B) é o arquivo:

```
Sources/Yegen/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

(1024×1024, referenciado pelo `AppIcon.appiconset/Contents.json` e pelo
`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` no `project.yml`.) Pra
trocar o ícone, basta substituir esse PNG por outro de 1024×1024 com o
mesmo nome.
