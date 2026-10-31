import SwiftUI

/// The Add playlist form, laid out like the TV's. Add checks the login by loading the channels
/// (shared Kotlin code), and saves the playlist only if that works.
struct AddPlaylistView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case xtream = "Xtream login"
        case m3u = "M3U link"
        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(PlaylistStore.self) private var store
    @State private var adding = false
    @State private var error: String?
    @State private var kind = Kind.xtream
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    TextField("Name (optional)", text: $name)
                    switch kind {
                    case .xtream:
                        TextField("Server, like http://example.com:8080", text: $server)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    case .m3u:
                        TextField("Playlist link", text: $link)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("Lumen doesn't provide any channels or content. Use the login or link from your own TV provider. It stays on this device.")
                }

                if adding {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Checking your login and loading channels…")
                                .foregroundStyle(LumenColors.textSecondary)
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(LumenColors.textPrimary)
                    }
                }
            }
            .font(LumenFont.body)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Add playlist")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(adding)
            .interactiveDismissDisabled(adding)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(!canAdd || adding)
                }
            }
        }
    }

    private var canAdd: Bool {
        switch kind {
        case .xtream: !server.isBlank && !username.isBlank && !password.isEmpty
        case .m3u: !link.isBlank
        }
    }

    private func add() async {
        adding = true
        error = nil
        do {
            switch kind {
            case .xtream:
                try await store.addXtream(name: name, server: server, username: username, password: password)
            case .m3u:
                try await store.addM3u(name: name, link: link)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        adding = false
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespaces).isEmpty }
}
