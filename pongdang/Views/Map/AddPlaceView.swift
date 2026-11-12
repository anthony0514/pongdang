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
    /// A real location the place already has: a long-pressed point, coordinates
    /// from a shared link, or the stored location of the place being edited.
    @State private var trustedCoordinate: CLLocationCoordinate2D?
    /// The address at the time `trustedCoordinate` was set. If the user edits the
    /// address, the location is looked up again.
    @State private var trustedAddress = ""
    @State private var selectedCategory: PlaceCategory = .restaurant
    @State private var memo = ""
    @State private var sourceURL: String? = nil
    @State private var selectedSpaceID: String = ""
    @State private var isResolvingCoordinate = false
    @State private var localErrorMessage: String?
    @State private var isSubmitting = false

    private var isEditing: Bool {
        placeToEdit != nil
    }

    private var normalizedPreviewAddress: String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = extractedRoadAddress(from: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty, normalized != trimmed else { return nil }
        return normalized
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing {
                    Section("스페이스") {
                        Picker("저장할 스페이스", selection: $selectedSpaceID) {
                            ForEach(spaceService.spaces) { space in
                                Text(space.name).tag(space.id)
                            }
                        }

                        if let selectedSpace = selectedSpace {
                            Text("\(selectedSpace.name)에 장소를 추가합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("기본 정보") {
                    TextField("장소 이름", text: $name)
                        .onChange(of: name) { _, newValue in
                            name = InputSanitizer.sanitize(newValue, as: .placeName)
                        }
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("주소", text: $address)
                            .onChange(of: address) { _, newValue in
                                address = InputSanitizer.sanitize(newValue, as: .address)
                            }

                        if let normalizedPreviewAddress {
                            Text("정제 주소: \(normalizedPreviewAddress)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("카테고리", selection: $selectedCategory) {
                        ForEach(PlaceCategory.allCases, id: \.self) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                }

                Section("메모") {
                    TextEditor(text: $memo)
                        .onChange(of: memo) { _, newValue in
                            memo = InputSanitizer.truncate(newValue, as: .body)
                        }
                        .frame(minHeight: 96)
                }

                if let localErrorMessage, !localErrorMessage.isEmpty {
                    Section {
                        Text(localErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !isEditing {
                    Section {
                        HStack(alignment: .center, spacing: 12) {
                            Image("app_icon")
                                .resizable()
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("다른 앱에서 바로 추가하기")
                                    .font(.subheadline.weight(.semibold))
                                Text("장소 공유하기 → 퐁당을 선택하세요!")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
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
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSubmitting
                        || placeService.isLoading
                        || isResolvingCoordinate
                    )
                }
            }
            .onAppear {
                if let placeToEdit {
                    name = placeToEdit.name
                    address = placeToEdit.address
                    if !PlaceCoordinateResolver.isSuspicious(
                        latitude: placeToEdit.latitude,
                        longitude: placeToEdit.longitude,
                        address: placeToEdit.address
                    ) {
                        trustedCoordinate = CLLocationCoordinate2D(
                            latitude: placeToEdit.latitude,
                            longitude: placeToEdit.longitude
                        )
                        trustedAddress = placeToEdit.address
                    }
                    selectedCategory = placeToEdit.category
                    memo = placeToEdit.memo ?? ""
                    sourceURL = placeToEdit.sourceURL
                    return
                }

                if let initialAddress {
                    address = initialAddress
                }

                if let initialCoordinate,
                   !PlaceCoordinateResolver.isSuspicious(initialCoordinate, address: initialAddress ?? "") {
                    trustedCoordinate = initialCoordinate
                    trustedAddress = initialAddress ?? ""
                }

                if let initialName, name.isEmpty {
                    name = initialName
                }

                if let initialSourceURL, !initialSourceURL.isEmpty {
                    sourceURL = initialSourceURL
                }

                initializeSelectedSpaceIfNeeded()
            }
            .onChange(of: spaceService.spaces) { _, _ in
                initializeSelectedSpaceIfNeeded()
            }
            .onChange(of: spaceService.activeSpace?.id) { _, newSpaceID in
                guard !isEditing else { return }
                guard selectedSpaceID.isEmpty || !spaceService.spaces.contains(where: { $0.id == selectedSpaceID }) else { return }
                if let newSpaceID {
                    selectedSpaceID = newSpaceID
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

    private var selectedSpace: Space? {
        spaceService.spaces.first(where: { $0.id == selectedSpaceID })
    }

    private func savePlace() {
        guard
            let spaceID = resolvedSpaceIDForSave(),
            let userID = authService.currentUser?.id
        else {
            localErrorMessage = "저장할 스페이스를 선택해 주세요"
            return
        }

        let trimmedName = InputSanitizer.sanitize(
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            as: .placeName
        )
        let sanitizedAddress = InputSanitizer.sanitize(
            sanitizedAddressForSave(address),
            as: .address
        )
        let trimmedMemo = InputSanitizer.sanitize(
            memo.trimmingCharacters(in: .whitespacesAndNewlines),
            as: .body
        )
        let previousMemo = placeToEdit?.memo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldNotifyMemoSaved = !trimmedMemo.isEmpty && trimmedMemo != previousMemo

        let place = Place(
            id: placeToEdit?.id ?? UUID().uuidString,
            spaceID: spaceID,
            name: trimmedName,
            address: sanitizedAddress,
            latitude: 0,  // set below, once the location is resolved
            longitude: 0,
            category: selectedCategory,
            memo: trimmedMemo.isEmpty ? nil : trimmedMemo,
            sourceURL: sourceURL,
            addedBy: placeToEdit?.addedBy ?? userID,
            addedAt: placeToEdit?.addedAt ?? Date(),
            isVisited: placeToEdit?.isVisited ?? false
        )

        Task {
            isSubmitting = true
            isResolvingCoordinate = true
            let resolvedCoordinate = await coordinateForSave(name: trimmedName, address: sanitizedAddress)
            isResolvingCoordinate = false

            // Never fall back to the map's default center: that is how places used
            // to end up pinned on Seoul City Hall.
            guard let finalCoordinate = resolvedCoordinate else {
                localErrorMessage = "위치를 찾지 못했어요. 주소를 다시 확인하거나, 지도를 길게 눌러 위치를 직접 찍어서 추가해 주세요."
                isSubmitting = false
                return
            }

            do {
                localErrorMessage = nil
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
                            memo: place.memo,
                            sourceURL: place.sourceURL,
                            addedBy: place.addedBy,
                            addedAt: place.addedAt,
                            isVisited: place.isVisited
                        ),
                        requestedBy: userID
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
                            memo: place.memo,
                            sourceURL: place.sourceURL,
                            addedBy: place.addedBy,
                            addedAt: place.addedAt,
                            isVisited: place.isVisited
                        ),
                        requestedBy: userID
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
                localErrorMessage = placeService.errorMessage ?? error.localizedDescription
            }
            isSubmitting = false
        }
    }

    private func initializeSelectedSpaceIfNeeded() {
        guard !isEditing else { return }
        guard selectedSpaceID.isEmpty || !spaceService.spaces.contains(where: { $0.id == selectedSpaceID }) else { return }

        if let activeSpaceID = spaceService.activeSpace?.id,
           spaceService.spaces.contains(where: { $0.id == activeSpaceID }) {
            selectedSpaceID = activeSpaceID
        } else if let firstSpaceID = spaceService.spaces.first?.id {
            selectedSpaceID = firstSpaceID
        }
    }

    private func resolvedSpaceIDForSave() -> String? {
        if let existingSpaceID = placeToEdit?.spaceID {
            return existingSpaceID
        }

        let trimmed = selectedSpaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Where to pin the place, best source first. Returns nil rather than guess.
    private func coordinateForSave(name: String, address: String) async -> CLLocationCoordinate2D? {
        // 1. A real point we already have, as long as the address wasn't changed.
        let previousAddress = InputSanitizer.sanitize(sanitizedAddressForSave(trustedAddress), as: .address)
        if let trustedCoordinate, previousAddress == address || address.isEmpty {
            return trustedCoordinate
        }

        // 2. The Naver place the user shared, if it still exists.
        if let coordinate = await PlaceCoordinateResolver.naverCoordinate(from: sourceURL) {
            return coordinate
        }

        // 3. The typed address.
        if let coordinate = await resolvedCoordinateForSave(address: address) {
            return coordinate
        }

        // 4. The place name within the address's district.
        if let coordinate = await PlaceCoordinateResolver.searchByName(name, address: address) {
            return coordinate
        }

        // 5. The address was edited but couldn't be found: keep the real point we had.
        return trustedCoordinate
    }

    private func resolvedCoordinateForSave(address: String) async -> CLLocationCoordinate2D? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return nil }

        for addressCandidate in addressCandidates(from: trimmedAddress) {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = addressCandidate
            request.resultTypes = [.address, .pointOfInterest]
            request.region = PlaceCoordinateResolver.koreaRegion
            if #available(iOS 18.0, *) {
                request.regionPriority = .required
            }

            do {
                let response = try await MKLocalSearch(request: request).start()
                let candidates = response.mapItems.compactMap { item -> (address: String, name: String, coordinate: CLLocationCoordinate2D)? in
                    let candidateAddress = preferredAddress(from: item)
                    let coordinate = MapAddressResolver.coordinate(for: item)
                    guard !candidateAddress.isEmpty,
                          !PlaceCoordinateResolver.isSuspicious(coordinate, address: addressCandidate) else { return nil }
                    return (candidateAddress, item.name ?? "", coordinate)
                }

                let normalizedInputAddress = normalizedAddressString(addressCandidate)
                let normalizedInputName = normalizedSearchString(name)

                let rankedCandidates = candidates.sorted { lhs, rhs in
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
                }

                // The best-ranked result whose address really matches, not a city or district.
                guard let match = rankedCandidates.first(where: {
                    PlaceCoordinateResolver.isAddressMatch(input: addressCandidate, candidate: $0.address)
                }) else {
                    continue
                }

                return match.coordinate
            } catch {
                continue
            }
        }

        return nil
    }

    private func normalizedAddressString(_ value: String) -> String {
        PlaceCoordinateResolver.normalizedAddress(value)
    }

    private func normalizedSearchString(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizedAddressForSave(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*((지하|지상)\s*)?([Bb]\s*)?\d+\s*(층|f|F)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[Bb]\s*\d+\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\d+\s*호\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addressCandidates(from address: String) -> [String] {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let floorStripped = sanitizedAddressForSave(trimmed)
        let coreRoadAddress = extractedRoadAddress(from: floorStripped)

        var candidates: [String] = []

        if !coreRoadAddress.isEmpty {
            candidates.append(coreRoadAddress)
        }

        // 층 정보가 제거된 주소를 우선 시도
        if !floorStripped.isEmpty && !candidates.contains(floorStripped) && floorStripped != trimmed {
            candidates.append(floorStripped)
        }
        if !candidates.contains(trimmed) {
            candidates.append(trimmed)
        }

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

    private func extractedRoadAddress(from value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard !normalized.isEmpty else { return "" }

        let fullPattern = #"((?:[가-힣]+도|경기|강원|충북|충남|전북|전남|경북|경남|제주)\s+)?((?:[가-힣]+시|서울|부산|대구|인천|광주|대전|울산|세종))\s+([가-힣]+(?:구|군))\s+(?:[가-힣0-9]+(?:동|읍|면|리|가)\s+)?([0-9A-Za-z가-힣]+(?:로|길|대로))\s*(\d+(?:-\d+)?)"#
        if let regex = try? NSRegularExpression(pattern: fullPattern),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           match.numberOfRanges >= 6,
           let cityRange = Range(match.range(at: 2), in: normalized),
           let districtRange = Range(match.range(at: 3), in: normalized),
           let roadRange = Range(match.range(at: 4), in: normalized),
           let numberRange = Range(match.range(at: 5), in: normalized) {
            return [
                String(normalized[cityRange]),
                String(normalized[districtRange]),
                String(normalized[roadRange]),
                String(normalized[numberRange]),
            ].joined(separator: " ")
        }

        let compactPattern = #"((?:[가-힣]+시|서울|부산|대구|인천|광주|대전|울산|세종))\s+([가-힣]+(?:구|군))\s+(?:[가-힣0-9]+(?:동|읍|면|리|가)\s+)?([0-9A-Za-z가-힣]+(?:로|길|대로))\s*(\d+(?:-\d+)?)"#
        if let regex = try? NSRegularExpression(pattern: compactPattern),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           match.numberOfRanges >= 5,
           let cityRange = Range(match.range(at: 1), in: normalized),
           let districtRange = Range(match.range(at: 2), in: normalized),
           let roadRange = Range(match.range(at: 3), in: normalized),
           let numberRange = Range(match.range(at: 4), in: normalized) {
            return [
                String(normalized[cityRange]),
                String(normalized[districtRange]),
                String(normalized[roadRange]),
                String(normalized[numberRange]),
            ].joined(separator: " ")
        }

        return normalized
    }

    private func memoNotificationPreview(for memo: String) -> String {
        let trimmed = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 28 else { return trimmed }
        return String(trimmed.prefix(28)) + "..."
    }


    private func preferredAddress(from mapItem: MKMapItem) -> String {
        MapAddressResolver.address(for: mapItem) ?? ""
    }
}
