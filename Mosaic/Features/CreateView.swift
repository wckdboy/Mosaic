import SwiftUI

// Create is the third destination: a quiet launchpad for turning the library into a
// collage or a printed book. Browsing stays in Library and Collections; making lives
// here so both workflows get room to breathe.
struct CreateView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CreationStore.self) private var creations
    @State private var collage: CreationProject?
    @State private var book: CreationProject?
    @State private var smartPicks = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    intro
                    makeCards
                    recent
                    if store.items.isEmpty { emptyLibrary }
                }
                .padding(20)
                .padding(.bottom, 80)
            }
            .mosaicBackground()
            .navigationTitle("Create")
            .onAppear { print("MOSAIC_CREATE_APPEARED") }
            .fullScreenCover(item: $collage) { project in
                CollageStudioView(project: project)
            }
            .fullScreenCover(item: $book) { project in
                BookStudioView(project: project)
            }
            .fullScreenCover(isPresented: $smartPicks) {
                SmartPicksView(source: store.items) { kind, items in
                    let project =
                        kind == .collage
                        ? CreationProject.collage(itemIDs: items.map(\.id))
                        : CreationProject.photobook(itemIDs: items.map(\.id))
                    if kind == .collage { collage = project } else { book = project }
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(text: "Make something")
            Text("Your photos, composed.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .tracking(-1)
            Text(
                "Pick a few moments and Mosaic handles the hard part: the grid, the rhythm, the book."
            )
            .font(.body).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var makeCards: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                makeCard(
                    title: "Collage", subtitle: "A print of many moments",
                    symbol: "square.on.square.dashed", tint: Color(hex: 0xA64BD1),
                    identifier: "create.collage"
                ) {
                    collage = .collage(itemIDs: [])
                }
                makeCard(
                    title: "Photobook", subtitle: "A story in pages",
                    symbol: "book.closed", tint: Color(hex: 0xE07A2E),
                    identifier: "create.photobook"
                ) {
                    book = .photobook(itemIDs: [])
                }
            }
            Button {
                smartPicks = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "wand.and.stars")
                        .font(.title2)
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.16), in: .rect(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Smart picks").font(.headline)
                        Text("Choose a varied, print-ready set from your library")
                            .font(.caption).opacity(0.8)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(MosaicTheme.accent, in: .rect(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("create.smartPicks")
            .disabled(store.items.isEmpty)
        }
    }

    private func makeCard(
        title: String, subtitle: String, symbol: String, tint: Color, identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .light))
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.15), in: .rect(cornerRadius: 14))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 176)
            .padding(16)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.55), in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.06)) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .disabled(store.items.isEmpty)
    }

    @ViewBuilder
    private var recent: some View {
        if !creations.projects.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent").font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(creations.projects.count)").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(creations.projects) { project in
                            recentCard(project)
                        }
                    }
                }
            }
        }
    }

    private func recentCard(_ project: CreationProject) -> some View {
        Button {
            if project.kind == .collage { collage = project } else { book = project }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            project.finish == .accent
                                ? AnyShapeStyle(MosaicTheme.accent) : AnyShapeStyle(.quaternary))
                    if let id = project.itemIDs.first, let item = store.item(id) {
                        MediaThumbnail(item: item, pixels: 300)
                            .clipShape(.rect(cornerRadius: 14))
                    } else {
                        Image(systemName: project.kind.symbol)
                            .font(.largeTitle.weight(.ultraLight)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 154, height: 154)
                Text(project.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Label(
                    "\(project.kind.title) · \(project.itemIDs.count)",
                    systemImage: project.kind.symbol
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 154, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") {
                creations.duplicate(project)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                creations.delete(project)
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2.weight(.light)).foregroundStyle(.secondary)
            Text("Add photos first").font(.headline)
            Text("Connect Photos or open files in Library, then come back to compose.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 20))
    }
}
