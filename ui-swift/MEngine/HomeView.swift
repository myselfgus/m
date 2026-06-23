import SwiftUI

/// Início do dashboard: saudação, stat cards (pacientes/documentos/BIRP/SOAP) e atalhos.
struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    var onOpenPatient: (String) -> Void
    var onNova: () -> Void

    @State private var patients: [Patient] = []
    @State private var totalDocs = 0
    @State private var birpCount = 0
    @State private var soapCount = 0
    @State private var loading = false

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Bom dia"
        case 12..<18: return "Boa tarde"
        default: return "Boa noite"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.hosLargeTitle).foregroundStyle(.primary)
                    Text("Visão geral do arquivo clínico").font(.hosBody).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    StatCard(symbol: "person.2.fill", value: "\(patients.count)", label: "Pacientes", tint: HOS.tintBlue)
                    StatCard(symbol: "doc.text.fill", value: "\(totalDocs)", label: "Documentos", tint: HOS.tintIndigo)
                    StatCard(symbol: "bolt.heart.fill", value: "\(birpCount)", label: "Notas BIRP", tint: HOS.stProc)
                    StatCard(symbol: "stethoscope", value: "\(soapCount)", label: "Notas SOAP", tint: HOS.tintTeal)
                }

                Button(action: onNova) {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.badge.mic").font(.system(size: 18, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Nova sessão").font(.hosTitle3)
                            Text("Gravar ou enviar áudio e processar o pipeline").font(.hosFootnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .healthCard()
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 10) {
                    Text("PACIENTES").font(.hosSubhead).foregroundStyle(.secondary)
                    if loading && patients.isEmpty {
                        ProgressView().padding(.vertical, 8)
                    } else if patients.isEmpty {
                        Text("Nenhum paciente ainda. Comece por uma nova sessão.")
                            .font(.hosFootnote).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(patients) { patient in
                                Button { onOpenPatient(patient.slug) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "person.crop.circle.fill")
                                            .font(.system(size: 24))
                                            .foregroundStyle(HOS.navy, HOS.blue.opacity(0.18))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(patient.displayName).font(.hosHeadline).foregroundStyle(.primary)
                                            Text(patient.slug).font(.hosCaption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        StatusPill(
                                            text: patient.consultationCount == 1 ? "1 consulta" : "\(patient.consultationCount) consultas",
                                            color: HOS.info, systemImage: "calendar"
                                        )
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                                    }
                                    .healthCard(padding: 12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .navigationTitle("Início")
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let client = try? settings.makeClient() else { return }
        let pats = (try? await client.fetchPatients()) ?? []
        patients = pats

        var docs = 0, birp = 0, soap = 0
        await withTaskGroup(of: [String].self) { group in
            for p in pats {
                group.addTask {
                    let consultations = (try? await client.fetchConsultations(slug: p.slug)) ?? []
                    return consultations.flatMap { $0.documents }
                }
            }
            for await list in group {
                docs += list.count
                birp += list.filter { $0.localizedCaseInsensitiveContains("BIRP") }.count
                soap += list.filter { $0.localizedCaseInsensitiveContains("SOAP") }.count
            }
        }
        totalDocs = docs; birpCount = birp; soapCount = soap
    }
}
