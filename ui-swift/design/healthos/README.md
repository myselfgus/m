# HealthOS — Design System (referência)

Fonte de verdade dos tokens visuais adotados pelo app SwiftUI do M-Engine.
Origem: bundle `healthdrive` (HealthOS Design System, macOS 26+ Liquid Glass).

| Arquivo | Conteúdo |
|---|---|
| `colors_and_type.css` | Tokens canônicos — cores da marca, stage tints (STT/PROC/SPEECH/ASL/VDLP/GEM), estados semânticos, escala tipográfica, espaçamento 8pt, raios, glass e capsules |
| `assets/healthos-mark.svg` | Marca "nós de conexão" (referência) |
| `assets/healthos-wordmark.svg` | Wordmark `health`+`OS` (referência) |
| `assets/glyph-*.svg` | Glyphs de seção (referência) |

## Como o app consome estes tokens

Os tokens são portados para SwiftUI **nativo** em
[`MEngine/HealthOSTheme.swift`](../../MEngine/HealthOSTheme.swift):

- **Cores** → `enum HOS` (`HOS.blue`, `HOS.navy`, `HOS.ink`, stage tints, estados).
- **Tipografia** → `extension Font` (`.hosLargeTitle`, `.hosTitle1`, … `.hosMono`).
  As famílias resolvem para **SF Pro / SF Pro Rounded / SF Mono** nativamente
  (system-first) — nenhuma fonte precisa ser embarcada.
- **Glass / Liquid Glass** → `.healthCard()` (`.regularMaterial` + raio 16 + borda fina).
- **Capsules / status** → `StatusPill`, com cor por estado ou por stage.
- **Stat cards** → `StatCard`.
- **Iconografia** → **SF Symbols** (canônicos do design) + o asset **`m-icon`** como
  marca do app (decisão do produto: manter o `m-icon`; ver `BrandMark`).

> Os SVGs aqui são **referência de design**, não recursos de runtime — o app não renderiza
> SVG; recria/mapeia tudo em componentes SwiftUI nativos.
