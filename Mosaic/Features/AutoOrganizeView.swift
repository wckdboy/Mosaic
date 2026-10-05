import SwiftUI

// The preview and commit share one immutable plan. Organization stays deliberately
// user-triggered; background discovery never silently changes a person's library.
struct AutoOrganizeView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var selectedIDs: Set<String>? = nil
    @State private var options = OrganizationOptions()
    @State private var changes: [OrganizationChange] = []
    @State private var planning = false
    @State private var plannedRequest: Request?
    @State private var applied = false
    @State private var movePreview = FileMovePreview()
    @State private var applying = false
    @State private var confirmMove = false
    @State private var completedCount = 0
    @State private var failures: [String] = []
    @State private var previewLimit = 30
    private struct Request: Equatable {
        let items: [MediaItem]
        let options: OrganizationOptions
        let reserved: Set<String>
    }
    private var request: Request {
        let all = store.items
        return Request(
            items: all.filter { selectedIDs == nil || selectedIDs!.contains($0.id) },
            options: options,
            reserved: Set(all.filter { selectedIDs != nil && !selectedIDs!.contains($0.id) }.map(\.name)))
    }
    var body: some View {
        NavigationStack {
            Group {
                if applied {
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle").font(.system(size: 54, weight: .ultraLight))
                        Text(completedCount > 0 ? "A little more organized." : "Nothing changed").font(
                            .title2.weight(.semibold))
                        Text("\(completedCount) items").foregroundStyle(.secondary)
                        Button("Done") { dismiss() }.buttonStyle(.glassProminent)
                        Button("Undo") {
                            Task {
                                applying = true
                                if options.moveOriginals {
                                    let result = await store.undoFileOrganization()
                                    failures = result.1
                                } else {
                                    store.undoOrganization()
                                }
                                applying = false
                                if failures.isEmpty { applied = false }
                            }
                        }.disabled(applying || (options.moveOriginals && !store.canUndoFileOrganization))
                        if !failures.isEmpty {
                            ScrollView {
                                Text(failures.joined(separator: "\n")).font(.caption).foregroundStyle(
                                    .secondary
                                ).padding()
                            }.frame(maxHeight: 150)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).mosaicBackground()
                } else {
                    Form {
                        Section {
                            Picker("Change", selection: $options.moveOriginals) {
                                Text("In Mosaic").tag(false)
                                Text("Original files").tag(true)
                            }.pickerStyle(.segmented)
                            Toggle("Rename", isOn: $options.rename)
                            if options.rename {
                                TextField("Naming pattern", text: $options.pattern)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(OrganizationPlanner.tokens, id: \.self) { token in
                                            Button(token) { options.pattern += token }.font(
                                                .caption.monospaced()
                                            )
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }
                            }
                            Picker(
                                options.moveOriginals ? "Sort into folders" : "Group into collections",
                                selection: $options.grouping
                            ) {
                                ForEach(OrganizationOptions.Grouping.allCases, id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                        } footer: {
                            Text(
                                options.moveOriginals
                                    ? "Renames and moves originals inside each connected folder. Grouped files go into its Mosaic subfolder. Photos and individually opened files are excluded; connect their parent folder first. Providers must allow writing."
                                    : "Names and collections change inside Mosaic. Original filenames and folders stay intact. Extensions are preserved; duplicate names get a number."
                            )
                        }
                        Section {
                            if planning {
                                ProgressView("Preparing preview…")
                            } else if options.rename && !OrganizationPlanner.validPattern(options.pattern) {
                                Text("Use the suggested tokens and a pattern of up to 120 characters.")
                                    .foregroundStyle(.secondary)
                            } else if options.moveOriginals {
                                ForEach(movePreview.moves.prefix(previewLimit)) { move in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(move.after.relativePath ?? move.after.name).font(.subheadline)
                                        Text(move.before.relativePath ?? move.before.name).font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if movePreview.moves.count > previewLimit {
                                    Button("Show more") { previewLimit += 30 }
                                }
                                if movePreview.skipped > 0 {
                                    Text("\(movePreview.skipped) items need connected-folder access")
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(movePreview.issues, id: \.self) {
                                    Text($0).font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                ForEach(changes.prefix(previewLimit)) { change in
                                    HStack(spacing: 12) {
                                        MediaThumbnail(item: change.item).frame(width: 48, height: 48)
                                            .clipShape(.rect(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(change.name).font(.subheadline).lineLimit(2)
                                            if change.name != change.item.name {
                                                Text(change.item.name).font(.caption).foregroundStyle(
                                                    .secondary
                                                ).lineLimit(1)
                                            }
                                            if let collection = change.collection {
                                                Label(collection, systemImage: "folder").font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                if changes.count > previewLimit {
                                    Button("Show more") { previewLimit += 30 }
                                }
                            }
                        } header: {
                            Text(
                                "Preview · \(options.moveOriginals ? movePreview.moves.count : changes.count)"
                            )
                        }
                        if store.canUndoOrganization {
                            Section { Button("Undo previous organization") { store.undoOrganization() } }
                        }
                    }
                    .disabled(applying)
                    .safeAreaInset(edge: .bottom) {
                        Button {
                            if options.moveOriginals {
                                confirmMove = true
                            } else {
                                completedCount = changes.count
                                applied = true
                                store.applyOrganization(changes)
                            }
                        } label: {
                            Text(
                                applying
                                    ? "Organizing…"
                                    : options.moveOriginals
                                        ? "Review \(movePreview.moves.count) file moves"
                                        : "Organize \(changes.count) items"
                            ).font(.headline).frame(maxWidth: .infinity)
                                .padding(8)
                        }
                        .buttonStyle(.glassProminent).disabled(
                            applying || planning || plannedRequest != request || changes.isEmpty
                                || (options.moveOriginals
                                    && (movePreview.moves.isEmpty || store.scanningFolders))
                                || (!options.rename && options.grouping == .none)
                                || store.storageFailed
                        )
                        .padding(20).background(.bar)
                    }
                }
            }
            .tint(.accentColor).navigationTitle("Auto organize").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(applying)
                }
            }
            .interactiveDismissDisabled(applying)
            .confirmationDialog(
                "Move \(movePreview.moves.count) original files?", isPresented: $confirmMove,
                titleVisibility: .visible
            ) {
                Button("Move files") {
                    Task {
                        applying = true
                        let result = await store.moveOriginals(movePreview.moves)
                        completedCount = result.0
                        failures = result.1
                        applying = false
                        applied = true
                    }
                }
            } message: {
                Text(
                    "Files will be renamed or moved to the paths in the preview. Existing files are never overwritten."
                )
            }
            .task(id: request) {
                guard !applied, !applying else { return }
                planning = true
                let snapshot = request
                let descriptors = await MosaicAnalysis.shared.cached()
                let result = await Task.detached(priority: .userInitiated) {
                    OrganizationPlanner.plan(
                        items: snapshot.items, options: snapshot.options,
                        descriptors: descriptors, reservedNames: snapshot.reserved)
                }.value
                guard !Task.isCancelled else { return }
                let preview =
                    snapshot.options.moveOriginals
                    ? await FileOrganizationService.shared.preview(result) : FileMovePreview()
                guard !Task.isCancelled else { return }
                changes = result
                movePreview = preview
                plannedRequest = snapshot
                planning = false
            }
        }
    }
}
