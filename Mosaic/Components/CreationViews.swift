import SwiftUI
import UIKit

// MARK: - Sharing

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: - Collage preview

struct CollagePreview: View {
    let layout: CoreCollageLayout
    let items: [String: MediaItem]
    let finish: CollageFinish
    let cornerRadius: CGFloat
    var showCaptions = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                background
                ForEach(layout.cells) { cell in
                    cellView(cell, width: width, height: height)
                }
            }
            .clipped()
        }
        .aspectRatio(max(layout.aspect, 0.1), contentMode: .fit)
        .clipShape(.rect(cornerRadius: 18))
    }

    private var background: some View {
        Group {
            if finish == .accent {
                MosaicTheme.accent
            } else {
                let (r, g, b) = finish.components
                Color(red: r, green: g, blue: b)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: CoreCollageCell, width: CGFloat, height: CGFloat) -> some View {
        let frame = CGRect(
            x: cell.x * width, y: cell.y * height,
            width: cell.w * width, height: cell.h * height)
        let radius = cornerRadius * (width / 390)
        Group {
            if let id = cell.id, let item = items[id] {
                MediaThumbnail(item: item, pixels: 500)
                    .overlay(alignment: .bottomLeading) {
                        if showCaptions {
                            Text(item.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: max(8, width * 0.018), weight: .medium))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(.black.opacity(0.35), in: Capsule())
                                .padding(6)
                        }
                    }
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(.rect(cornerRadius: radius))
        .rotationEffect(.degrees(cell.rotation))
        .shadow(
            color: .black.opacity(cell.role == "card" ? 0.18 : 0.06),
            radius: cell.role == "card" ? 8 : 2, y: cell.role == "card" ? 4 : 1
        )
        .position(x: frame.midX, y: frame.midY)
        .zIndex(Double(cell.z))
    }
}

// MARK: - Book page preview

struct BookPagePreview: View {
    let page: CoreBookPage
    let items: [String: MediaItem]
    let finish: CollageFinish
    let pageAspect: Double
    var cornerRadius: CGFloat = 0
    var coverTypography: CoverTypography = .serif

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                if finish == .accent {
                    MosaicTheme.accent
                } else {
                    let (r, g, b) = finish.components
                    Color(red: r, green: g, blue: b)
                }
                ForEach(page.cells.sorted(by: { $0.z < $1.z })) { cell in
                    let frame = CGRect(
                        x: cell.x * width, y: cell.y * height,
                        width: cell.w * width, height: cell.h * height)
                    Group {
                        if let item = items[cell.id] {
                            MediaThumbnail(item: item, pixels: 520)
                        } else {
                            Rectangle().fill(.quaternary)
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(.rect(cornerRadius: cornerRadius))
                    .rotationEffect(.degrees(cell.rotation))
                    .position(x: frame.midX, y: frame.midY)
                    .zIndex(Double(cell.z))
                }
                if page.kind == "cover" {
                    coverType(width: width, height: height)
                } else if !page.title.isEmpty {
                    VStack {
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(page.title).font(.caption2.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if let date = page.startDate {
                                Text(
                                    Date(timeIntervalSince1970: date).formatted(
                                        date: .abbreviated, time: .omitted)
                                )
                                .font(.caption2).lineLimit(1)
                            }
                        }
                        .foregroundStyle(finish.foregroundIsLight ? .white : .primary.opacity(0.7))
                        .padding(.horizontal, max(12, width * 0.06))
                        .padding(.bottom, max(10, width * 0.04))
                    }
                }
            }
            .clipped()
        }
        .aspectRatio(max(pageAspect, 0.4), contentMode: .fit)
    }

    private func coverType(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            if !page.title.isEmpty {
                Text(page.title)
                    .font(
                        coverTypography == .serif
                            ? .system(size: max(20, width * 0.075), weight: .semibold, design: .serif)
                            : coverTypography == .rounded
                                ? .system(size: max(20, width * 0.075), weight: .semibold, design: .rounded)
                                : .system(size: max(20, width * 0.075), weight: .semibold)
                    )
                    .foregroundStyle(.white)
                    .lineLimit(3)
            }
            if !page.subtitle.isEmpty {
                Text(page.subtitle)
                    .font(.system(size: max(11, width * 0.032), weight: .regular))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(max(16, width * 0.07))
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom))
    }
}

// MARK: - Item picker

/// A bounded, searchable picker over the existing library. It returns identifiers in
/// the exact order they were tapped, which gives freeform layouts a deliberate
/// sequence instead of an arbitrary set order.
struct CreationPhotoPicker: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: [String]
    let limit: Int
    let onDone: ([String]) -> Void
    @State private var query = ""
    @State private var selected: [String]
    @State private var favoriteOnly = false

    init(
        title: String = "Choose photos", initial: [String] = [], limit: Int = 60,
        onDone: @escaping ([String]) -> Void
    ) {
        self.title = title
        self.initial = initial
        self.limit = limit
        self.onDone = onDone
        _selected = State(initialValue: initial)
    }

    private var filtered: [MediaItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return store.items.filter { item in
            if favoriteOnly && !store.favorites.contains(item.id) { return false }
            guard !terms.isEmpty else { return true }
            let searchable =
                "\(item.name) \(item.kind.title) \(Calendar.current.component(.year, from: item.date))"
            return terms.allSatisfy { searchable.localizedStandardContains($0) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 4), spacing: 3
                ) {
                    ForEach(filtered) { item in
                        Button {
                            toggle(item.id)
                        } label: {
                            MediaTile(
                                item: item, favorite: store.favorites.contains(item.id),
                                selecting: true, selected: selected.contains(item.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.name), \(item.kind.title)")
                        .accessibilityValue(selected.contains(item.id) ? "Selected" : "")
                    }
                }
                .padding(3)
            }
            .searchable(text: $query, prompt: "Search by name, year, or type")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add \(selected.count)") {
                        onDone(selected)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selected.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Toggle("Favorites only", isOn: $favoriteOnly)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("\(selected.count) of \(limit) selected")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private func toggle(_ id: String) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else if selected.count < limit {
            selected.append(id)
        }
    }
}
