import SwiftUI
import UIKit

struct InviteView: View {
    @EnvironmentObject var spaceService: SpaceService
    @EnvironmentObject var authService: AuthService

    @State private var inviteCode = ""
    @State private var joinCode = ""

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { spaceService.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    spaceService.errorMessage = nil
                }
            }
        )
    }

    var body: some View {
        Form {
            Color.clear
                .frame(height: 12)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Section("초대하기") {
                Button("코드 생성") {
                    Task {
                        do {
                            inviteCode = try await spaceService.generateInviteCode(
                                for: spaceService.activeSpace!.id,
                                createdBy: authService.currentUser!.id
                            )
                        } catch {
                            spaceService.errorMessage = error.localizedDescription
                        }
                    }
                }

                if !inviteCode.isEmpty {
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.secondarySystemBackground))

                            Text(inviteCode)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .padding()
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)

                        Button("복사") {
                            UIPasteboard.general.string = inviteCode
                        }

                        Text("이 코드는 48시간 동안 유효합니다")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Section("참여하기") {
                TextField("6자리 코드 입력", text: $joinCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                Button("검색") {
                    Task {
                        do {
                            try await spaceService.joinSpace(
                                with: joinCode.uppercased(),
                                userID: authService.currentUser!.id
                            )
                        } catch {
                            spaceService.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
        .navigationTitle("멤버 초대")
        .navigationBarTitleDisplayMode(.inline)
        .alert("오류", isPresented: errorAlertBinding) {
            Button("확인") {
                spaceService.errorMessage = nil
            }
        } message: {
            Text(spaceService.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
    }
}
