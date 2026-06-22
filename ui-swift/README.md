# M-Engine — App SwiftUI (macOS + iOS)

Cliente multiplataforma do M-Engine: **grava ou seleciona** um áudio, **envia** para a API
(`POST /audio`), **dispara o pipeline** (`POST /jobs/pipeline`), **acompanha o job** por polling
e **lê** as notas clínicas (BIRP/SOAP) renderizadas em Markdown.

> Os arquivos em `MEngine/` são código-fonte SwiftUI puro. Não há `.xcodeproj` versionado
> (não dá para gerá-lo de forma confiável fora do Xcode). Siga o setup abaixo.
>
> **Sobre os erros do editor ("Cannot find type 'APIClient'…"):** são do SourceKit analisando
> cada arquivo isolado, sem um módulo. Ao adicionar todos os `.swift` ao MESMO target Xcode,
> eles compartilham o módulo e os erros somem. Não são bugs do código.

## Arquivos

| Arquivo | Papel |
|---|---|
| `MEngineApp.swift` | `@main` App + `WindowGroup` |
| `AppSettings.swift` | URL da API + API key (`@AppStorage`) |
| `Models.swift` | DTOs Codable (espelham `m_engine/api.py`) + `ModelChoice` |
| `APIClient.swift` | Cliente async (upload multipart, pipeline, status, pacientes, documentos) |
| `AudioRecorder.swift` | Gravação `.m4a`/AAC (AVAudioRecorder), permissão de microfone |
| `ContentView.swift` | TabView (Sessão / Pacientes) + Ajustes |
| `IngestView.swift` | Gravar/selecionar → enviar → pipeline → status |
| `PatientsView.swift` | Lista pacientes → documentos → nota renderizada |
| `MarkdownText.swift` | Renderizador Markdown leve (títulos/listas/ênfase) |

## Setup no Xcode

1. **Xcode → File → New → Project → Multiplatform → App.** Nome: `MEngine`. Interface: SwiftUI.
2. **Deployment targets:** iOS **17.0+** e macOS **14.0+** (uso de `ContentUnavailableView` e
   `AVAudioApplication.requestRecordPermission`).
3. Apague o `ContentView.swift`/`<Nome>App.swift` gerados e **arraste todos os `.swift` de `MEngine/`**
   para o target (marque "Copy items if needed" e o target do app).
4. Configure as permissões/segurança abaixo.
5. Build & Run. Em **Ajustes** (engrenagem), aponte a **URL da API** (ex.: `http://localhost:8000`)
   e use "Testar conexão".

## Permissões e segurança (obrigatório para funcionar)

### Microfone — ambos
No target → **Info** → adicione:
- `NSMicrophoneUsageDescription` = *"Gravação de áudio das sessões clínicas para transcrição."*

### macOS — App Sandbox (Signing & Capabilities → App Sandbox)
- **Outgoing Connections (Client)** — para falar com a API.
- **Audio Input** — para o microfone (entitlement `com.apple.security.device.audio-input`).

### App Transport Security — falar com a API em HTTP (localhost/VM sem TLS)
Por padrão iOS/macOS bloqueiam HTTP texto-puro. Se a API não estiver atrás de HTTPS, no `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <!-- Permite http apenas para a rede local (ex.: localhost / VM interna). -->
  <key>NSAllowsLocalNetworking</key><true/>
</dict>
```

Para um host remoto sem TLS, use uma exceção por domínio (`NSExceptionDomains`) em vez de
`NSAllowsArbitraryLoads`. **Em produção, ponha a API atrás de HTTPS** e nada disso é necessário.

## Fluxo do app

```
[Sessão]  gravar/selecionar áudio
            → POST /audio              (salva em $M_BASE/audio)
            → POST /jobs/pipeline      (transcribe → birp + normalize→asl→dim→gem→soap_t)
            → GET  /jobs/{id}          (polling a cada 5s até ready)
[Pacientes] GET /patients
            → GET /patients/{id}/documents
            → GET /patients/{id}/documents/{nome}   (Markdown renderizado)
```

O seletor **Modelo** envia `model` ao pipeline: *Padrão* deixa cada stage usar seu default
(birp/normalize/soap → Sonnet; asl/dim/gem → Opus 4.8); *Opus*/*Sonnet*/*Claude Code (cc)* forçam.
O toggle **Análise profunda** liga/desliga o ramo B (asl→dim→gem→soap).

## Notas

- A API hoje **não exige autenticação**; o campo *API key* manda `Authorization: Bearer …`
  apenas para o caso de você pôr um proxy/gateway na frente.
- A gravação produz `.m4a` (AAC) em `temporaryDirectory` e é enviada via multipart.
- O job de pipeline pode levar **minutos** (várias chamadas LLM) — o polling cobre isso.
