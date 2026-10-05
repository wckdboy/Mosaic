import AVKit
import SwiftUI
import UniformTypeIdentifiers

// Provider apps own their sign-in and encryption. Selecting a document grants access
// to that document only; Mosaic does not ask for a user's cloud account password.
struct CloudStorageView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("s3Connections") private var savedConnections = Data()
    @State private var adding = false
    @State private var importing = false
    @State private var deleting: S3Connection?
    private var connections: [S3Connection] {
        (try? JSONDecoder().decode([S3Connection].self, from: savedConnections)) ?? []
    }
    var body: some View {
        List {
            Section {
                ForEach(["Nextcloud", "Proton Drive", "Google Drive", "iCloud Drive"], id: \.self) {
                    provider in
                    Button {
                        importing = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "externaldrive.badge.icloud").font(.title2).frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider).font(.headline)
                                Text("Choose files with iOS Files").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }.tint(.primary)
                }
            } header: {
                Text("Your connected providers")
            } footer: {
                Text(
                    "Install and sign in to the provider’s app, then enable it in Files → Browse → ••• → Edit. Availability depends on the provider. If Proton Drive is missing, export media to Files from Proton Drive first. Only files you select become accessible to Mosaic."
                )
            }
            Section {
                ForEach(connections) { connection in
                    NavigationLink {
                        S3Browser(connection: connection)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connection.name)
                                Text(connection.bucket).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "server.rack")
                        }
                    }.swipeActions { Button("Disconnect", role: .destructive) { deleting = connection } }
                }
                Button("Connect S3 bucket", systemImage: "plus") { adding = true }
            } header: {
                Text("S3 & compatible storage")
            } footer: {
                Text(
                    "Read-only browsing. Credentials are stored in this device’s Keychain. Mosaic connects only when you open a bucket or media item."
                )
            }
        }
        .navigationTitle("Cloud storage").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) {
            S3ConnectSheet { connection in
                do { savedConnections = try JSONEncoder().encode(connections + [connection]) } catch {
                    store.message = error.localizedDescription
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            result in
            switch result {
            case .success(let urls): Task { await store.openFiles(urls) }
            case .failure(let error): store.message = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Disconnect this bucket?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Disconnect", role: .destructive) {
                guard let deleting else { return }
                do {
                    try CloudKeychain.delete(id: deleting.id)
                    savedConnections = try JSONEncoder().encode(connections.filter { $0.id != deleting.id })
                } catch { store.message = error.localizedDescription }
                self.deleting = nil
            }
        } message: {
            Text("The saved credentials are removed from this device. Nothing is changed on the server.")
        }
    }
}

// No network access occurs while entering credentials. Connect is explicit consent
// to store them locally; opening the saved connection performs the first request.
struct S3ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (S3Connection) -> Void
    @State private var name = ""
    @State private var endpoint = "https://s3.amazonaws.com"
    @State private var bucket = ""
    @State private var region = "us-east-1"
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var sessionToken = ""
    @State private var pathStyle = true
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Display name", text: $name)
                    TextField("HTTPS endpoint", text: $endpoint).keyboardType(.URL)
                    TextField("Bucket", text: $bucket)
                    TextField("Region", text: $region)
                    Toggle("Path-style addressing", isOn: $pathStyle)
                }
                Section {
                    SecureField("Access key ID", text: $accessKey)
                    SecureField("Secret access key", text: $secretKey)
                    SecureField("Session token (optional)", text: $sessionToken)
                } header: {
                    Text("Credentials")
                } footer: {
                    Text(
                        "Use credentials with ListBucket and GetObject access. Session tokens expire according to your provider. Secrets are saved only in Keychain."
                    )
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Text(
                        "Supports AWS S3 and services with the S3 Signature V4 API. Use your bucket’s region endpoint. Connecting does not upload, edit, or delete objects."
                    ).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("Connect S3").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { save() }.disabled(
                        bucket.isEmpty || accessKey.isEmpty || secretKey.isEmpty)
                }
            }
        }
    }
    private func save() {
        let connection = S3Connection(
            name: name.isEmpty ? bucket : name,
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region.trimmingCharacters(in: .whitespacesAndNewlines), pathStyle: pathStyle)
        let credentials = S3Credentials(
            accessKey: accessKey, secretKey: secretKey, sessionToken: sessionToken)
        do {
            _ = try S3Signer.url(connection: connection, credentials: credentials)
            try CloudKeychain.save(credentials, id: connection.id)
            onSave(connection)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct S3Browser: View {
    let connection: S3Connection
    var prefix = ""
    @State private var page = S3Page()
    @State private var loading = false
    @State private var error: String?
    @State private var selected: S3Object?
    var body: some View {
        List {
            if let error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
            }
            ForEach(page.folders, id: \.self) { folder in
                NavigationLink {
                    S3Browser(connection: connection, prefix: folder)
                } label: {
                    Label(String(folder.dropFirst(prefix.count).dropLast()), systemImage: "folder")
                }
            }
            ForEach(page.objects) { object in
                let kind = MediaItem.kind(for: URL(fileURLWithPath: object.key))
                Button {
                    selected = object
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: kind?.symbol ?? "doc").frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(object.name).lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }.tint(.primary).disabled(kind == nil)
            }
            if page.nextToken != nil {
                Button("Load more") { Task { await load(more: true) } }.disabled(loading)
            }
            if loading { ProgressView("Loading…") }
            if !loading && error == nil && page.objects.isEmpty && page.folders.isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            }
        }
        .navigationTitle(
            prefix.isEmpty
                ? connection.name
                : String(prefix.dropLast()).components(separatedBy: "/").last ?? connection.name
        )
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { S3MediaViewer(connection: connection, object: $0) }
    }
    private func load(more: Bool = false) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await S3Service.shared.list(
                connection: connection, prefix: prefix, token: more ? page.nextToken : nil)
            if more {
                page.objects += result.objects
                page.folders += result.folders
                page.nextToken = result.nextToken
            } else {
                page = result
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

// Videos use HTTP range streaming. Images download to a temporary file and are
// removed on dismissal. Large images require export through a Files provider.
struct S3MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    let connection: S3Connection
    let object: S3Object
    @State private var loader = MediaLoader()
    @State private var temporaryURL: URL?
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let error = loader.error {
                    ContentUnavailableView(
                        "Unable to open", systemImage: "exclamationmark.icloud", description: Text(error))
                } else if let player = loader.player {
                    NativeVideoPlayer(player: player)
                } else if let image = loader.image {
                    ZoomableImage(image: image)
                } else if let url = loader.animatedURL {
                    AnimatedImageSurface(url: url)
                }
                if loader.loading { ProgressView("Opening…").tint(.white) }
            }
            .navigationTitle(object.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .preferredColorScheme(.dark)
        .task {
            do {
                let url = try await S3Service.shared.mediaURL(connection: connection, key: object.key)
                let kind = MediaItem.kind(for: URL(fileURLWithPath: object.key))
                if kind == .video {
                    loader.configure(AVPlayerItem(url: url), position: 0, autoplay: true)
                } else {
                    guard object.size <= 100 * 1024 * 1024 else {
                        loader.fail(
                            "This image is over 100 MB. Open it through a Files provider to view locally.")
                        return
                    }
                    let (download, response) = try await URLSession.shared.download(from: url)
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                        throw CloudError.response((response as? HTTPURLResponse)?.statusCode ?? 0)
                    }
                    let target = URL.temporaryDirectory.appending(path: UUID().uuidString)
                        .appendingPathExtension((object.name as NSString).pathExtension)
                    try FileManager.default.moveItem(at: download, to: target)
                    if Task.isCancelled {
                        try? FileManager.default.removeItem(at: target)
                        return
                    }
                    temporaryURL = target
                    if kind == .animated {
                        loader.animatedURL = target
                    } else {
                        loader.image = await Task.detached {
                            ThumbnailService.downsample(url: target, pixels: 4096)
                        }.value
                    }
                    loader.loading = false
                    if loader.image == nil && loader.animatedURL == nil {
                        loader.fail("iOS could not decode this image.")
                    }
                }
            } catch { if !Task.isCancelled { loader.fail(error.localizedDescription) } }
        }
        .onDisappear {
            loader.stop()
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        }
    }
}
