import Contacts
import CoreLocation
import MapKit

// iOS 26 introduced MKMapItem.address, MKMapItem.location and MKReverseGeocodingRequest.
// Older versions fall back to MKPlacemark and CLGeocoder.
enum MapAddressResolver {
    static func address(for mapItem: MKMapItem?) -> String? {
        guard let mapItem else { return nil }

        if #available(iOS 26.0, *) {
            guard let address = mapItem.address else { return nil }
            return firstNonEmpty(address.fullAddress, address.shortAddress)
        }

        return address(for: mapItem.placemark)
    }

    static func coordinate(for mapItem: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26.0, *) {
            return mapItem.location.coordinate
        }
        return mapItem.placemark.coordinate
    }

    static func reverseGeocode(_ location: CLLocation) async -> String? {
        if #available(iOS 26.0, *) {
            let request = MKReverseGeocodingRequest(location: location)
            let mapItem = try? await request?.mapItems.first
            return address(for: mapItem)
        }

        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark.flatMap { address(for: $0) }
    }

    private static func address(for placemark: CLPlacemark) -> String? {
        let formatted = placemark.postalAddress.map {
            CNPostalAddressFormatter.string(from: $0, style: .mailingAddress)
                .components(separatedBy: .newlines)
                .joined(separator: " ")
        }
        return firstNonEmpty(formatted, placemark.name)
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
