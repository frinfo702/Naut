import SwiftUI

/// Publishing is the only setting, so there is one pane and no sidebar.
struct SettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                StatusCard()
            }

            Section {
                TextField("Account ID", text: $store.accountID, prompt: Text("32 hex characters"))
                    .font(.body.monospaced())
                SecureField("API Token", text: $store.apiToken)
            } header: {
                Text("Cloudflare")
            } footer: {
                Text("Create a token with **Workers Scripts: Edit**, **Workers KV Storage: Edit** and **Account Settings: Read**. The token is stored in your keychain.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    if let error = store.error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .lineLimit(6)
                    }
                    Spacer()
                    if store.provisioning { ProgressView().controlSize(.small) }
                    Button(store.site == nil ? "Set Up Publishing" : "Update") { store.provision() }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.provisioning || store.accountID.isEmpty || store.apiToken.isEmpty)
                }
            } footer: {
                Text("Runs Terraform to create a Worker and a KV namespace named “naut”. Afterwards they are ordinary Cloudflare resources you can change in the dashboard.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Server — Running" style card summarising where notes are published.
private struct StatusCard: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Publishing").font(.headline)
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = store.site?.url {
                Button("Open") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var subtitle: String {
        if store.provisioning { return "Setting up…" }
        guard let site = store.site else { return "Not set up" }
        return site.url.host() ?? site.url.absoluteString
    }
}
