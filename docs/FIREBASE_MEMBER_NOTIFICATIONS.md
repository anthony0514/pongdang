# Firebase Member Notification Setup

목표:
- 멤버가 스페이스에 새로 참가하면 같은 스페이스의 기존 멤버에게 푸시 알림 발송
- 멤버가 새 장소를 추가하면 같은 스페이스의 다른 멤버에게 푸시 알림 발송
- 멤버가 새 메모를 추가하면 같은 스페이스의 다른 멤버에게 푸시 알림 발송
- 각 사용자는 설정 탭에서 `새 멤버 참가`, `새 장소 등록`, `새 메모 작성`을 개별 토글 가능

현재 앱에서 이미 준비된 데이터:
- `users/{userId}.receivesNewMemberNotifications: Bool`
- `users/{userId}.receivesNewPlaceNotifications: Bool`
- `users/{userId}.receivesNewMemoNotifications: Bool`
- `users/{userId}.fcmTokens: [String]`

## 1. Firebase Console에서 APNs 키 등록

1. Firebase Console에서 프로젝트 `pongdang-e3592` 열기
2. `Project settings > Cloud Messaging` 이동
3. Apple 앱 설정에서 APNs 인증 키 업로드
4. 개발/운영 키가 분리되어 있으면 둘 다 등록

공식 문서:
- https://firebase.google.com/docs/cloud-messaging/ios/get-started

## 2. iOS 앱에서 토큰 수집 확인

이번 앱 변경으로 다음 흐름이 연결됨:
- 알림 권한 허용 시 `registerForRemoteNotifications()` 호출
- `UIApplicationDelegateAdaptor` 기반 AppDelegate에서 FCM delegate 연결
- FCM registration token 갱신 시 `users/{userId}.fcmTokens`에 저장

확인 방법:
- 로그인 후 Firestore `users` 문서에 `fcmTokens` 배열이 생기는지 확인
- `receivesNewMemberNotifications`, `receivesNewPlaceNotifications`, `receivesNewMemoNotifications`가 저장되는지 확인

공식 문서:
- https://firebase.google.com/docs/cloud-messaging/ios/get-started

## 3. Cloud Functions for Firebase 추가

권장 방식:
- Cloud Functions 2nd gen
- Firestore trigger 사용
- Node.js Admin SDK로 멀티캐스트 전송

공식 문서:
- Firestore trigger: https://firebase.google.com/docs/functions/firestore-events
- FCM Admin SDK 전송: https://firebase.google.com/docs/cloud-messaging/send/admin-sdk

예시 초기화:

```bash
firebase login
firebase init functions
```

질문이 나오면:
- 기존 프로젝트 선택: `pongdang-e3592`
- JavaScript 또는 TypeScript 선택
- 2nd gen 기준으로 진행

## 4. 발송 트리거 설계

### 새 멤버 참가 알림

트리거:
- `spaces/{spaceId}` 문서 `onDocumentUpdated`

조건:
- `memberIDs` 길이가 정확히 1 증가했을 때만 발송
- 추가된 멤버 1명을 계산해서 참가자로 간주
- 참가자 본인은 제외
- 기존 멤버 중 `receivesNewMemberNotifications == true` 인 사용자만 대상

### 새 장소 알림

트리거:
- `places/{placeId}` 문서 `onDocumentCreated`

조건:
- `spaceID`, `name`, `addedBy` 사용
- 발신자 본인 제외
- `receivesNewPlaceNotifications == true` 인 멤버만 대상
- `fcmTokens`가 비어 있지 않은 사용자만 대상

### 새 메모 알림

트리거:
- `places/{placeId}` 문서 `onDocumentUpdated`

조건:
- `before.memo` 는 비어 있고 `after.memo` 는 비어 있지 않을 때
또는
- 팀 정책상 "메모 신규 작성"을 "기존 메모 없음 -> 메모 생김"으로만 한정

권장:
- 단순 수정까지 모두 보내지 말고 "처음 메모가 생긴 경우"에만 발송

## 5. 수신 대상 조회 로직

1. 변경된 `place` 문서에서 `spaceID` 확인
2. `spaces/{spaceID}` 문서 조회 후 `memberIDs` 가져오기
3. `memberIDs` 중에서 이벤트 발생 사용자 제거
4. `users` 컬렉션에서 대상 사용자 문서 조회
5. 알림 종류별 opt-in 필드 확인
6. `fcmTokens`를 평탄화해서 멀티캐스트 전송

주의:
- 한 요청에 토큰은 최대 500개 단위로 잘라서 전송
- 실패 토큰은 응답 결과 보고 사용자 문서에서 정리 권장

## 6. Functions 샘플 구조

```js
const { onDocumentCreated, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();
const db = getFirestore();

exports.notifyNewPlace = onDocumentCreated('places/{placeId}', async (event) => {
  const place = event.data?.data();
  if (!place) return;

  await sendSpaceNotification({
    spaceID: place.spaceID,
    actorUserID: place.addedBy,
    preferenceField: 'receivesNewPlaceNotifications',
    title: '새 장소가 추가되었어요',
    body: `${place.name}`,
    data: {
      type: 'new_place',
      placeID: event.params.placeId,
      spaceID: place.spaceID,
    },
  });
});

exports.notifyNewMemberJoin = onDocumentUpdated('spaces/{spaceId}', async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();
  if (!before || !after) return;

  const beforeMemberIDs = Array.isArray(before.memberIDs) ? before.memberIDs : [];
  const afterMemberIDs = Array.isArray(after.memberIDs) ? after.memberIDs : [];

  if (afterMemberIDs.length !== beforeMemberIDs.length + 1) return;

  const joinedUserID = afterMemberIDs.find((id) => !beforeMemberIDs.includes(id));
  if (!joinedUserID) return;

  const recipientUserIDs = beforeMemberIDs.filter((id) => id !== joinedUserID);
  const joinedUserName = await fetchUserName(joinedUserID);

  await sendNotificationToSpecificUsers({
    recipientUserIDs,
    actorUserID: joinedUserID,
    preferenceField: 'receivesNewMemberNotifications',
    title: '새 멤버가 참가했어요',
    body: `${joinedUserName}님이 ${after.name}에 참가했어요`,
    data: {
      type: 'new_member_join',
      spaceID: event.params.spaceId,
      joinedUserID,
    },
  });
});

exports.notifyNewMemo = onDocumentUpdated('places/{placeId}', async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();
  if (!before || !after) return;

  const beforeMemo = (before.memo || '').trim();
  const afterMemo = (after.memo || '').trim();

  if (!beforeMemo && afterMemo) {
    await sendSpaceNotification({
      spaceID: after.spaceID,
      actorUserID: after.addedBy,
      preferenceField: 'receivesNewMemoNotifications',
      title: '새 메모가 추가되었어요',
      body: `${after.name}`,
      data: {
        type: 'new_memo',
        placeID: event.params.placeId,
        spaceID: after.spaceID,
      },
    });
  }
});

async function sendSpaceNotification({ spaceID, actorUserID, preferenceField, title, body, data }) {
  const spaceSnap = await db.collection('spaces').doc(spaceID).get();
  if (!spaceSnap.exists) return;

  const memberIDs = (spaceSnap.data()?.memberIDs || []).filter((id) => id !== actorUserID);
  if (!memberIDs.length) return;

  const userSnaps = await db.collection('users').where('__name__', 'in', memberIDs.slice(0, 10)).get();
  const tokens = userSnaps.docs.flatMap((doc) => {
    const user = doc.data();
    if (user[preferenceField] !== true) return [];
    return Array.isArray(user.fcmTokens) ? user.fcmTokens : [];
  });

  if (!tokens.length) return;

  await getMessaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
    data,
  });
}
```

## 7. Firestore 쿼리 주의사항

- `where('__name__', 'in', memberIDs)` 는 한 번에 최대 10개 ID만 처리 가능
- 멤버가 10명 초과할 수 있으면 chunk 처리 필요
- FCM 멀티캐스트는 최대 500 토큰 단위로 나누는 것이 안전

## 8. 배포

Functions 폴더에서:

```bash
firebase deploy --only functions
```

## 9. 앱 쪽 최종 확인

1. 사용자 A, B가 같은 스페이스에 참여
2. 둘 다 로그인 상태에서 알림 허용
3. 사용자 B의 `users` 문서에 `fcmTokens` 존재 확인
4. 사용자 B에서 `새 멤버 참가`, `새 장소 등록`, `새 메모 작성` 토글 on/off 확인
5. 사용자 A가 새 장소 생성
6. 사용자 A가 기존 메모 없는 장소에 메모 추가
7. 사용자 C가 스페이스에 새로 참가
8. 사용자 B만 알림 받는지 확인
9. 각 토글 off 시 해당 종류 알림만 멈추는지 확인

## 10. 권장 후속 작업

- 실패한 FCM 토큰을 응답 결과 기준으로 `fcmTokens`에서 제거
- 알림 클릭 시 특정 장소 상세로 이동하도록 딥링크 처리
- 배지 숫자 사용 시 읽음 상태 컬렉션 분리
