import SwiftUI

struct DenSettingsView: View {
    @Environment(DenStore.self) private var den
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        @Bindable var den = den
        NavigationStack {
            Form {
                Section {
                    TextField("http://my-den:5050 or 100.x.y.z:5050", text: $den.urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.Fonts.data)
                } header: {
                    ModuleHeader(1, "Den address")
                } footer: {
                    Text("The Observatory on your Den, reached over Tailscale. Keep the Tailscale app connected on this phone.")
                }
                .fieldSection()
                Section {
                    SecureField(den.hasToken ? "Saved. Type to replace." : "Operator password", text: $password)
                    Button("Save password") {
                        den.setToken(password)
                        password = ""
                    }
                    .disabled(password.isEmpty)
                    if den.hasToken {
                        Button("Remove password", role: .destructive) { den.setToken(nil) }
                    }
                    HStack {
                        Text("Can send").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Chip(den.authorized == true ? "Yes" : den.authorized == false ? "No" : "Unknown",
                             color: den.authorized == true ? Theme.ok : den.authorized == false ? Theme.alert : Theme.textTertiary, small: true)
                    }
                } header: {
                    ModuleHeader(2, "Operator password")
                } footer: {
                    Text("Sending messages through the Den needs the operator_token from the Den's wildcat.toml. It is kept in this phone's Keychain.")
                }
                .fieldSection()
            }
            .fieldForm()
            .navigationTitle("Den settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task { await den.refresh() }
                        dismiss()
                    }
                }
            }
        }
        .presentationBackground(Theme.bg)
    }
}
