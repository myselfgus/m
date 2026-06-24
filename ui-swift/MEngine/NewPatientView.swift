import SwiftUI

/// Folha de criação de paciente (HealthOS — Pacientes). Coleta nome completo
/// (obrigatório), CPF, telefone, idade, e-mail e notas; cria via `POST /patients`
/// e devolve o `slug` resultante pelo callback `onCreated`.
struct NewPatientView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// Chamado com o `slug` do paciente criado (para navegação subsequente).
    var onCreated: ((String) -> Void)? = nil

    @State private var fullName = ""
    @State private var cpf = ""
    @State private var phone = ""
    @State private var ageText = ""
    @State private var email = ""
    @State private var notes = ""

    @State private var saving = false
    @State private var errorText: String?

    private var trimmedName: String { fullName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !trimmedName.isEmpty && !saving }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(alignment: .leading, spacing: 14) {
                    field("NOME COMPLETO", text: $fullName, placeholder: "obrigatório",
                          autocap: .words)
                    field("CPF", text: $cpf, placeholder: "somente números",
                          keyboard: .numberPad, mono: true)
                    field("TELEFONE", text: $phone, placeholder: "com DDD",
                          keyboard: .phonePad)
                    field("IDADE", text: $ageText, placeholder: "anos",
                          keyboard: .numberPad)
                    field("E-MAIL", text: $email, placeholder: "opcional",
                          keyboard: .emailAddress, autocap: .never)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("NOTAS").font(.hosSubhead).foregroundStyle(.secondary)
                        TextEditor(text: $notes)
                            .font(.hosBody)
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous))
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

                actions
            }
            .padding(22)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 540)
        #endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 22)).foregroundStyle(HOS.blue)
            Text("Novo paciente").font(.hosTitle1)
            Spacer()
        }
    }

    private var actions: some View {
        HStack {
            Button { dismiss() } label: {
                ActionLabel("Cancelar", systemImage: "xmark")
            }
            Spacer()
            Button {
                Task { await create() }
            } label: {
                if saving { ProgressView().controlSize(.small) }
                else { ActionLabel("Criar", systemImage: "checkmark") }
            }
            .buttonStyle(.borderedProminent)
            .tint(HOS.blue)
            .disabled(!canCreate)
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String = "",
                       keyboard: KeyboardKind = .default, mono: Bool = false,
                       autocap: Autocap = .sentences) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.hosSubhead).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? .hosMono : .hosBody)
                #if os(iOS)
                .keyboardType(keyboard.uiKit)
                .textInputAutocapitalization(autocap.uiKit)
                .autocorrectionDisabled(mono || keyboard == .emailAddress)
                #endif
        }
    }

    private func create() async {
        saving = true
        errorText = nil
        defer { saving = false }

        let req = CreatePatientRequest(
            fullName: trimmedName,
            cpf: nonEmpty(cpf),
            phone: nonEmpty(phone),
            age: Int(ageText.trimmingCharacters(in: .whitespaces)),
            email: nonEmpty(email),
            notes: nonEmpty(notes)
        )
        do {
            let profile = try await settings.makeClient().createPatient(req)
            onCreated?(profile.slug)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Abstração de capitalização automática multiplataforma (ignorada no macOS).
enum Autocap {
    case never, words, sentences
    #if os(iOS)
    var uiKit: TextInputAutocapitalization {
        switch self {
        case .never: return .never
        case .words: return .words
        case .sentences: return .sentences
        }
    }
    #endif
}
