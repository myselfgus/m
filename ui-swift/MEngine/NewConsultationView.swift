import SwiftUI

/// Folha de criação de consulta para um paciente. Seleciona a data (padrão hoje,
/// formato `YYYY-MM-DD`) e cria via `POST /patients/{slug}/consultations`.
struct NewConsultationView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    let slug: String
    /// Chamado com a consulta recém-criada (id + date).
    var onCreated: ((ConsultationCreated) -> Void)? = nil

    @State private var date = Date()
    @State private var saving = false
    @State private var errorText: String?

    /// Formatador estável `YYYY-MM-DD` (POSIX, UTC) para o corpo da requisição.
    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var dateString: String { Self.isoDay.string(from: date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 22)).foregroundStyle(HOS.blue)
                Text("Nova consulta").font(.hosTitle1)
                Spacer()
                Text(slug).font(.hosMono).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("DATA DA CONSULTA").font(.hosSubhead).foregroundStyle(.secondary)
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .tint(HOS.blue)
                HStack(spacing: 6) {
                    StatusPill(text: dateString, color: HOS.info, systemImage: "calendar")
                    Spacer()
                }
            }
            .healthCard()

            if let errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorText).font(.hosFootnote)
                    Spacer()
                }
                .foregroundStyle(HOS.error)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                Button { dismiss() } label: {
                    ActionLabel("Cancelar", systemImage: "xmark")
                }
                Spacer()
                Button {
                    Task { await create() }
                } label: {
                    if saving { ProgressView().controlSize(.small) }
                    else { ActionLabel("Criar consulta", systemImage: "checkmark") }
                }
                .buttonStyle(.borderedProminent)
                .tint(HOS.blue)
                .disabled(saving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #endif
        .background(.background)
    }

    private func create() async {
        saving = true
        errorText = nil
        defer { saving = false }
        do {
            let created = try await settings.makeClient()
                .createConsultation(slug: slug, date: dateString)
            onCreated?(created)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
