# Pongdang

소규모 그룹이 함께 장소를 저장하고, 방문 기록을 지도와 캘린더로 쌓아가는 iOS 앱입니다.

## 핵심 기능

- 스페이스 단위 장소 공유
- 지도, 리스트, 캘린더 기반 장소 탐색
- 장소 상세 시트에서 카테고리 변경, 외부 지도 앱 열기, 다른 스페이스로 공유
- 방문 기록 작성 및 날짜별 캘린더 확인
- 외부 앱 공유로 장소 추가
- 기본 스페이스 즐겨찾기

## 앱 구조

- `홈`: 지도 기반 장소 탐색, 스페이스 전환, 장소 추가
- `리스트`: 장소 목록, 검색, 다중 선택 일괄 작업
- `캘린더`: 날짜별 방문 기록 확인
- `프로필`: 스페이스 관리, 알림/앱 설정

## 기술 스택

- SwiftUI
- MapKit / CoreLocation
- Firebase Auth / Firestore / Messaging
- Share Extension

## 현재 구현 포인트

- 장소는 `Space` 기준으로 분리됩니다.
- 리스트에서 항목 롱탭으로 다중 선택 후 일괄 공유/삭제가 가능합니다.
- 장소 상세 시트 좌상단에서 카테고리를 바로 변경할 수 있습니다.
- 앱 정보 푸터에는 이스터에그 오버레이가 있습니다.

## 로컬 실행

1. Xcode에서 `pongdang.xcodeproj`를 엽니다.
2. Firebase 설정 파일(`GoogleService-Info.plist`)과 팀 서명이 유효한지 확인합니다.
3. `pongdang` 스킴으로 실행합니다.

## 문서

- 상세 명세: [docs/SPEC.md](docs/SPEC.md)
- 권한 문서: [docs/PERMISSIONS.md](docs/PERMISSIONS.md)
- 알림 관련 메모: [docs/FIREBASE_MEMBER_NOTIFICATIONS.md](docs/FIREBASE_MEMBER_NOTIFICATIONS.md)
