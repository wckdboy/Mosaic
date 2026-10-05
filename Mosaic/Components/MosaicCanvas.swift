import SwiftUI
import UIKit

// A two-dimensional UICollectionView recycles tiles in both axes. SwiftUI's nested
// lazy stacks do not guarantee bounded work for a free-panning, two-axis canvas.
struct MosaicCanvas: UIViewRepresentable {
    let clusters: [MosaicCluster]
    let revision: UUID
    let zoom: CGFloat
    let onSelect: (MediaItem) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }
    func makeUIView(context: Context) -> UICollectionView {
        let layout = MosaicCanvasLayout()
        layout.clusters = clusters
        layout.scale = zoom
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceHorizontal = true
        view.alwaysBounceVertical = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.register(MosaicCanvasCell.self, forCellWithReuseIdentifier: "media")
        view.register(
            MosaicHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "header")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        context.coordinator.clusters = clusters
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }
    func updateUIView(_ view: UICollectionView, context: Context) {
        guard let layout = view.collectionViewLayout as? MosaicCanvasLayout else { return }
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            context.coordinator.clusters = clusters
            layout.clusters = clusters
            layout.invalidateLayout()
            view.reloadData()
            view.layoutIfNeeded()
            // Filtering from a distant canvas location must leave results reachable.
            view.contentOffset = CGPoint(
                x: min(
                    view.contentOffset.x, max(0, layout.collectionViewContentSize.width - view.bounds.width)),
                y: min(
                    view.contentOffset.y, max(0, layout.collectionViewContentSize.height - view.bounds.height)
                ))
        }
        if context.coordinator.requestedZoom != zoom {
            context.coordinator.requestedZoom = zoom
            layout.scale = zoom
            layout.invalidateLayout()
        }
    }
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var clusters: [MosaicCluster] = []
        var revision: UUID?
        var requestedZoom: CGFloat = 1
        var startScale: CGFloat = 1
        let onSelect: (MediaItem) -> Void
        init(onSelect: @escaping (MediaItem) -> Void) { self.onSelect = onSelect }
        func numberOfSections(in collectionView: UICollectionView) -> Int { clusters.count }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            clusters[section].items.count
        }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
            -> UICollectionViewCell
        {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "media", for: indexPath)
            (cell as? MosaicCanvasCell)?.configure(clusters[indexPath.section].items[indexPath.item])
            return cell
        }
        func collectionView(
            _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
            at indexPath: IndexPath
        ) -> UICollectionReusableView {
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: "header", for: indexPath)
            (view as? MosaicHeader)?.label.text =
                "\(clusters[indexPath.section].title)  ·  \(clusters[indexPath.section].items.count)"
            return view
        }
        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            onSelect(clusters[indexPath.section].items[indexPath.item])
        }
        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view as? UICollectionView,
                let layout = view.collectionViewLayout as? MosaicCanvasLayout
            else { return }
            if recognizer.state == .began { startScale = layout.scale }
            let previous = layout.scale
            let next = min(2, max(0.4, startScale * recognizer.scale))
            let anchor = recognizer.location(in: view)
            layout.scale = next
            layout.invalidateLayout()
            view.layoutIfNeeded()
            view.contentOffset = CGPoint(
                x: max(0, view.contentOffset.x + anchor.x * (next / previous - 1)),
                y: max(0, view.contentOffset.y + anchor.y * (next / previous - 1)))
        }
    }
}

// Frames are computed once per layout invalidation. A spatial hash returns only
// intersecting tiles during pan, so per-frame layout cost follows viewport size.
final class MosaicCanvasLayout: UICollectionViewLayout {
    var clusters: [MosaicCluster] = [] { didSet { dirty = true } }
    var scale: CGFloat = 1 { didSet { dirty = true } }
    private var dirty = true
    private var preparedSize = CGSize.zero
    private var cells: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var headers: [Int: UICollectionViewLayoutAttributes] = [:]
    private var buckets: [String: Set<IndexPath>] = [:]
    private var headerBuckets: [String: Set<Int>] = [:]
    private var size = CGSize.zero
    private let bucketSize: CGFloat = 256
    override var collectionViewContentSize: CGSize { size }
    override func prepare() {
        super.prepare()
        let boundsSize = collectionView?.bounds.size ?? .zero
        guard dirty || preparedSize != boundsSize else { return }
        dirty = false
        preparedSize = boundsSize
        cells.removeAll(keepingCapacity: true)
        headers.removeAll(keepingCapacity: true)
        buckets.removeAll(keepingCapacity: true)
        headerBuckets.removeAll(keepingCapacity: true)
        let unit = 112 * scale
        let gap = 4 * scale
        let worldWidth = max(700, (collectionView?.bounds.width ?? 440) * 1.6) * scale
        var cursorX: CGFloat = 20
        var cursorY: CGFloat = 16
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        for (section, cluster) in clusters.enumerated() {
            let bandWidth = (unit + gap) * CGFloat(cluster.items.count == 1 ? 2 : 4)
            if cursorX + bandWidth > worldWidth, cursorX > 20 {
                cursorX = 20
                cursorY += rowHeight + 28 * scale
                rowHeight = 0
            }
            let originX = cursorX
            var groupMaxY = cursorY + 44
            let header = UICollectionViewLayoutAttributes(
                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                with: IndexPath(item: 0, section: section))
            header.frame = CGRect(x: originX, y: cursorY, width: bandWidth, height: 36)
            headers[section] = header
            for x in Int(header.frame.minX / bucketSize)...Int(header.frame.maxX / bucketSize) {
                for y in Int(header.frame.minY / bucketSize)...Int(header.frame.maxY / bucketSize) {
                    headerBuckets["\(x),\(y)", default: []].insert(section)
                }
            }
            for index in cluster.items.indices {
                // Each block has one 2×2 hero and twelve small tiles: no overlapping
                // frames, with a varied rhythm that remains stable across scrolls.
                let block = index / 13
                let slot = index % 13
                let coordinates: (Int, Int, Int)
                if slot == 0 {
                    coordinates = (0, 0, 2)
                } else if slot <= 4 {
                    coordinates = (2 + (slot - 1) % 2, (slot - 1) / 2, 1)
                } else {
                    coordinates = ((slot - 5) % 4, 2 + (slot - 5) / 4, 1)
                }
                let path = IndexPath(item: index, section: section)
                let attr = UICollectionViewLayoutAttributes(forCellWith: path)
                attr.frame = CGRect(
                    x: originX + CGFloat(coordinates.0) * (unit + gap),
                    y: cursorY + 44 + CGFloat(block * 4 + coordinates.1) * (unit + gap),
                    width: CGFloat(coordinates.2) * (unit + gap) - gap,
                    height: CGFloat(coordinates.2) * (unit + gap) - gap)
                cells[path] = attr
                maxY = max(maxY, attr.frame.maxY)
                groupMaxY = max(groupMaxY, attr.frame.maxY)
                for x in Int(attr.frame.minX / bucketSize)...Int(attr.frame.maxX / bucketSize) {
                    for y in Int(attr.frame.minY / bucketSize)...Int(attr.frame.maxY / bucketSize) {
                        buckets["\(x),\(y)", default: []].insert(path)
                    }
                }
            }
            rowHeight = max(rowHeight, groupMaxY - cursorY)
            maxX = max(maxX, originX + bandWidth)
            cursorX += bandWidth + 28 * scale
        }
        size = CGSize(
            width: max(collectionView?.bounds.width ?? 0, maxX + 20),
            height: max(collectionView?.bounds.height ?? 0, maxY + 100))
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var paths: Set<IndexPath> = []
        var headerIDs: Set<Int> = []
        for x in Int(floor(rect.minX / bucketSize))...Int(floor(rect.maxX / bucketSize)) {
            for y in Int(floor(rect.minY / bucketSize))...Int(floor(rect.maxY / bucketSize)) {
                paths.formUnion(buckets["\(x),\(y)"] ?? [])
                headerIDs.formUnion(headerBuckets["\(x),\(y)"] ?? [])
            }
        }
        let visibleHeaders = headerIDs.compactMap { headers[$0] }.filter { $0.frame.intersects(rect) }
        return paths.compactMap { cells[$0] }.filter { $0.frame.intersects(rect) } + visibleHeaders
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cells[indexPath]
    }
    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath)
        -> UICollectionViewLayoutAttributes?
    { headers[indexPath.section] }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.size != newBounds.size
    }
}

// Reuse cancels both Photos requests and actor tasks. Identity checks prevent a late
// result from painting the wrong tile after a fast fling across the canvas.
final class MosaicCanvasCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let badge = UILabel()
    private let request = PhotoThumbnailRequest()
    private var task: Task<Void, Never>?
    private var mediaID: String?
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 5
        backgroundColor = .tertiarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        contentView.addSubview(badge)
        badge.font = .preferredFont(forTextStyle: .caption2)
        badge.textColor = .white
        badge.backgroundColor = .black.withAlphaComponent(0.4)
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
        badge.sizeToFit()
        badge.frame = CGRect(
            x: 7, y: contentView.bounds.height - 25, width: badge.bounds.width + 8, height: 18)
    }
    func configure(_ item: MediaItem) {
        prepareForReuse()
        mediaID = item.id
        accessibilityLabel = "\(item.name), \(item.kind.title)"
        badge.text =
            item.kind == .video
            ? "▶ \(item.duration > 0 ? item.durationLabel : "VIDEO")" : item.kind == .animated ? "GIF" : ""
        badge.isHidden = badge.text?.isEmpty ?? true
        if item.isPhotoLibrary {
            request.load(item, pixels: 400) { [weak self] image in
                if self?.mediaID == item.id { self?.imageView.image = image }
            }
        } else {
            task = Task { [weak self] in
                let image = await ThumbnailService.shared.image(for: item, pixels: 400)
                guard !Task.isCancelled, self?.mediaID == item.id else { return }
                self?.imageView.image = image
            }
        }
        setNeedsLayout()
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        request.cancel()
        task?.cancel()
        imageView.image = nil
        mediaID = nil
    }
}

final class MosaicHeader: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .label
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }
}
