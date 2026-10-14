# Permissions Summary

기준:
- 앱 서비스 레이어 `SpaceService`, `PlaceService`, `VisitRecordService`, `AuthService`
- 현재 프로젝트에 저장된 Firestore 규칙 배포 로그 `firebase-debug.log`

## 스페이스

`add`
- 로그인 사용자만 가능
- 생성자는 본인이어야 함
- 생성 직후 멤버는 생성자 1명만 포함

`edit`
- 스페이스 이름 수정: 방장만 가능
- 멤버 추가: 초대 코드로 직접 입장하는 본인만 가능
- 멤버 제거: 방장만 가능
- 내 집 공개 여부 변경: 해당 멤버 본인만 가능

`remove`
- 스페이스 삭제: 방장만 가능
- 스페이스 탈퇴: 현재 규칙은 본인만 가능하도록 설계되어 있음
- 앱 UI에서 일반 멤버 탈퇴 액션 제공

## 초대 코드

`add`
- 방장만 생성 가능
- 현재 구현은 새 코드 생성 시 같은 스페이스의 기존 코드를 먼저 삭제함

`read`
- 방장만 자신 스페이스의 코드 목록 조회 가능
- 개별 코드 문서 조회는 로그인 사용자 가능

`remove`
- 방장만 삭제 가능

## 장소

`add`
- 로그인 사용자만 가능
- 해당 스페이스 멤버만 가능
- `addedBy`는 요청자 본인이어야 함

`edit`
- 해당 스페이스 멤버 중
- 장소를 추가한 본인 또는 스페이스 방장만 전체 수정 가능
- 방문 여부(`isVisited`)만 바꾸는 작업은 모든 스페이스 멤버 가능

`remove`
- 장소를 추가한 본인 또는 스페이스 방장만 가능

## 방문 기록

구조
- 장소+날짜당 방문 기록 1개 (`visitRecords/{spaceID}_{placeID}_{yyyyMMdd}`)
- 글과 별점은 `visitRecords/{id}/comments` 하위 컬렉션에 댓글로 저장 (댓글마다 별점 1개)
- 방문 문서의 `ratings` (`{userID: {commentID: 별점}}`)는 목록 평균 표시용 복사본

`add`
- 해당 스페이스 멤버만 가능
- 같은 날 기록이 이미 있으면 새로 만들지 않고 그 기록에 댓글로 더함
- 댓글 작성자는 요청자 본인이어야 함

`edit`
- 댓글(글+별점): 작성자 본인만 수정 가능

`remove`
- 댓글: 작성자 본인만 가능, 마지막 댓글이 지워지면 방문 기록도 삭제
- 장소 추가자와 방장은 장소/스페이스 삭제 시 방문 기록과 댓글 전체 삭제 가능

대표 사진
- 방문 기록당 1장, Storage `visitPhotos/{spaceID}/{visitID}/`에 저장 (긴 변 2048px JPEG로 압축)
- 그 방문에 댓글을 남긴 사람만 추가/변경/삭제 가능
- 방문 기록이 삭제되면 사진 파일도 삭제

예전 형식
- 사람별로 따로 저장된 예전 기록은 작성자 앱이 실행될 때 자동으로 별점 달린 댓글로 변환됨

## 운동 (건강 앱)

구조
- `activities/{spaceID}_{workoutID}`: 건강 앱에서 고른 운동 1개 = 문서 1개 (같은 운동은 스페이스당 1번만)
- 경로는 단순화해서 Google polyline 문자열로 저장

`add`
- 해당 스페이스 멤버가 본인 운동만 공유 가능

`edit`
- 불가 (지우고 다시 공유)

`remove`
- 공유한 본인 또는 방장

## 사용자 정보

`edit`
- 본인 문서만 수정 가능

`remove`
- 계정 삭제 시
- 내가 만든 스페이스, 내가 만든 장소, 내 별점과 댓글, 초대 코드 정리 로직이 앱 서비스에 구현되어 있음
- 다른 사람이 만든 스페이스에서는 내 멤버십만 제거됨

## 확인 필요 사항

- Firestore/Storage 규칙 원본 파일은 `LOCAL_FIREBASE/firestore.rules`, `LOCAL_FIREBASE/storage.rules`에 있음 (git 제외). 배포: `cd LOCAL_FIREBASE && firebase deploy --only firestore:rules,storage`
- 현재 문서는 앱 서비스 레이어와 로컬 규칙 파일 기준으로 정리함
