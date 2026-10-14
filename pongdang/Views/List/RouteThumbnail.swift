import MapKit
import SwiftUI

/// The route's shape alone, fitted into a soft tile. Reads better than a tiny map.
struct RouteThumbnail: View {
    let coordinates: [CLLocationCoordinate2D]
    var cornerRadius: CGFloat = 14
    var inset: CGFloat = 14
    var lineWidth: CGFloat = 3

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.green.opacity(0.12))
            .overlay {
                GeometryReader { proxy in
                    let points = Self.fittedPoints(coordinates, in: proxy.size, inset: inset)
                    ZStack {
                        Path { path in
                            guard let first = points.first else { return }
                            path.move(to: first)
                            points.dropFirst().forEach { path.addLine(to: $0) }
                        }
                        .stroke(Color.green, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                        if let start = points.first {
                            Circle().fill(.green).frame(width: lineWidth + 4, height: lineWidth + 4).position(start)
                        }
                        if let end = points.last, points.count > 1 {
                            Circle().fill(.red).frame(width: lineWidth + 4, height: lineWidth + 4).position(end)
                        }
                    }
                }
            }
    }

    /// Projects coordinates into the box, keeping the aspect ratio and centering the shape.
    private static func fittedPoints(_ coordinates: [CLLocationCoordinate2D], in size: CGSize, inset: CGFloat) -> [CGPoint] {
        let mapPoints = coordinates.map(MKMapPoint.init)
        guard
            let minX = mapPoints.map(\.x).min(), let maxX = mapPoints.map(\.x).max(),
            let minY = mapPoints.map(\.y).min(), let maxY = mapPoints.map(\.y).max()
        else { return [] }

        let available = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)
        let scale = min(available.width / spanX, available.height / spanY)
        let offsetX = inset + (available.width - spanX * scale) / 2
        let offsetY = inset + (available.height - spanY * scale) / 2

        return mapPoints.map { point in
            CGPoint(x: offsetX + (point.x - minX) * scale, y: offsetY + (point.y - minY) * scale)
        }
    }
}
