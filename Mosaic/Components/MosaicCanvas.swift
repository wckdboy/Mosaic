import Photos
import SwiftUI
import UIKit

// One-shot canvas commands. The id lets SwiftUI repeat the same action.
struct CanvasCommand: Equatable {
    enum Action: Equatable { case zoomIn, zoomOut, fit, recenter }
    let id: Int
    let action: Action
}

// A two-dimensional UICollectionView recycles tiles in both axes. SwiftUI's nested
// lazy stacks do not guarantee bounded work for a free-panning, two-axis canvas.
struct MosaicCanvas: UIViewRepresentable {
    let clusters: [MosaicCluster]
    let revision: UUID
    // Distinct viewports are remembered per context, e.g. overview vs. each focus hop.
    let context: String
    var focused = false
    // Search results open on their best match (the start of the world), not its middle.
    var anchorsAtStart = false
    var selectedID: String?
    var tints: [String: UInt32] = [:]
    var favorites: Set<String> = []
    var command: CanvasCommand?
    var onTap: (MediaItem) -> Void
    var onOpen: (MediaItem) -> Void
    var onFavorite: (MediaItem) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UICollectionView {
        let layout = MosaicCanvasLayout()
        let view = CanvasCollectionView(frame: .zero, collectionViewLayout: layout)
        view.onResize = { [weak coordinator = context.coordinator] view in coordinator?.resized(view) }
        view.backgroundColor = .clear
        view.alwaysBounceHorizontal = true
        view.alwaysBounceVertical = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.decelerationRate = .normal
        view.register(MosaicCanvasCell.self, forCellWithReuseIdentifier: "media")
        view.register(
            MosaicHeader.self, forSupplementaryViewOfKind: MosaicCanvasLayout.headerKind,
            withReuseIdentifier: "header")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.prefetchDataSource = context.coordinator
        view.accessibilityIdentifier = "mosaic.canvas"
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        // No double-tap zoom: on a canvas of tappable tiles it fires a selection first.
        // In map mode (no cells), a single tap dives into the tapped region instead.
        let mapTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.mapTap(_:)))
        mapTap.delegate = context.coordinator
        view.addGestureRecognizer(mapTap)
        view.insertSubview(context.coordinator.map, at: 0)
        context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.revision != revision {
            coordinator.apply(self, to: view)
        } else if coordinator.favorites != favorites {
            coordinator.favorites = favorites
            view.reconfigureItems(at: view.indexPathsForVisibleItems)
        }
        if let command, command != coordinator.lastCommand {
            coordinator.lastCommand = command
            coordinator.perform(command.action, in: view)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate
    {
        var parent: MosaicCanvas
        var clusters: [MosaicCluster] = []
        var revision: UUID?
        var contextKey: String?
        var tints: [String: UInt32] = [:]
        var favorites: Set<String> = []
        var lastCommand: CanvasCommand?
        weak var view: UICollectionView?
        private var paths: [String: IndexPath] = [:]
        private var startScale: CGFloat = 1
        // SwiftUI can deliver the first projection before the view has a size;
        // centering then waits for the first real layout pass.
        private var pendingCenter: CGPoint?
        private var viewports: [String: (center: CGPoint, scale: CGFloat)] = [:]
        private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
        // Far zoom shows one pre-rendered bitmap of every item instead of thousands of cells.
        let map = CanvasMapView(frame: .zero)
        private var mapRevision: UUID?

        init(parent: MosaicCanvas) {
            self.parent = parent
            lastCommand = parent.command
        }
        private var layout: MosaicCanvasLayout? { view?.collectionViewLayout as? MosaicCanvasLayout }

        // A new projection crossfades in. The outgoing viewport is remembered so
        // stepping back through a discovery trail returns to the same place.
        func apply(_ canvas: MosaicCanvas, to view: UICollectionView) {
            guard let layout else { return }
            // The first non-empty projection is the real first load; empty ones may precede it.
            let wasEmpty = clusters.allSatisfy(\.items.isEmpty)
            if let key = contextKey, view.bounds.width > 0, !wasEmpty {
                viewports[key] = (visibleCenter(view), layout.scale)
            }
            let changedContext = contextKey != canvas.context
            let firstLoad = revision == nil || wasEmpty
            revision = canvas.revision
            contextKey = canvas.context
            tints = canvas.tints
            favorites = canvas.favorites
            let update = {
                self.clusters = canvas.clusters
                self.paths = [:]
                for (section, cluster) in canvas.clusters.enumerated() {
                    for (index, item) in cluster.items.enumerated() where self.paths[item.id] == nil {
                        self.paths[item.id] = IndexPath(item: index, section: section)
                    }
                }
                layout.focused = canvas.focused
                layout.anchorsAtStart = canvas.anchorsAtStart
                layout.clusters = canvas.clusters
                // A tap keeps the current zoom; only returning to a saved context restores one.
                if changedContext, let saved = self.viewports[canvas.context]?.scale {
                    layout.scale = saved
                } else if changedContext, canvas.focused {
                    // A tapped item is framed larger, with a ring of related media around it.
                    layout.scale = self.heroFitScale(view)
                }
                self.map.reset()
                view.reloadData()
                view.layoutIfNeeded()
                self.updateInsets(view)
                self.updateMap(view)
                self.announceZoom(view)
                if changedContext || firstLoad {
                    // Saved viewports restore only when returning to an earlier context.
                    let saved = changedContext ? self.viewports[canvas.context]?.center : nil
                    let target = saved ?? layout.focusPoint
                    if view.bounds.width > 0 {
                        self.center(view, on: target)
                    } else {
                        self.pendingCenter = target
                    }
                } else {
                    self.clamp(view)
                }
            }
            if changedContext && !firstLoad && !reduceMotion && view.window != nil {
                UIView.transition(
                    with: view, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction],
                    animations: update)
            } else {
                UIView.performWithoutAnimation(update)
            }
        }

        func perform(_ action: CanvasCommand.Action, in view: UICollectionView) {
            guard let layout else { return }
            switch action {
            case .zoomIn: zoom(view, to: layout.scale * 1.6, anchor: nil, animated: true)
            case .zoomOut: zoom(view, to: layout.scale / 1.6, anchor: nil, animated: true)
            case .fit:
                let size = layout.baseSize
                guard size.width > 0, view.bounds.width > 0 else { return }
                // One animation that both zooms and centers; two concurrent ones stutter.
                zoom(
                    view, to: layout.fitScale, anchor: nil, animated: true,
                    focus: CGPoint(x: size.width / 2, y: size.height / 2))
            case .recenter:
                if layout.focused {
                    zoom(view, to: heroFitScale(view), anchor: nil, animated: true, focus: layout.focusPoint, force: true)
                    highlight(IndexPath(item: 0, section: 0), in: view)
                } else if let id = parent.selectedID, let path = paths[id], let frame = layout.baseFrame(at: path) {
                    // Bring the selection back: framed at about a third of the screen, then pulsed.
                    let scale = min(1.6, max(MosaicCanvasLayout.detailScale + 0.1, 0.36 * view.bounds.width / frame.width))
                    zoom(view, to: scale, anchor: nil, animated: true, focus: CGPoint(x: frame.midX, y: frame.midY), force: true)
                    highlight(path, in: view)
                } else {
                    zoom(view, to: 1, anchor: nil, animated: true, focus: layout.focusPoint, force: true)
                }
            }
        }

        func resized(_ view: UICollectionView) {
            updateInsets(view)
            updateMap(view)
            if let point = pendingCenter {
                pendingCenter = nil
                center(view, on: point)
            } else {
                clamp(view)
            }
        }

        // The reference tile fills about half the shorter screen side.
        func heroFitScale(_ view: UICollectionView) -> CGFloat {
            let side = min(view.bounds.width, view.bounds.height)
            guard side > 0 else { return 1 }
            return min(1.5, max(0.5, side * 0.52 / MosaicCanvasLayout.heroSide))
        }
        private func highlight(_ path: IndexPath, in view: UICollectionView) {
            guard !reduceMotion else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                guard let cell = view.cellForItem(at: path) else { return }
                UIView.animateKeyframes(withDuration: 0.5, delay: 0) {
                    UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.4) {
                        cell.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
                    }
                    UIView.addKeyframe(withRelativeStartTime: 0.4, relativeDuration: 0.6) { cell.transform = .identity }
                }
            }
        }
        func announceZoom(_ view: UICollectionView) {
            view.accessibilityValue = "\(Int(((layout?.scale ?? 1) * 100).rounded())) percent zoom"
        }

        // MARK: Viewport math. Centers are stored in unscaled layout coordinates.

        private func visibleCenter(_ view: UICollectionView) -> CGPoint {
            let scale = layout?.scale ?? 1
            return CGPoint(
                x: (view.contentOffset.x + view.bounds.width / 2) / scale,
                y: (view.contentOffset.y + view.bounds.height / 2) / scale)
        }
        private func center(_ view: UICollectionView, on point: CGPoint, animated: Bool = false) {
            let scale = layout?.scale ?? 1
            let target = CGPoint(
                x: point.x * scale - view.bounds.width / 2, y: point.y * scale - view.bounds.height / 2)
            view.setContentOffset(clamped(target, in: view), animated: animated)
        }
        private func clamped(_ offset: CGPoint, in view: UICollectionView) -> CGPoint {
            // The layout's size is current even before UIKit copies it to contentSize.
            let size = layout?.collectionViewContentSize ?? view.contentSize
            let inset = view.contentInset
            return CGPoint(
                x: min(max(-inset.left, offset.x), max(-inset.left, size.width + inset.right - view.bounds.width)),
                y: min(max(-inset.top, offset.y), max(-inset.top, size.height + inset.bottom - view.bounds.height)))
        }
        private func clamp(_ view: UICollectionView) {
            view.contentOffset = clamped(view.contentOffset, in: view)
        }
        // Content smaller than the viewport floats in the middle instead of the corner.
        func updateInsets(_ view: UICollectionView) {
            let size = layout?.collectionViewContentSize ?? view.contentSize
            let x = max(0, (view.bounds.width - size.width) / 2)
            let y = max(0, (view.bounds.height - size.height) / 2)
            let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
            if view.contentInset != inset { view.contentInset = inset }
        }
        private func zoom(
            _ view: UICollectionView, to value: CGFloat, anchor: CGPoint?, animated: Bool,
            focus: CGPoint? = nil, force: Bool = false
        ) {
            guard let layout else { return }
            let next = min(MosaicCanvasLayout.scaleRange.upperBound, max(layout.minimumScale, value))
            let previous = layout.scale
            guard abs(next - previous) > 0.001 || force || focus != nil else { return }
            // The anchor is a point in the viewport that stays under the finger.
            let anchorInView = anchor ?? CGPoint(x: view.bounds.width / 2, y: view.bounds.height / 2)
            let contentPoint = CGPoint(
                x: (view.contentOffset.x + anchorInView.x) / previous,
                y: (view.contentOffset.y + anchorInView.y) / previous)
            let change = {
                layout.scale = next
                layout.invalidateLayout()
                view.layoutIfNeeded()
                self.updateInsets(view)
                self.updateMap(view)
                self.announceZoom(view)
                let target =
                    focus.map {
                        CGPoint(x: $0.x * next - view.bounds.width / 2, y: $0.y * next - view.bounds.height / 2)
                    }
                    ?? CGPoint(x: contentPoint.x * next - anchorInView.x, y: contentPoint.y * next - anchorInView.y)
                view.contentOffset = self.clamped(target, in: view)
            }
            if animated && !reduceMotion {
                UIView.animate(
                    withDuration: 0.28, delay: 0, options: [.curveEaseInOut, .allowUserInteraction],
                    animations: change
                ) { _ in self.refreshResolution(view) }
            } else {
                change()
                if anchor == nil { refreshResolution(view) }
            }
        }
        // Tiles re-request only when a zoom crosses a thumbnail-size bucket.
        private func refreshResolution(_ view: UICollectionView) {
            let stale = view.indexPathsForVisibleItems.filter { path in
                guard let cell = view.cellForItem(at: path) as? MosaicCanvasCell else { return false }
                return cell.pixels != pixels(for: path)
            }
            if !stale.isEmpty { view.reconfigureItems(at: stale) }
        }
        private func pixels(for path: IndexPath) -> Int {
            guard let layout, let frame = layout.baseFrame(at: path) else { return 256 }
            let points = max(frame.width, frame.height) * layout.scale * UIScreen.main.scale
            return points <= 140 ? 128 : points <= 300 ? 256 : points <= 560 ? 512 : 768
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view as? UICollectionView, let layout else { return }
            switch recognizer.state {
            case .began: startScale = layout.scale
            case .changed:
                zoom(view, to: startScale * recognizer.scale, anchor: recognizer.location(in: view).applying(
                    CGAffineTransform(translationX: -view.contentOffset.x, y: -view.contentOffset.y)),
                    animated: false)
            case .ended, .cancelled:
                refreshResolution(view)
            default: break
            }
        }
        @objc func mapTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? UICollectionView, let layout, !layout.showsCells else { return }
            let anchor = recognizer.location(in: view).applying(
                CGAffineTransform(translationX: -view.contentOffset.x, y: -view.contentOffset.y))
            zoom(view, to: max(MosaicCanvasLayout.detailScale * 1.6, 0.7), anchor: anchor, animated: true)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Taps on cells are selections; the map tap only exists while cells are hidden.
            if gestureRecognizer is UITapGestureRecognizer { return layout?.showsCells == false }
            return true
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { gestureRecognizer is UIPinchGestureRecognizer }

        // The map tracks the content frame; it renders lazily the first time it is
        // needed for a projection and is hidden whenever real tiles are on screen.
        func updateMap(_ view: UICollectionView) {
            guard let layout else { return }
            map.frame = CGRect(origin: .zero, size: layout.collectionViewContentSize)
            let visible = !layout.showsCells
            if visible && mapRevision != revision {
                mapRevision = revision
                map.render(frames: layout.allFrames(), clusters: clusters, tints: tints, world: layout.baseSize)
            }
            let alpha: CGFloat = visible ? 1 : 0
            if map.alpha != alpha {
                if reduceMotion { map.alpha = alpha } else { UIView.animate(withDuration: 0.2) { self.map.alpha = alpha } }
            }
            map.accessibilityElementsHidden = !visible
        }

        // MARK: Data

        func item(at path: IndexPath) -> MediaItem? {
            guard clusters.indices.contains(path.section), clusters[path.section].items.indices.contains(path.item)
            else { return nil }
            return clusters[path.section].items[path.item]
        }
        func numberOfSections(in collectionView: UICollectionView) -> Int { clusters.count }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            clusters[section].items.count
        }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
            -> UICollectionViewCell
        {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "media", for: indexPath)
            if let cell = cell as? MosaicCanvasCell, let item = item(at: indexPath) {
                let hero = layout?.focused == true && indexPath == IndexPath(item: 0, section: 0)
                cell.configure(
                    item, pixels: pixels(for: indexPath), tint: tints[item.id],
                    favorite: favorites.contains(item.id), hero: hero)
            }
            return cell
        }
        func collectionView(
            _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
            at indexPath: IndexPath
        ) -> UICollectionReusableView {
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: "header", for: indexPath)
            if let header = view as? MosaicHeader, clusters.indices.contains(indexPath.section) {
                let cluster = clusters[indexPath.section]
                header.configure(title: cluster.title, count: cluster.items.count)
            }
            return view
        }
        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            guard let item = item(at: indexPath) else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            if layout?.focused == true && indexPath == IndexPath(item: 0, section: 0) {
                parent.onOpen(item)
            } else {
                parent.onTap(item)
            }
        }
        func collectionView(
            _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let path = indexPaths.first, let item = item(at: path) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let favorite = favorites.contains(item.id)
                return UIMenu(children: [
                    UIAction(title: "Open", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) {
                        _ in self.parent.onOpen(item)
                    },
                    UIAction(title: "Explore similar", image: UIImage(systemName: "sparkles")) { _ in
                        self.parent.onTap(item)
                    },
                    UIAction(
                        title: favorite ? "Unfavorite" : "Favorite",
                        image: UIImage(systemName: favorite ? "heart.slash" : "heart")
                    ) { _ in self.parent.onFavorite(item) },
                ])
            }
        }
        // Photos thumbnails for upcoming tiles are warmed in the caching manager.
        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let groups = Dictionary(grouping: indexPaths.compactMap { path in item(at: path).map { ($0, pixels(for: path)) } }) { $0.1 }
            for (pixels, entries) in groups {
                PhotoThumbnailRequest.prefetch(entries.map(\.0), pixels: pixels)
            }
        }
        func collectionView(
            _ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            let groups = Dictionary(grouping: indexPaths.compactMap { path in item(at: path).map { ($0, pixels(for: path)) } }) { $0.1 }
            for (pixels, entries) in groups {
                PhotoThumbnailRequest.cancelPrefetch(entries.map(\.0), pixels: pixels)
            }
        }
    }
}

// Reports size changes (first layout, rotation, split view) to the coordinator.
final class CanvasCollectionView: UICollectionView {
    var onResize: ((UICollectionView) -> Void)?
    private var lastSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize, bounds.width > 0 else { return }
        lastSize = bounds.size
        onResize?(self)
    }
}

// Base frames are computed once per content change in unscaled coordinates, with a
// spatial hash. Zoom multiplies frames lazily for the queried rect only, so pinching
// costs O(visible tiles) rather than re-laying out the whole library every frame.
final class MosaicCanvasLayout: UICollectionViewLayout {
    static let headerKind = "mosaic-island-header"
    static let unit: CGFloat = 112
    static let gap: CGFloat = 4
    static let islandGap: CGFloat = 64
    static let headerSpace: CGFloat = 44
    static let scaleRange: ClosedRange<CGFloat> = 0.005...3
    // Below this scale tiles would be smaller than ~40 pt: the map replaces cells.
    static let detailScale: CGFloat = 0.36
    static func clampScale(_ value: CGFloat) -> CGFloat {
        min(scaleRange.upperBound, max(scaleRange.lowerBound, value))
    }

    var clusters: [MosaicCluster] = [] { didSet { dirty = true } }
    // Focused layouts spiral ranked items outward from a centered hero (item 0).
    var focused = false { didSet { if focused != oldValue { dirty = true } } }
    var anchorsAtStart = false { didSet { if anchorsAtStart != oldValue { dirty = true } } }
    static var heroSide: CGFloat { 2 * (unit + gap) - gap }
    var scale: CGFloat = 1 {
        didSet {
            scale = Self.clampScale(scale)
            if scale != oldValue {
                scaled.removeAll(keepingCapacity: true)
                placedScale = -1
            }
        }
    }
    private(set) var baseSize = CGSize.zero
    private(set) var focusPoint = CGPoint.zero
    private var dirty = true
    private var frames: [[CGRect]] = []
    private var headerFrames: [CGRect?] = []
    private var islandRects: [CGRect?] = []
    private var labelWidths: [CGFloat] = []
    // Island labels placed for the current scale; colliding smaller ones are hidden.
    private var placedLabels: [Int: CGRect] = [:]
    private var placedScale: CGFloat = -1
    private var buckets: [Int: [IndexPath]] = [:]
    private var scaled: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private let bucketSize: CGFloat = 320

    override var collectionViewContentSize: CGSize {
        CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    }
    var showsCells: Bool { scale >= Self.detailScale }
    // The whole world fits the viewport at this scale ("Show all").
    var fitScale: CGFloat {
        let viewport = collectionView?.bounds.size ?? CGSize(width: 400, height: 800)
        guard baseSize.width > 0, baseSize.height > 0, viewport.width > 0 else { return 1 }
        return min(1, min(viewport.width / baseSize.width, viewport.height / baseSize.height) * 0.94)
    }
    // Zooming out stops once every item is on screen, never earlier.
    var minimumScale: CGFloat { max(Self.scaleRange.lowerBound, min(0.3, fitScale)) }
    func allFrames() -> [[CGRect]] { frames }
    func baseFrame(at path: IndexPath) -> CGRect? {
        frames.indices.contains(path.section) && frames[path.section].indices.contains(path.item)
            ? frames[path.section][path.item] : nil
    }

    override func prepare() {
        super.prepare()
        guard dirty else { return }
        dirty = false
        scaled.removeAll()
        placedScale = -1
        buckets.removeAll(keepingCapacity: true)
        islandRects = []
        if focused { buildSpiral() } else { buildIslands() }
        let font = MosaicHeader.font
        labelWidths = clusters.map { cluster in
            ceil((MosaicHeader.text(cluster.title, cluster.items.count) as NSString)
                .size(withAttributes: [.font: font]).width) + 26
        }
        for (section, sectionFrames) in frames.enumerated() {
            for (item, frame) in sectionFrames.enumerated() {
                let path = IndexPath(item: item, section: section)
                forEachBucket(frame) { buckets[$0, default: []].append(path) }
            }
        }

    }

    // Each island is a near-square block packed with an occupancy grid: a 2×2 hero
    // opens every nine tiles, and smaller tiles backfill the gaps. Islands are then
    // shelf-packed into a roughly square world so panning works in every direction.
    private func buildIslands() {
        let step = Self.unit + Self.gap
        var blocks: [(cells: [(col: Int, row: Int, span: Int)], cols: Int, rows: Int)] = []
        var area: CGFloat = 0
        var widest: CGFloat = 0
        for cluster in clusters {
            let block = Self.pack(count: cluster.items.count)
            blocks.append(block)
            let width = CGFloat(block.cols) * step
            area += (width + Self.islandGap) * (CGFloat(block.rows) * step + Self.headerSpace + Self.islandGap)
            widest = max(widest, width)
        }
        let worldWidth = max(widest, area.squareRoot() * 1.1, 360)
        var x = Self.islandGap / 2
        var y = Self.islandGap / 2
        var shelf: CGFloat = 0
        var maxX: CGFloat = 0
        frames = []
        headerFrames = []
        for block in blocks {
            let width = CGFloat(block.cols) * step - Self.gap
            let height = CGFloat(block.rows) * step - Self.gap + Self.headerSpace
            if x + width > worldWidth, x > Self.islandGap {
                x = Self.islandGap / 2
                y += shelf + Self.islandGap
                shelf = 0
            }
            headerFrames.append(CGRect(x: x, y: y, width: max(width, 160), height: Self.headerSpace - 8))
            let top = y + Self.headerSpace
            islandRects.append(CGRect(x: x, y: top, width: width, height: height - Self.headerSpace))
            frames.append(
                block.cells.map { cell in
                    CGRect(
                        x: x + CGFloat(cell.col) * step, y: top + CGFloat(cell.row) * step,
                        width: CGFloat(cell.span) * step - Self.gap, height: CGFloat(cell.span) * step - Self.gap)
                })
            shelf = max(shelf, height)
            maxX = max(maxX, x + width)
            x += width + Self.islandGap
        }
        baseSize = CGSize(width: maxX + Self.islandGap / 2, height: y + shelf + Self.islandGap / 2)
        focusPoint = anchorsAtStart ? .zero : CGPoint(x: baseSize.width / 2, y: baseSize.height / 2)
    }

    static func pack(count: Int) -> (cells: [(col: Int, row: Int, span: Int)], cols: Int, rows: Int) {
        guard count > 0 else { return ([], 1, 0) }
        if count == 1 { return ([(0, 0, 2)], 2, 2) }
        let cols = max(3, Int((Double(count) * 1.4).squareRoot().rounded()))
        var occupied: [Bool] = []
        var cells: [(col: Int, row: Int, span: Int)] = []
        cells.reserveCapacity(count)
        var cursor = 0
        func free(_ col: Int, _ row: Int) -> Bool {
            let index = row * cols + col
            return index >= occupied.count || !occupied[index]
        }
        func mark(_ col: Int, _ row: Int) {
            let index = row * cols + col
            if index >= occupied.count { occupied += Array(repeating: false, count: index - occupied.count + cols) }
            occupied[index] = true
        }
        for index in 0..<count {
            while !free(cursor % cols, cursor / cols) { cursor += 1 }
            var placed = false
            if index % 9 == 0 && count - index >= 4 {
                // Look a short distance ahead for a 2×2 opening; never leave large holes.
                var probe = cursor
                while probe < cursor + cols * 2 {
                    let col = probe % cols
                    let row = probe / cols
                    if col + 1 < cols, free(col, row), free(col + 1, row), free(col, row + 1), free(col + 1, row + 1) {
                        for dx in 0...1 { for dy in 0...1 { mark(col + dx, row + dy) } }
                        cells.append((col, row, 2))
                        placed = true
                        break
                    }
                    probe += 1
                }
            }
            if !placed {
                mark(cursor % cols, cursor / cols)
                cells.append((cursor % cols, cursor / cols, 1))
            }
        }
        let rows = cells.map { $0.row + $0.span }.max() ?? 0
        return (cells, cols, rows)
    }

    // Item 0 sits at the center as a 2×2 hero (larger reads as an unwanted zoom). Remaining items take the nearest free
    // cells in an ellipse slightly taller than wide (portrait screens), so similarity
    // decreases smoothly in every direction the user pans.
    private func buildSpiral() {
        let step = Self.unit + Self.gap
        let items = clusters.first?.items.count ?? 0
        frames = [[]]
        headerFrames = clusters.map { _ in nil }
        for _ in 1..<max(1, clusters.count) { frames.append([]) }
        guard items > 0 else {
            baseSize = .zero
            return
        }
        let cells = Self.spiralCells(count: items - 1)
        let minCol = min(0, cells.map(\.0).min() ?? 0)
        let minRow = min(0, cells.map(\.1).min() ?? 0)
        let maxCol = max(1, cells.map(\.0).max() ?? 0)
        let maxRow = max(1, cells.map(\.1).max() ?? 0)
        let pad = Self.islandGap
        func origin(_ col: Int, _ row: Int) -> CGPoint {
            CGPoint(x: pad + CGFloat(col - minCol) * step, y: pad + CGFloat(row - minRow) * step)
        }
        let hero = origin(0, 0)
        var result = [CGRect(x: hero.x, y: hero.y, width: 2 * step - Self.gap, height: 2 * step - Self.gap)]
        result += cells.map { cell in
            let point = origin(cell.0, cell.1)
            return CGRect(x: point.x, y: point.y, width: Self.unit, height: Self.unit)
        }
        frames[0] = result
        baseSize = CGSize(
            width: CGFloat(maxCol - minCol + 1) * step + pad * 2,
            height: CGFloat(maxRow - minRow + 1) * step + pad * 2)
        focusPoint = CGPoint(x: result[0].midX, y: result[0].midY)
    }

    static func spiralCells(count: Int) -> [(Int, Int)] {
        guard count > 0 else { return [] }
        var radius = Int((Double(count + 4).squareRoot() / 2).rounded(.up)) + 1
        while true {
            var candidates: [(col: Int, row: Int, distance: Double, angle: Double)] = []
            for row in -radius...(radius + 1) {
                for col in -radius...(radius + 1) where !((0...1).contains(col) && (0...1).contains(row)) {
                    // Measured from the hero's center (0.5, 0.5) in doubled integer units.
                    let dx = Double(2 * col - 1)
                    let dy = Double(2 * row - 1)
                    candidates.append((col, row, dx * dx + dy * dy * 0.8, atan2(dy, dx)))
                }
            }
            if candidates.count >= count {
                candidates.sort { $0.distance == $1.distance ? $0.angle < $1.angle : $0.distance < $1.distance }
                return candidates.prefix(count).map { ($0.col, $0.row) }
            }
            radius += 2
        }
    }

    private func bucketKey(_ x: Int, _ y: Int) -> Int { x &* 1_000_003 &+ y }
    private func forEachBucket(_ frame: CGRect, _ body: (Int) -> Void) {
        for x in Int(frame.minX / bucketSize)...Int(frame.maxX / bucketSize) {
            for y in Int(frame.minY / bucketSize)...Int(frame.maxY / bucketSize) { body(bucketKey(x, y)) }
        }
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard scale > 0 else { return [] }
        let base = CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
        var result: [UICollectionViewLayoutAttributes] = []
        // In map mode the whole world may be in view; skip per-item work entirely.
        if showsCells {
            let minX = max(0, Int(floor(base.minX / bucketSize)))
            let maxX = max(minX, Int(floor(base.maxX / bucketSize)))
            let minY = max(0, Int(floor(base.minY / bucketSize)))
            let maxY = max(minY, Int(floor(base.maxY / bucketSize)))
            var seenCells = Set<IndexPath>()
            for x in minX...maxX {
                for y in minY...maxY {
                    for path in buckets[bucketKey(x, y)] ?? [] where !seenCells.contains(path) {
                        guard let frame = baseFrame(at: path), frame.intersects(base) else { continue }
                        seenCells.insert(path)
                        if let attributes = layoutAttributesForItem(at: path) { result.append(attributes) }
                    }
                }
            }
        }
        placeLabels()
        for (section, frame) in placedLabels where frame.intersects(rect) {
            if let attributes = headerAttributes(section) { result.append(attributes) }
        }
        return result
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        if let cached = scaled[indexPath] { return cached }
        guard let frame = baseFrame(at: indexPath) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = CGRect(
            x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        scaled[indexPath] = attributes
        return attributes
    }
    // Labels keep a fixed point size at every zoom. Above an island when its header
    // space is tall enough, otherwise pinned inside its top-left corner over the
    // tiles. Larger islands claim space first; a label that would collide with an
    // accepted one, or that does not fit its island, is hidden until zooming in.
    private func placeLabels() {
        guard placedScale != scale else { return }
        placedScale = scale
        placedLabels.removeAll(keepingCapacity: true)
        let order = clusters.indices.sorted {
            clusters[$0].items.count == clusters[$1].items.count ? $0 < $1 : clusters[$0].items.count > clusters[$1].items.count
        }
        let height: CGFloat = 30
        let cell: CGFloat = 160
        var grid: [Int: [CGRect]] = [:]
        func keys(_ rect: CGRect) -> [Int] {
            var result: [Int] = []
            for x in Int(floor(rect.minX / cell))...Int(floor(rect.maxX / cell)) {
                for y in Int(floor(rect.minY / cell))...Int(floor(rect.maxY / cell)) { result.append(bucketKey(x, y)) }
            }
            return result
        }
        for section in order {
            guard islandRects.indices.contains(section), let island = islandRects[section],
                labelWidths.indices.contains(section)
            else { continue }
            let tiles = CGRect(
                x: island.minX * scale, y: island.minY * scale, width: island.width * scale,
                height: island.height * scale)
            let width = labelWidths[section]
            let label: CGRect
            if Self.headerSpace * scale >= height + 6 {
                label = CGRect(x: tiles.minX, y: tiles.minY - height - 6, width: width, height: height)
            } else {
                // Pinned to the island's corner, drawn over tiles like a map label. It may
                // extend past a small island; label-to-label collisions still hide it.
                guard tiles.width >= 16, tiles.height >= 16 else { continue }
                let inset = min(6, tiles.width * 0.1)
                label = CGRect(x: tiles.minX + inset, y: tiles.minY + inset, width: width, height: height)
            }
            let padded = label.insetBy(dx: -4, dy: -3)
            let cells = keys(padded)
            guard !cells.contains(where: { grid[$0]?.contains(where: { $0.intersects(padded) }) ?? false }) else {
                continue
            }
            for key in cells { grid[key, default: []].append(padded) }
            placedLabels[section] = label
        }
    }
    private func headerAttributes(_ section: Int) -> UICollectionViewLayoutAttributes? {
        placeLabels()
        guard let frame = placedLabels[section] else { return nil }
        let attributes = UICollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: Self.headerKind, with: IndexPath(item: 0, section: section))
        attributes.frame = frame
        // Labels always draw above tiles and the far-zoom map.
        attributes.zIndex = 100
        return attributes
    }
    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath)
        -> UICollectionViewLayoutAttributes?
    { headerAttributes(indexPath.section) }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }
}

// Reuse cancels both Photos requests and actor tasks. Identity checks prevent a late
// result from painting the wrong tile after a fast fling across the canvas.
final class MosaicCanvasCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let badge = UILabel()
    private let heart = UIImageView(image: UIImage(systemName: "heart.fill"))
    private let request = PhotoThumbnailRequest()
    private var task: Task<Void, Never>?
    private var mediaID: String?
    private(set) var pixels = 0
    private var favorite = false
    private var hero = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = 6
        contentView.layer.cornerCurve = .continuous
        contentView.backgroundColor = .tertiarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        contentView.addSubview(badge)
        contentView.addSubview(heart)
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = .black.withAlphaComponent(0.45)
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true
        heart.tintColor = .white
        heart.contentMode = .scaleAspectFit
        heart.layer.shadowOpacity = 0.4
        heart.layer.shadowRadius = 2
        heart.layer.shadowOffset = .zero
        isAccessibilityElement = true
        accessibilityTraits = .button
        // CGColor borders do not resolve dynamic colors on appearance changes by themselves.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: MosaicCanvasCell, _) in
            cell.updateBorder()
        }
    }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is not supported") }
    private func updateBorder() {
        contentView.layer.borderWidth = hero ? 2 : 0
        contentView.layer.borderColor = UIColor.label.withAlphaComponent(0.8).resolvedColor(with: traitCollection).cgColor
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
        let compact = contentView.bounds.width < 60
        badge.isHidden = compact || (badge.text?.isEmpty ?? true)
        heart.isHidden = !favorite || compact
        badge.sizeToFit()
        badge.frame = CGRect(
            x: 6, y: contentView.bounds.height - 24, width: badge.bounds.width + 10, height: 18)
        heart.frame = CGRect(x: contentView.bounds.width - 22, y: 6, width: 16, height: 16)
        contentView.layer.cornerRadius = min(8, max(3, contentView.bounds.width * 0.05))
    }
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        setNeedsLayout()
    }
    func configure(_ item: MediaItem, pixels: Int, tint: UInt32?, favorite: Bool, hero: Bool) {
        let sameItem = mediaID == item.id
        self.favorite = favorite
        accessibilityLabel = "\(item.name), \(item.kind.title)\(favorite ? ", favorite" : "")"
        accessibilityHint = hero ? "Opens full screen" : "Shows similar media"
        badge.text =
            item.kind == .video
            ? "▶ \(item.duration > 0 ? item.durationLabel : "VIDEO")"
            : item.kind == .animated ? "GIF" : item.kind == .livePhoto ? "LIVE" : ""
        self.hero = hero
        updateBorder()
        // Same item at the same resolution: keep the current image (favorite toggles).
        guard !sameItem || self.pixels != pixels else {
            setNeedsLayout()
            return
        }
        cancel()
        if !sameItem { imageView.image = nil }
        mediaID = item.id
        self.pixels = pixels
        // The analyzed dominant color previews the tile before pixels arrive.
        contentView.backgroundColor =
            tint.map {
                UIColor(
                    red: CGFloat(($0 >> 16) & 255) / 255, green: CGFloat(($0 >> 8) & 255) / 255,
                    blue: CGFloat($0 & 255) / 255, alpha: 1)
            } ?? .tertiarySystemFill
        if item.isPhotoLibrary {
            request.load(item, pixels: pixels) { [weak self] image in
                guard let self, self.mediaID == item.id, let image else { return }
                self.show(image, animated: self.imageView.image == nil)
            }
        } else {
            task = Task { [weak self] in
                let image = await ThumbnailService.shared.image(for: item, pixels: pixels)
                guard !Task.isCancelled, let self, self.mediaID == item.id, let image else { return }
                self.show(image, animated: self.imageView.image == nil)
            }
        }
        setNeedsLayout()
    }
    private func show(_ image: UIImage, animated: Bool) {
        imageView.image = image
        guard animated, !UIAccessibility.isReduceMotionEnabled else { return }
        imageView.alpha = 0
        UIView.animate(withDuration: 0.18, delay: 0, options: .allowUserInteraction) { self.imageView.alpha = 1 }
    }
    private func cancel() {
        request.cancel()
        task?.cancel()
        task = nil
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        cancel()
        imageView.image = nil
        imageView.alpha = 1
        mediaID = nil
        pixels = 0
    }
}

// Island labels are small glass pills, legible over tiles when zoomed far out.
final class MosaicHeader: UICollectionReusableView {
    static let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    static func text(_ title: String, _ count: Int) -> String { "\(title)  \(count.formatted())" }
    private let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        layer.zPosition = 100
        label.adjustsFontForContentSizeCategory = false
        label.textColor = .label
        pill.clipsToBounds = true
        pill.layer.cornerCurve = .continuous
        addSubview(pill)
        pill.contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .header
    }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is not supported") }
    func configure(title: String, count: Int) {
        label.text = Self.text(title, count)
        accessibilityLabel = "\(title), \(count) items"
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        pill.frame = bounds
        pill.layer.cornerRadius = bounds.height / 2
        label.frame = pill.bounds.insetBy(dx: 12, dy: 0)
    }
}
