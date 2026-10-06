import Photos
import SwiftUI

// Explanatory copy and advanced choices live here so browsing stays focused on media.
// All preferences are local; connection credentials are separately secured by Keychain.
struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var autoOrganize = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("monochrome") private var monochrome = false
    @AppStorage("galleryDirection") private var galleryDirection = "vertical"
    @AppStorage("skipInterval") private var skipInterval = 10
    @AppStorage("gridColumns") private var gridColumns = 3
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("resumePlayback") private var resumePlayback = true
    @AppStorage("visualCacheVersion") private var visualCacheVersion = 0
    @AppStorage("visualAnalysis") private var visualAnalysis = true
    @AppStorage("detailedDescriptions") private var detailedDescriptions = true
    @AppStorage("textRecognition") private var textRecognition = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Customize") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    Toggle("True monochrome", isOn: $monochrome)
                    Picker("Gallery direction", selection: $galleryDirection) {
                        Text("Vertical").tag("vertical")
                        Text("Horizontal").tag("horizontal")
                    }
                    Picker("Grid density", selection: $gridColumns) {
                        ForEach(2...5, id: \.self) { Text("\($0) columns").tag($0) }
                    }
                }
                Section("Connections") {
                    NavigationLink {
                        FilesView()
                    } label: {
                        Label("Opened files", systemImage: "folder")
                    }
                    NavigationLink {
                        FolderConnectionsView()
                    } label: {
                        Label("Folders & discovery", systemImage: "folder.badge.gearshape")
                    }
                    NavigationLink {
                        CloudStorageView()
                    } label: {
                        Label("Cloud storage", systemImage: "externaldrive.badge.icloud")
                    }
                }
                Section("Organization") {
                    Button("Auto organize") { autoOrganize = true }
                    if store.canUndoFileOrganization {
                        Button("Undo last file moves") {
                            Task {
                                let result = await store.undoFileOrganization()
                                if !result.1.isEmpty { store.message = result.1.joined(separator: "\n") }
                            }
                        }
                    }
                    if store.archive.pendingFileMove != nil {
                        Button("Recover interrupted file move") { Task { await store.retryFileRecovery() } }
                    }
                    if store.canUndoOrganization {
                        Button("Undo last organization") { store.undoOrganization() }
                    }
                }
                Section("Playback") {
                    Toggle("Autoplay videos", isOn: $autoplay)
                    Toggle("Resume playback", isOn: $resumePlayback)
                    Picker("Skip interval", selection: $skipInterval) {
                        ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                }
                Section {
                    Toggle("Analyze photos on this iPhone", isOn: $visualAnalysis)
                    if visualAnalysis && MosaicIndexer.shared.running {
                        LabeledContent(MosaicIndexer.shared.paused ? "Paused to keep iPhone cool" : "Analyzing") {
                            Text(MosaicIndexer.shared.progress.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                        }
                    }
                    if visualAnalysis {
                        Toggle("Detailed descriptions", isOn: $detailedDescriptions)
                        if detailedDescriptions {
                            if MediaDescriber.isAvailable {
                                let indexer = MosaicIndexer.shared
                                if indexer.describable > 0 {
                                    LabeledContent(indexer.describing && indexer.paused ? "Described (paused)" : "Described") {
                                        Text("\(indexer.described.formatted()) of \(indexer.describable.formatted())")
                                            .monospacedDigit()
                                    }
                                }
                            } else {
                                Text("Requires Apple Intelligence. Search still uses on-device scene labels.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Clear visual analysis cache") {
                        Task {
                            await MosaicIndexer.shared.reset()
                            visualCacheVersion += 1
                        }
                    }
                } header: {
                    Text("Mosaic canvas")
                } footer: {
                    Text(
                        "Mosaic analyzes small thumbnails entirely on this device to find each item’s colors, scene (like beach, dog, or food), and visual similarity. With Apple Intelligence, detailed descriptions add precise tags (objects, people described generically, activities, places, and ideas) using the on-device model, mostly while charging. Nothing is uploaded, iCloud originals are never downloaded for analysis, and cloud-only files are skipped. Indexing runs gently in the background (faster while charging) and pauses while you view media, when Mosaic is closed, or when your iPhone is warm. Tap any tile on the canvas to explore similar media; pinch to zoom, all the way out to see your whole library."
                    )
                }
                Section {
                    Toggle("Search text in photos", isOn: $textRecognition)
                        .onChange(of: textRecognition) { _, enabled in if !enabled { store.stopIndexing() } }
                    if textRecognition {
                        if store.indexing {
                            HStack {
                                ProgressView()
                                Text("Indexed \(store.indexedCount) photos")
                                Spacer()
                                Button("Stop") { store.stopIndexing() }
                            }
                        } else {
                            Button("Index local photos") { store.indexPhotoText() }.disabled(
                                !store.hasPhotoAccess)
                        }
                        LabeledContent("Indexed photos", value: store.recognizedText.count.formatted())
                        Button("Clear text index", role: .destructive) { store.clearTextIndex() }
                    }
                } header: {
                    Text("On-device AI")
                } footer: {
                    Text(
                        "Recognizes text with Apple Vision, entirely on your device. Each batch scans up to 500 unindexed local photos while Mosaic is open. It does not download iCloud originals. Recognized text is saved locally for search. Turning this off disables text search; Clear text index removes the saved text."
                    )
                }
                Section {
                    LabeledContent("Photos", value: photoPermission)
                    if store.authorization == .notDetermined {
                        Button("Allow Photos access") { Task { await store.connectPhotos() } }
                    }
                    Button("Manage system permissions", systemImage: "arrow.up.right.square") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text(
                        "Choose all photos or a limited selection. Files access is granted individually by the system picker. Cloud providers control their own sign-in and downloads."
                    )
                }
                Section("About") {
                    NavigationLink("Formats & playback") { formatDetails }
                    NavigationLink("Privacy & storage") { privacyDetails }
                    if let sourceURL = URL(string: "https://github.com/wckdboy/Mosaic") {
                        Link("Source code", destination: sourceURL)
                    }
                    LabeledContent("Mosaic", value: "1.0 · MIT License")
                }
            }
            .tint(.accentColor).navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .fullScreenCover(isPresented: $autoOrganize) { AutoOrganizeView() }
    }
    private var photoPermission: String {
        switch store.authorization {
        case .authorized: "All photos"
        case .limited: "Selected photos"
        case .denied: "Not allowed"
        case .restricted: "Restricted"
        default: "Not requested"
        }
    }
    private var formatDetails: some View {
        List {
            Section("Images") {
                Text(
                    "JPEG, HEIC, PNG, TIFF, BMP, WebP, RAW formats supported by iOS, GIF, APNG, and Live Photos from Photos. Image decoding and RAW compatibility depend on the device and OS."
                )
            }
            Section("Video") {
                Text(
                    "Native playback supports compatible MP4, MOV, and M4V media, with HDR, AirPlay, Picture in Picture, speed controls, and embedded subtitle and audio tracks when available."
                )
            }
            Section("Other containers") {
                Text(
                    "A file extension is not a codec. MKV, AVI, WebM, and other containers can be opened from Files, but unsupported codecs need another player. Mosaic offers the original through the share sheet when native playback fails."
                )
            }
        }.navigationTitle("Formats & playback").navigationBarTitleDisplayMode(.inline)
    }
    private var privacyDetails: some View {
        List {
            Section("On this device") {
                Text(
                    "Mosaic stores file references, collections, favorites, playback positions, and optional recognized text. Photos and Files originals remain in their existing locations. Forgetting a file or deleting a collection never deletes an original."
                )
            }
            Section("Network access") {
                Text(
                    "Mosaic has no analytics or account. Media opened from iCloud or a Files provider may download through that provider. S3 connections make read requests to the endpoint you configure. S3 images are temporarily downloaded and removed on dismissal; videos stream directly."
                )
            }
            Section("Credentials") {
                Text(
                    "S3 secrets are saved in this device’s Keychain and removed when you disconnect. Nextcloud, Proton Drive, and Google Drive credentials remain in their own apps."
                )
            }
        }.navigationTitle("Privacy & storage").navigationBarTitleDisplayMode(.inline)
    }
}
