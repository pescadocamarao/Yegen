import SwiftUI

/// Aba Guia: as leis do Yegen em resumo curto — as mesmas da versão web.
struct GuideView: View {
    private struct Law: Identifiable {
        var id: String { title }
        let title: String
        let text: String
    }

    private let laws: [Law] = [
        Law(title: "O básico manda", text: "Vídeo se extrai com regex e substituição sobre o corpo do HTML. Replacement \"$1\" puro nos modelos de corpo/config; o sufixo |{source:} só existe em tuplas selector+attr."),
        Law(title: "Seletor mínimo", text: "idCode e âncoras usam a forma mais simples que funciona: 'a' ou 'this'. Seletor composto extrai igual no navegador, mas QUEBRA no app — e o Debug não detecta."),
        Law(title: "Capa do detalhe é \"this\"",
            text: "cover do detailRule e do videoRule saem sempre com selector \"this\" (a função/param do candidato detectado ficam). Com seletor de elemento, a capa do detalhe não resolve no app."),
        Law(title: "Seleção manual soberana", text: "O automático só PRÉ-seleciona. O seu toque num candidato de vídeo manda e nunca é sobrescrito pela análise."),
        Law(title: "desc = URL do vídeo", text: "Com vídeo escolhido, a descrição do detalhe espelha a URL final do stream — dá pra conferir a extração de relance dentro do Yealico."),
        Law(title: "Paginação por comparação", text: "A variável de paginação é o que MUDA entre a página 1 e a 2/3. Você cola a página 2 e o Yegen normaliza pra página 1 e monta o modelo ({pageFormat:/page/{page:}} ou query direta {page:})."),
        Law(title: "Flags são string", text: "Na raiz, \"flags\" é uma string minúscula separada por vírgula — nunca objeto. Cada página em pages leva \"flags\": \"default\"."),
        Law(title: "Nada de nil", text: "Nunca emitir \"nil\"/\"null\" como function. Campo cru de regex vai sem a chave function."),
        Law(title: "Categorias não são itens", text: "Grupo de links cujos destinos são os próprios vídeos da lista NÃO é categoria. Categoria é o menu do site — e toda rule sai com as categorias marcadas virando abas."),
        Law(title: "Tags só se existirem", text: "Site com sistema de tags de verdade ganha tagRule no detalhe + tagSearchRule na raiz. Site sem tags: nada é inventado."),
        Law(title: "Pôster não é stream", text: "Candidato de vídeo igual à capa do detalhe (ou com /plain/rs:fit:) é thumbnail, não vídeo — ele é rebaixado no ranking."),
        Law(title: "Headers Referer", text: "Quando o stream mora em outro host, a raiz ganha \"headers\" com o Referer do site — sem ele, o CDN costuma responder 403."),
    ]

    var body: some View {
        TabScroll(title: "Guia") {
            Text("As leis do Yegen nativo v1.0")
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
            Text("Resumo curto dos contratos provados na bancada. A aba Navegar (seletor visual) e o Modo Wizard chegam na v1.1.")
                .font(.callout)
                .foregroundColor(Theme.textDim)
            ForEach(laws) { law in
                VStack(alignment: .leading, spacing: 5) {
                    Text(law.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Theme.gold)
                    Text(law.text)
                        .font(.callout)
                        .foregroundColor(Theme.textPrimary)
                }
                .panelCard()
            }
        }
    }
}
