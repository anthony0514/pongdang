import SwiftUI
import CoreLocation

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
                if placeService.isLoading {
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

        let place = Place(
            id: placeToEdit?.id ?? UUID().uuidString,
            spaceID: spaceID,
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            category: selectedCategory,
            tags: tags,
            memo: memo.isEmpty ? nil : memo,
            sourceURL: sourceURL,
            addedBy: placeToEdit?.addedBy ?? userID,
            addedAt: placeToEdit?.addedAt ?? Date(),
            isVisited: placeToEdit?.isVisited ?? false
        )

        Task {
            do {
                if isEditing {
                    try await placeService.updatePlace(place)
                } else {
                    try await placeService.addPlace(place)
                }
                dismiss()
            } catch {
            }
        }
    }
}
