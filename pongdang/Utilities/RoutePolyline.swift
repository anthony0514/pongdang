import CoreLocation

/// Simplifies GPS tracks and stores them compactly as Google encoded polylines,
/// so a whole route fits in one small Firestore field.
enum RoutePolyline {
    /// Drops points that deviate less than `tolerance` meters from the line
    /// (Douglas-Peucker), which keeps the shape while cutting thousands of points.
    static func simplify(_ coordinates: [CLLocationCoordinate2D], tolerance: Double = 5) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2 else { return coordinates }

        var keep = [Bool](repeating: false, count: coordinates.count)
        keep[0] = true
        keep[coordinates.count - 1] = true

        var stack = [(0, coordinates.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }

            var maxDistance = 0.0
            var maxIndex = start
            for index in (start + 1)..<end {
                let distance = perpendicularDistance(coordinates[index], from: coordinates[start], to: coordinates[end])
                if distance > maxDistance {
                    maxDistance = distance
                    maxIndex = index
                }
            }

            if maxDistance > tolerance {
                keep[maxIndex] = true
                stack.append((start, maxIndex))
                stack.append((maxIndex, end))
            }
        }

        return coordinates.indices.filter { keep[$0] }.map { coordinates[$0] }
    }

    static func encode(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var result = ""
        var previousLatitude = 0
        var previousLongitude = 0

        for coordinate in coordinates {
            let latitude = Int((coordinate.latitude * 1e5).rounded())
            let longitude = Int((coordinate.longitude * 1e5).rounded())
            result += encodeValue(latitude - previousLatitude)
            result += encodeValue(longitude - previousLongitude)
            previousLatitude = latitude
            previousLongitude = longitude
        }

        return result
    }

    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var latitude = 0
        var longitude = 0
        var coordinates: [CLLocationCoordinate2D] = []

        func nextValue() -> Int? {
            var result = 0
            var shift = 0
            while index < bytes.count {
                let byte = Int(bytes[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 {
                    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let deltaLatitude = nextValue(), let deltaLongitude = nextValue() else { break }
            latitude += deltaLatitude
            longitude += deltaLongitude
            coordinates.append(CLLocationCoordinate2D(latitude: Double(latitude) / 1e5, longitude: Double(longitude) / 1e5))
        }

        return coordinates
    }

    private static func encodeValue(_ value: Int) -> String {
        var remaining = value < 0 ? ~(value << 1) : (value << 1)
        var result = ""
        while remaining >= 0x20 {
            result.append(Character(UnicodeScalar(UInt8((0x20 | (remaining & 0x1F)) + 63))))
            remaining >>= 5
        }
        result.append(Character(UnicodeScalar(UInt8(remaining + 63))))
        return result
    }

    private static func perpendicularDistance(
        _ point: CLLocationCoordinate2D,
        from lineStart: CLLocationCoordinate2D,
        to lineEnd: CLLocationCoordinate2D
    ) -> Double {
        // Project onto a local flat plane in meters; fine at walking scale.
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = 111_320.0 * cos(lineStart.latitude * .pi / 180)

        let x = (point.longitude - lineStart.longitude) * metersPerDegreeLongitude
        let y = (point.latitude - lineStart.latitude) * metersPerDegreeLatitude
        let dx = (lineEnd.longitude - lineStart.longitude) * metersPerDegreeLongitude
        let dy = (lineEnd.latitude - lineStart.latitude) * metersPerDegreeLatitude

        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (x * x + y * y).squareRoot() }

        let t = max(0, min(1, (x * dx + y * dy) / lengthSquared))
        let projectedX = t * dx
        let projectedY = t * dy
        return ((x - projectedX) * (x - projectedX) + (y - projectedY) * (y - projectedY)).squareRoot()
    }
}
