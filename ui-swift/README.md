# M-Engine — App SwiftUI (macOS + iOS)

Cliente multiplataforma do M-Engine, agora no formato **dashboard** seguindo o
**HealthOS Design System** (macOS 26+ Liquid Glass): uma `NavigationSplitView` com
sidebar de pacientes + detalhe em abas. **Grava ou seleciona** um áudio, **envia**
para a API (`POST /audio`), **dispara o pipeline** (`POST /jobs/pipeline`), **acompanha
o job** por polling e **lê** as notas clínicas (BIRP / SOAP) renderizadas em Markdown.

> Os arquivos em `MEngine/` são código-fonte SwiftUI puro. Não há `.xcodeproj` versionado.
> Os erros do editor ("Cannot find type 'APIClient'…") são do SourceKit analisando cada
> arquivo isolado, sem módulo — somem quando todos os `.swift` estão no MESMO target.

## Design system (HealthOS)

O visual segue os tokens do bundle HealthOS, versionados em
[`design/healthos/`](design/healthos/) e portados para SwiftUI nativo em
[`MEngine/HealthOSTheme.swift`](MEngine/HealthOSTheme.swift):

| Eixo | Implementação |
|---|---|
| **Cores** | `enum HOS` — marca (`blue #3B82F6`, `navy #1C3A63`, `ink #1C2533`), stage tints (STT/PROC/SPEECH/ASL/VDLP/GEM), estados semânticos (complete/running/review/error…) |
| **Tipografia** | `extension Font` (`.hosLargeTitle` … `.hosMono`) → **SF Pro / SF Pro Rounded / SF Mono** (system-first, sem fontes embarcadas) |
| **Liquid Glass** | `.healthCard()` — `.regularMaterial` + raio 16 + borda fina + sombra |
| **Capsules** | `StatusPill` — pill colorida por estado ou por stage |
| **Stat cards** | `StatCard` — número arredondado + ícone + rótulo |
| **Iconografia** | **SF Symbols** canônicos + asset **`m-icon`** como marca (`BrandMark`) |

## Arquivos

| Arquivo | Papel |
|---|---|
| `MEngineApp.swift` | `@main` App + `WindowGroup` |
| `AppSettings.swift` | URL da API + API key (`@AppStorage`) |
| `Models.swift` | DTOs Codable (espelham `m_engine/api.py`) + `PatientInfo` + `ModelChoice` |
| `APIClient.swift` | Cliente async (upload multipart, pipeline, status, pacientes, documentos, info) |
| `AudioRecorder.swift` | Gravação `.m4a`/AAC (AVAudioRecorder), permissão de microfone |
| `HealthOSTheme.swift` | **Design system**: cores, tipografia, glass card, capsules, stat card, `BrandMark` |
| `ContentView.swift` | **Shell**: `NavigationSplitView` (sidebar Início/Nova sessão/Pacientes) + Ajustes |
| `HomeView.swift` | **Início**: saudação + stat cards + lista de pacientes |
| `IngestView.swift` | **Nova sessão** (`NewSessionView`): gravar/selecionar → enviar → pipeline → status, com stage track |
| `PatientsView.swift` | **Detalhe do paciente** (`PatientDetailView`): cabeçalho + abas Documentos · Pipeline · Dossiê + leitor Markdown |
| `MarkdownText.swift` | Renderizador Markdown leve (títulos/listas/ênfase) |

## Estrutura do dashboard

```
NavigationSplitView
├─ Sidebar
│   ├─ marca (m-icon) + "M-Engine"
│   ├─ Início · Nova sessão
│   └─ Pacientes (buscável)         ← GET /patients
└─ Detalhe
    ├─ Início      → stat cards (pacientes/documentos/BIRP/SOAP) + lista
    ├─ Nova sessão → gravar/enviar áudio → pipeline → polling do job
    └─ Paciente    → cabeçalho (CID/medicamentos via /info) +
                     [Documentos] lista BIRP/SOAP → leitor Markdown
                     [Pipeline]   checklist de stages (STT→BIRP, ASL→…→SOAP)
                     [Dossiê]     resumo clínico + chips CID/medicamentos/tópicos
```

## Setup no Xcode

1. **Xcode → File → New → Project → Multiplatform → App.** Nome: `MEngine`. Interface: SwiftUI.
2. **Deployment targets:** iOS **17.0+** e macOS **14.0+**.
3. Apague o `ContentView.swift`/`<Nome>App.swift` gerados e **arraste todos os `.swift` de `MEngine/`**
   para o target (marque "Copy items if needed" e o target do app).
4. **Ícone do app:** asset da marca `m-icon` (`../assets/m-icon.jpg`). Em
   `Assets.xcassets → AppIcon` arraste o `m-icon`. Já há um `MEngine/AppIcon.icns`
   (gerado do `m-icon`) usado pelo build SwiftPM/macOS (`Info.plist` → `CFBundleIconFile = AppIcon`).
5. Configure as permissões/segurança abaixo.
6. Build & Run. Em **Ajustes** (engrenagem na sidebar), aponte a **URL da API**
   (ex.: `http://localhost:8000`) e use "Testar conexão".

> **macOS via SwiftPM** (`swift build`): o `M-Engine.app` montado embute o ícone em
> `Contents/Resources/AppIcon.icns`. O `.app` e o `.build/` não vão ao git; o que é
> versionado é o `AppIcon.icns` em `MEngine/`.

## Permissões e segurança (obrigatório para funcionar)

### Microfone — ambos
No target → **Info** → `NSMicrophoneUsageDescription` = *"Gravação de áudio das sessões clínicas para transcrição."*

### macOS — App Sandbox (Signing & Capabilities → App Sandbox)
- **Outgoing Connections (Client)** — para falar com a API.
- **Audio Input** — para o microfone (`com.apple.security.device.audio-input`).

### App Transport Security — falar com a API em HTTP (localhost/VM sem TLS)
```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key><true/>
</dict>
```
Para host remoto sem TLS, use `NSExceptionDomains` por domínio. **Em produção, ponha a API atrás de HTTPS.**

## Fluxo do app

```
[Nova sessão]  gravar/selecionar áudio
                 → POST /audio              (salva em $M_BASE/audio)
                 → POST /jobs/pipeline      (transcribe → birp ∥ normalize→asl→dim→gem→soap_t)
                 → GET  /jobs/{id}          (polling a cada 5s até ready)
[Pacientes]    GET /patients
                 → GET /patients/{id}/documents
                 → GET /patients/{id}/info               (resumo: CID, medicamentos, tópicos)
                 → GET /patients/{id}/documents/{nome}    (Markdown renderizado)
```

O seletor **Modelo** envia `model` ao pipeline: *Padrão* deixa cada stage usar seu default
(birp/normalize/soap → Sonnet; asl/dim/gem → Opus 4.8); *Opus*/*Sonnet*/*Claude Code (cc)* forçam.
O toggle **Análise profunda** liga/desliga o ramo B (asl→dim→gem→soap).

## Notas

- A API hoje **não exige autenticação**; o campo *API key* manda `Authorization: Bearer …`
  apenas para o caso de um proxy/gateway na frente.
- A gravação produz `.m4a` (AAC) em `temporaryDirectory`, enviada via multipart.
- O job de pipeline pode levar **minutos** (várias chamadas LLM) — o polling cobre isso.
