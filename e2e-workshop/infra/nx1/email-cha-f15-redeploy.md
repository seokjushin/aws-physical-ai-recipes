# 메일 초안 — 차일황 수석 (F15 SSM 세션 로그 권한 hotfix 안내)

**To:** 차일황 수석 (`ilhwang.cha@doosan.com`)
**Cc:** 김정재 수석 / Dimitri (FYI), AWS 팀
**Subject:** [NX1 워크샵] Session Manager 접속 에러(`s3:GetEncryptionConfiguration`) 해소 — 스택 재배포 안내

수석님, 보내주신 스크린샷의 SSM 세션 종료 에러 원인 확인했고, day1 템플릿에 누락 권한을 추가했습니다.

## 무엇이 문제였나
NX1 계정의 Session Manager 기본 설정이 **모든 세션을 S3 버킷(`db-bestnx1-us-east-1-sessionmanager-logs`)에 SSE-KMS로 로깅**하도록 강제합니다. 세션을 시작할 때 SSM 에이전트가 그 버킷의 SSE 설정을 먼저 읽는데(`s3:GetEncryptionConfiguration`), 인스턴스 역할에 그 권한이 빠져 있어서 핸드셰이크 단계에서 종료됐습니다.

5/27 단일 인스턴스 검증 때는 통과했었는데, 그건 같은 일자에 KMS 권한(F13)만 추가하고 끝낸 케이스였고, S3 GetEncryptionConfiguration이 **버킷 정책 측에서 일부 principal만 허용**하는 형태라서 다른 역할에서 처음 노출된 것으로 보입니다.

## 적용한 fix
`day1-isaaclab.yaml` InstanceRole에 두 줄 추가했습니다:

- `s3:GetEncryptionConfiguration` on `arn:aws:s3:::db-bestnx1-us-east-1-sessionmanager-logs`
- `s3:PutObject` on `arn:aws:s3:::db-bestnx1-us-east-1-sessionmanager-logs/sessions/*`

(SSM Preferences 실측: `s3BucketName=db-bestnx1-us-east-1-sessionmanager-logs`, `s3KeyPrefix=sessions`, `s3EncryptionEnabled=true`, `kmsKeyId=c52d7d43-…`.)

## 수석님이 하실 일 (둘 중 택1, 5분 이내)

**옵션 A (권장) — Update stack**
1. 콘솔 → CloudFormation → 본인 스택 `nx1-isaaclab-ilhwang` 선택
2. **Update** → *Replace current template* → **Amazon S3 URL** 입력: `https://dibh-737138011740-us-east-1-cloudformation.s3.us-east-1.amazonaws.com/nx1/day1/day1-isaaclab.yaml` (2026-05-28 16:59 UTC 재업로드 완료)
3. Parameters 그대로 → IAM role `CloudFormationDeployer` → Tags `doosan:owner=BEST_NX1` 유지 → Submit
4. UserData 재실행 없음 — IAM 정책만 갱신되어 ~1분 내 `UPDATE_COMPLETE`

**옵션 B — Delete 후 재배포**
스택 삭제 후 0번 가이드대로 다시 Create. UserData 빌드 ~32분 다시 걸림.

## 다른 분들도?
self-deploy 가이드 0번 페이지 상단·"자주 막히는 곳" 표에 동일 안내를 추가했고, 강사 측에서 새 템플릿을 dibh 버킷에 재업로드 후 모든 멤버에게 일괄 공지 예정입니다.

— 신석주
