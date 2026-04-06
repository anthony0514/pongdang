import SwiftUI
import CoreLocation
import MapKit

struct AddPlaceView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @StateObject private var placeService = PlaceService()
    @Environment(\.dismiss) private var dismiss

    var initialCoordinate: CLLocationCoordinate2D?
    var initialAddress: String? = nil
    var initialName: String? = nil
    var initialSourceURL: String? = nil
    var placeToEdit: Place? = nil

    @State private var name = ""
    @State private var address = ""
    @State private var latitude: Double = 37.5665
    @State private var longitude: Double = 126.9780
    @State private var selectedCategory: PlaceCategory = .restaurant
    @State private var tagInput = ""
    @State private var tags: [String] = []
    @State private var memo = ""
    @State private var sourceURL: String? = nil
    @State private var isResolvingCoordinate = false

    private var isEditing: Bool {
        placeToEdit != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("기본 정보") {
                    TextField("장소 이름", text: $name)
                    TextField("주소", text: $address)

                    Picker("카테고리", selection: $selectedCategory) {
                        ForEach(PlaceCategory.allCases, id: \.self) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                }

                Section("태그") {
                    HStack {
                        TextField("태그 입력 후 Return", text: $tagInput)
                            .onSubmit(addTag)
                    }

                    if !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(tags, id: \.self) { tag in
                                    Button {
                                        removeTag(tag)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(tag)
                                            Text("×")
                                        }
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("메모") {
                    TextEditor(text: $memo)
                        .frame(minHeight: 96)
                }
            }
            .navigationTitle(isEditing ? "장소 수정" : "장소 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") {
                        savePlace()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let placeToEdit {
                    name = placeToEdit.name
                    address = placeToEdit.address
                    latitude = placeToEdit.latitude
                    longitude = placeToEdit.longitude
                    selectedCategory = placeToEdit.category
                    tags = placeToEdit.tags
                    memo = placeToEdit.memo ?? ""
                    sourceURL = placeToEdit.sourceURL
                    return
                }

                if let initialCoordinate {
                    latitude = initialCoordinate.latitude
                    longitude = initialCoordinate.longitude
                }

                if let initialAddress {
                    address = initialAddress
                }

                if let initialName, name.isEmpty {
                    name = initialName
                }

                if let initialSourceURL, !initialSourceURL.isEmpty {
                    sourceURL = initialSourceURL
                }
            }
            .overlay {
                if placeService.isLoading || isResolvingCoordinate {
                    ZStack {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                        ProgressView()
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else {
            tagInput = ""
            return
        }

        tags.append(trimmed)
        tagInput = ""
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    private func savePlace() {
        guard
            let spaceID = spaceService.activeSpace?.id,
            let userID = authService.currentUser?.id
        else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedAddress = sanitizedAddressForSave(address)
        let trimmedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousMemo = placeToEdit?.memo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldNotifyMemoSaved = !trimmedMemo.isEmpty && trimmedMemo != previousMemo

        let place = Place(
            id: placeToEdit?.id ?? UUID().uuidString,
            spaceID: spaceID,
            name: trimmedName,
            address: sanitizedAddress,
            latitude: latitude,
            longitude: longitude,
            category: selectedCategory,
            tags: tags,
            memo: trimmedMemo.isEmpty ? nil : trimmedMemo,
            sourceURL: sourceURL,
            addedBy: placeToEdit?.addedBy ?? userID,
            addedAt: placeToEdit?.addedAt ?? Date(),
            isVisited: placeToEdit?.isVisited ?? false
        )

        Task {
            isResolvingCoordinate = true
            let resolvedCoordinate = await resolvedCoordinateForSave(address: sanitizedAddress)
            isResolvingCoordinate = false

            do {
                let finalCoordinate = resolvedCoordinate ?? CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                if isEditing {
                    try await placeService.updatePlace(
                        Place(
                            id: place.id,
                            spaceID: place.spaceID,
                            name: place.name,
                            address: place.address,
                            latitude: finalCoordinate.latitude,
                            longitude: finalCoordinate.longitude,
                            category: place.category,
                            tags: place.tags,
                            memo: place.memo,
                            sourceURL: place.sourceURL,
                            addedBy: place.addedBy,
                            addedAt: place.addedAt,
                            isVisited: place.isVisited
                        )
                    )
                } else {
                    try await placeService.addPlace(
                        Place(
                            id: place.id,
                            spaceID: place.spaceID,
                            name: place.name,
                            address: place.address,
                            latitude: finalCoordinate.latitude,
                            longitude: finalCoordinate.longitude,
                            category: place.category,
                            tags: place.tags,
                            memo: place.memo,
                            sourceURL: place.sourceURL,
                            addedBy: place.addedBy,
                            addedAt: place.addedAt,
                            isVisited: place.isVisited
                        )
                    )
                }

                if shouldNotifyMemoSaved {
                    LocalNotificationManager.schedule(
                        title: "메모가 저장되었어요",
                        body: "\(place.name) · \(memoNotificationPreview(for: trimmedMemo))"
                    )
                }

                dismiss()
            } catch {
            }
        }
    }

    private func resolvedCoordinateForSave(address: String) async -> CLLocationCoordinate2D? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return nil }

        for addressCandidate in addressCandidates(from: trimmedAddress) {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = addressCandidate
            request.resultTypes = [.address, .pointOfInterest]

            do {
                let response = try await MKLocalSearch(request: request).start()
                let candidates = response.mapItems.compactMap { item -> (address: String, name: String, coordinate: CLLocationCoordinate2D)? in
                    let candidateAddress = preferredAddress(from: item)
                    guard !candidateAddress.isEmpty else { return nil }
                    return (candidateAddress, item.name ?? "", item.location.coordinate)
                }

                let normalizedInputAddress = normalizedAddressString(addressCandidate)
                let normalizedInputName = normalizedSearchString(name)

                let bestCandidate = candidates.sorted { lhs, rhs in
                    let lhsAddress = normalizedAddressString(lhs.address)
                    let rhsAddress = normalizedAddressString(rhs.address)
                    let lhsName = normalizedSearchString(lhs.name)
                    let rhsName = normalizedSearchString(rhs.name)

                    let lhsExact = lhsAddress == normalizedInputAddress ? 0 : 1
                    let rhsExact = rhsAddress == normalizedInputAddress ? 0 : 1
                    if lhsExact != rhsExact { return lhsExact < rhsExact }

                    let lhsContains = lhsAddress.contains(normalizedInputAddress) ? 0 : 1
                    let rhsContains = rhsAddress.contains(normalizedInputAddress) ? 0 : 1
                    if lhsContains != rhsContains { return lhsContains < rhsContains }

                    let lhsNameContains = (!normalizedInputName.isEmpty && (lhsName.contains(normalizedInputName) || lhsAddress.contains(normalizedInputName))) ? 0 : 1
                    let rhsNameContains = (!normalizedInputName.isEmpty && (rhsName.contains(normalizedInputName) || rhsAddress.contains(normalizedInputName))) ? 0 : 1
                    if lhsNameContains != rhsNameContains { return lhsNameContains < rhsNameContains }

                    return lhs.name < rhs.name
                }.first

                guard let bestCandidate else { continue }

                let normalizedBestAddress = normalizedAddressString(bestCandidate.address)
                guard isAddressMatchAcceptable(input: normalizedInputAddress, candidate: normalizedBestAddress) else {
                    continue
                }

                return bestCandidate.coordinate
            } catch {
                continue
            }
        }

        return nil
    }

    private func normalizedAddressString(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[\s\-\(\)\[\],\.]"#, with: "", options: .regularExpression)
    }

    private func normalizedSearchString(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizedAddressForSave(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*((지하|지상)\s*)?([Bb]\s*)?\d+\s*(층|f|F)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[Bb]\s*\d+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addressCandidates(from address: String) -> [String] {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let floorStripped = sanitizedAddressForSave(trimmed)

        var candidates: [String] = []

        // 층 정보가 제거된 주소를 우선 시도
        if !floorStripped.isEmpty && floorStripped != trimmed {
            candidates.append(floorStripped)
        }
        candidates.append(trimmed)

        // "서울 " 접두어 제거 변형도 추가
        let base = candidates.first ?? trimmed
        if base.hasPrefix("서울 ") {
            let dropped = String(base.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !dropped.isEmpty && !candidates.contains(dropped) {
                candidates.append(dropped)
            }
        }

        return candidates
    }

    private func memoNotificationPreview(for memo: String) -> String {
        let trimmed = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 28 else { return trimmed }
        return String(trimmed.prefix(28)) + "..."
    }

    private func isAddressMatchAcceptable(input: String, candidate: String) -> Bool {
        guard !input.isEmpty, !candidate.isEmpty else { return false }
        if input == candidate { return true }
        if candidate.contains(input) || input.contains(candidate) { return true }

        let commonPrefixLength = zip(input, candidate).prefix { $0 == $1 }.count
        let threshold = max(8, Int(Double(input.count) * 0.6))
        return commonPrefixLength >= threshold
    }

    private func preferredAddress(from mapItem: MKMapItem) -> String {
        guard let address = mapItem.address else { return "" }

        let fullAddress = address.fullAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullAddress.isEmpty {
            return fullAddress
        }

        if let shortAddress = address.shortAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shortAddress.isEmpty {
            return shortAddress
        }

        return ""
    }
}
