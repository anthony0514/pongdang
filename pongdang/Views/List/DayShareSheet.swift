import MapKit
import SwiftUI

/// Shares one calendar day as a full-screen map story: the day's walks drawn as
/// routes and its places as photo pins.
struct DayShareSheet: View {
    let date: Date
    let visits: [VisitRecord]
    let activities: [ActivityRecord]
    let placeByID: [String: Place]

    @State private var shareImage: UIImage?

    var body: some View {
        ShareImageScaffold(title: DayShareStory.dateFormatter.string(from: date), image: shareImage) {
            EmptyView()
        }
        .task {
            await buildShareImage()
        }
    }

    private func buildShareImage() async {
        let places: [DayShareStory.PlaceMark] = visits.compactMap { visit in
            guard let place = placeByID[visit.placeID] else { return nil }
            return DayShareStory.PlaceMark(
                id: visit.id,
                name: visit.placeName,
                coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                color: place.category.accentColor,
                photoURL: visit.photoURL.flatMap(URL.init(string:))
            )
        }
        let routes = activities.map { (activity: $0, coordinates: $0.routeCoordinates) }

        let allCoordinates = places.map(\.coordinate) + routes.flatMap(\.coordinates)
        guard let snapshot = await DayShareStory.snapshot(covering: allCoordinates) else { return }

        var photos: [String: UIImage] = [:]
        for place in places {
            if let url = place.photoURL {
                photos[place.id] = await ThumbnailCache.shared.image(for: url, pointSize: DayShareStory.photoSize)
            }
        }
        // Walk photos are keyed by activity ID, next to the place photos.
        for activity in activities {
            if let url = activity.photoURL.flatMap(URL.init(string:)) {
                photos[activity.id] = await ThumbnailCache.shared.image(for: url, pointSize: DayShareStory.photoSize)
            }
        }

        let renderer = ImageRenderer(content: DayShareStory(
            date: date,
            snapshot: snapshot,
            places: places,
            routes: routes,
            photos: photos
        ))
        renderer.scale = ShareStoryBackground.renderScale
        shareImage = renderer.uiImage
    }
}

struct DayShareStory: View {
    struct PlaceMark {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let color: Color
        let photoURL: URL?
    }

    static let photoSize: CGFloat = 56
    private static let canvasSize = ShareStoryBackground.size
    /// Room kept clear at the top for the date.
    private static let headerHeight: CGFloat = 130

    let date: Date
    let snapshot: MKMapSnapshotter.Snapshot
    let places: [PlaceMark]
    let routes: [(activity: ActivityRecord, coordinates: [CLLocationCoordinate2D])]
    /// Photos by visit ID or activity ID.
    let photos: [String: UIImage]

    /// Everything that floats over the map and must not overlap: photo pins and name capsules.
    private struct Item {
        enum Kind {
            case photoPlace(Int)
            case placeLabel(Int)
            case routeLabel(Int)
        }

        let kind: Kind
        /// Where the item is tied to on the map; tethers are drawn from here.
        let anchor: CGPoint
        /// Where the item would like to sit.
        let home: CGPoint
        let size: CGSize
    }

    private static let labelFont = UIFont.systemFont(ofSize: 12, weight: .bold)
    private static let maxLabelTextWidth: CGFloat = 130
    private static let labelSpacing: CGFloat = 6

    var body: some View {
        let items = makeItems()
        let positions = Self.spread(items)

        ZStack(alignment: .topLeading) {
            Image(uiImage: snapshot.image)
                .resizable()
                .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)

            ForEach(routes.indices, id: \.self) { index in
                routePath(routes[index].coordinates)
            }

            // Plain place dots stay fixed on their spot.
            ForEach(places.indices, id: \.self) { index in
                if photos[places[index].id] == nil {
                    Circle()
                        .fill(places[index].color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .position(snapshot.point(for: places[index].coordinate))
                }
            }

            // Tethers for anything pushed off its spot.
            Path { path in
                for (item, position) in zip(items, positions) where hypot(position.x - item.home.x, position.y - item.home.y) > 10 {
                    path.move(to: item.anchor)
                    path.addLine(to: position)
                }
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .shadow(color: .black.opacity(0.25), radius: 2)

            ForEach(items.indices, id: \.self) { index in
                itemView(items[index])
                    .position(positions[index])
            }

            header

            ShareStoryBadge()
                .frame(width: Self.canvasSize.width, height: Self.canvasSize.height, alignment: .bottomTrailing)
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        .clipped()
        .environment(\.colorScheme, .light)
    }

    private func makeItems() -> [Item] {
        var items: [Item] = []

        for (index, place) in places.enumerated() {
            let pin = snapshot.point(for: place.coordinate)
            let label = Self.labelSize(place.name)

            if photos[place.id] != nil {
                // Photo with its name underneath, sitting just above the pin.
                let size = CGSize(width: max(Self.photoSize, label.width), height: Self.photoSize + Self.labelSpacing + label.height)
                let home = CGPoint(x: pin.x, y: pin.y - 10 - size.height / 2)
                items.append(Item(kind: .photoPlace(index), anchor: pin, home: home, size: size))
            } else {
                let home = CGPoint(x: pin.x, y: pin.y + 12 + label.height / 2)
                items.append(Item(kind: .placeLabel(index), anchor: pin, home: home, size: label))
            }
        }

        for (index, route) in routes.enumerated() where !route.coordinates.isEmpty {
            let middle = snapshot.point(for: route.coordinates[route.coordinates.count / 2])
            let label = Self.labelSize(routeLabelText(route.activity))
            // With a photo, the walk gets a photo pin with its green capsule underneath, like places do.
            let size = photos[route.activity.id] == nil
                ? label
                : CGSize(width: max(Self.photoSize, label.width), height: Self.photoSize + Self.labelSpacing + label.height)
            let home = CGPoint(x: middle.x, y: middle.y - 8 - size.height / 2)
            items.append(Item(kind: .routeLabel(index), anchor: middle, home: home, size: size))
        }

        return items
    }

    @ViewBuilder
    private func itemView(_ item: Item) -> some View {
        switch item.kind {
        case .photoPlace(let index):
            VStack(spacing: Self.labelSpacing) {
                if let photo = photos[places[index].id] {
                    photoTile(photo, border: .white)
                }
                capsule(places[index].name, foreground: .black, background: .white)
            }
            .frame(width: item.size.width, height: item.size.height)
        case .placeLabel(let index):
            capsule(places[index].name, foreground: .black, background: .white)
        case .routeLabel(let index):
            let activity = routes[index].activity
            VStack(spacing: Self.labelSpacing) {
                if let photo = photos[activity.id] {
                    photoTile(photo, border: .green)
                }
                capsule(routeLabelText(activity), foreground: .white, background: .green)
                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
            }
            .frame(width: item.size.width, height: item.size.height)
        }
    }

    private func photoTile(_ photo: UIImage, border: Color) -> some View {
        Image(uiImage: photo)
            .resizable()
            .scaledToFill()
            .frame(width: Self.photoSize, height: Self.photoSize)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(border, lineWidth: 3))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    private func capsule(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(Font(Self.labelFont))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.maxLabelTextWidth)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }

    private func routePath(_ coordinates: [CLLocationCoordinate2D]) -> some View {
        let points = coordinates.map { snapshot.point(for: $0) }
        let path = Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
        }
        return ZStack {
            path.stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            path.stroke(Color.green, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        }
    }

    private func routeLabelText(_ activity: ActivityRecord) -> String {
        "\(activity.title) · \(ActivityFormat.distance(activity.distanceMeters))"
    }

    private var header: some View {
        Text(Self.dateFormatter.string(from: date))
            .font(.system(size: 34, weight: .heavy))
            .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .padding(.horizontal, 24)
        .padding(.top, 44)
        .frame(width: Self.canvasSize.width, height: Self.headerHeight + 40, alignment: .topLeading)
        .background(
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Layout helpers

    /// Capsule size for a label, measured with the same font the capsule uses.
    private static func labelSize(_ text: String) -> CGSize {
        let measured = (text as NSString).size(withAttributes: [.font: labelFont])
        return CGSize(
            width: min(ceil(measured.width), maxLabelTextWidth) + 16,
            height: ceil(labelFont.lineHeight) + 8
        )
    }

    /// Nudges overlapping items apart a little at a time while pulling each back home.
    /// Same idea as the live map's jelly photos, run once to a resting layout.
    private static func spread(_ items: [Item]) -> [CGPoint] {
        var positions = items.map(\.home)
        let gap: CGFloat = 6

        for _ in 0..<180 {
            for i in items.indices {
                for j in (i + 1)..<items.count {
                    let dx = positions[i].x - positions[j].x
                    let dy = positions[i].y - positions[j].y
                    let overlapX = (items[i].size.width + items[j].size.width) / 2 + gap - abs(dx)
                    let overlapY = (items[i].size.height + items[j].size.height) / 2 + gap - abs(dy)
                    guard overlapX > 0, overlapY > 0 else { continue }

                    // Separate along the shallower axis; split the move between both items.
                    if overlapX < overlapY {
                        let shift = overlapX / 2 * (dx >= 0 ? 1 : -1)
                        positions[i].x += shift
                        positions[j].x -= shift
                    } else {
                        let shift = overlapY / 2 * (dy >= 0 ? 1 : -1)
                        positions[i].y += shift
                        positions[j].y -= shift
                    }
                }
            }

            for i in items.indices {
                positions[i].x += (items[i].home.x - positions[i].x) * 0.04
                positions[i].y += (items[i].home.y - positions[i].y) * 0.04

                // Stay on the canvas and below the date header.
                let half = CGSize(width: items[i].size.width / 2, height: items[i].size.height / 2)
                positions[i].x = min(max(positions[i].x, half.width + 10), canvasSize.width - half.width - 10)
                positions[i].y = min(max(positions[i].y, headerHeight + half.height), canvasSize.height - half.height - 40)
            }
        }
        return positions
    }

    /// A muted map snapshot framed around every coordinate, with room for the header and pins.
    static func snapshot(covering coordinates: [CLLocationCoordinate2D]) async -> MKMapSnapshotter.Snapshot? {
        guard let first = coordinates.first else { return nil }

        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }

        // At least ~700m across so a single place still shows its neighborhood.
        let minimumWidth = 700 * MKMapPointsPerMeterAtLatitude(first.latitude)
        rect = rect.insetBy(dx: -max(0, (minimumWidth - rect.width) / 2), dy: 0)

        // Match the 9:16 canvas, then pad: extra on top for the header, below for labels.
        let aspect = canvasSize.height / canvasSize.width
        if rect.height < rect.width * aspect {
            rect = rect.insetBy(dx: 0, dy: -(rect.width * aspect - rect.height) / 2)
        } else {
            rect = rect.insetBy(dx: -(rect.height / aspect - rect.width) / 2, dy: 0)
        }
        let pointsPerScreenPoint = rect.width / canvasSize.width
        let side = 50 * pointsPerScreenPoint
        rect = MKMapRect(
            x: rect.minX - side,
            y: rect.minY - (headerHeight + 50) * pointsPerScreenPoint,
            width: rect.width + side * 2,
            height: rect.height + (headerHeight + 50 + 70) * pointsPerScreenPoint
        )
        // Re-square to 9:16 after the uneven padding.
        let paddedHeight = rect.width * aspect
        if paddedHeight > rect.height {
            rect.size.height = paddedHeight
        } else {
            let newWidth = rect.height / aspect
            rect = MKMapRect(x: rect.midX - newWidth / 2, y: rect.minY, width: newWidth, height: rect.height)
        }

        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = canvasSize
        let configuration = MKStandardMapConfiguration(emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration
        options.traitCollection = UITraitCollection { traits in
            traits.displayScale = ShareStoryBackground.renderScale
            traits.userInterfaceStyle = .light
        }

        return try? await MKMapSnapshotter(options: options).start()
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 EEEE"
        return formatter
    }()
}
