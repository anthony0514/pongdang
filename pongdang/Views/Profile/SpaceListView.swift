import SwiftUI

struct SpaceListView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var showingCreate = false
    @State private var showingInvite = false
    @State private var managingSpace: Space?

    var body: some View {
        List {
            ForEach(spaceService.spaces) { space in
                SpaceRow(
                    space: space,
                    isActive: space.id == spaceService.activeSpace?.id,
                    onManage: {
                        managingSpace = space
                    },
                    onSelect: {
                        spaceService.setActiveSpace(space)
                        dismiss()
                    }
                )
            }
        }
        .navigationTitle("스페이스")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingInvite = true
                } label: {
                    Label("멤버 초대", systemImage: "person.badge.plus")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("새 스페이스") {
                    showingCreate = true
                }
            }
        }
        .sheet(isPresented: $showingInvite) {
            InviteView()
                .environmentObject(spaceService)
                .environmentObject(authService)
        }
        .sheet(isPresented: $showingCreate) {
            CreateSpaceView()
                .environmentObject(spaceService)
                .environmentObject(authService)
        }
        .sheet(item: $managingSpace) { space in
            ManageSpaceView(space: space)
                .environmentObject(spaceService)
                .environmentObject(authService)
        }
    }
}

private struct SpaceRow: View {
    let space: Space
    let isActive: Bool
    let onManage: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack {
            Button(action: onSelect) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(space.name)
                        Text("멤버 \(space.memberIDs.count)명")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isActive {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)

            Button(action: onManage) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
