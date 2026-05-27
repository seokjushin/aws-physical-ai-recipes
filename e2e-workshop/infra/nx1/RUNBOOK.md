# NX1 Workshop Runbook — Day1 인프라 배포 & 접속 (AWS 초보 / Windows OK)

> 대상: Doosan Bobcat BEST NX1 참가자. CloudShell 차단 + 멤버 신원 권한 한계 때문에 **로컬 설치를 최소화**한 절차입니다.
> 전제: NX1 온보딩 완료(AD 로그인 + `BESTNX1-Developer` + MFA). 계정 `737138011740`, 리전 `us-east-1`.

---

## ⚠️ 먼저 읽기 — 비용/세션 규칙
- 인스턴스는 **무활동 120분 후 자동 정지**되며, **본인은 다시 켤 수 없습니다**(강사만 가능). → **워크샵/숙제는 한 번에 완료하세요.** 오래 자리를 비우지 마세요.
- 끝나면 반드시 **스택 삭제(Teardown)** 로 정리합니다(§5).

---

## 0. (강사 사전 작업 — 참가자는 건너뜀)
강사가 1회 수행하고 아래 2개 URL을 참가자에게 공유합니다.
```bash
# UserData 스크립트 zip 스테이징 → ScriptsZipUrl 출력
cd e2e-workshop/infra/nx1 && ./build-and-stage.sh
# 템플릿도 dibh에 업로드(콘솔 "파일 업로드"는 멤버 권한 밖이라 S3 URL 참조 필수)
aws s3 cp day1-isaaclab.yaml s3://dibh-737138011740-us-east-1-cloudformation/nx1/day1/day1-isaaclab.yaml \
  --profile BESTNX1-Developer-737138011740 --region us-east-1
```
- **템플릿 S3 URL**: `https://dibh-737138011740-us-east-1-cloudformation.s3.amazonaws.com/nx1/day1/day1-isaaclab.yaml`
- **ScriptsZipUrl**: build-and-stage.sh 출력값 (`s3://dibh-.../nx1/day1/userdata-<ver>.zip`)

> 운영 권장: 9명·Windows·빌드 변동성 감안 시, 강사가 인스턴스를 **선배포**해두고 참가자는 3·4단계(접속)만 하는 모델이 안전합니다. 자가배포(2단계)는 숙제/고급용.

---

## 1. 로그인
1. 브라우저에서 AWS Identity Center 포털 접속:
   `https://ad-doosanad-1s129xqo6hgkh.awsapps.com/start/`
2. AD 계정 + MFA로 로그인 → **`BESTNX1-Developer`** 역할 선택.
3. (DCV GUI 쓸 사람만) 로컬에서 하루 1회 `aws sso login` — §4 참고.

---

## 2. 인프라 배포 (브라우저만, 로컬 설치 0)
1. 콘솔 → **CloudFormation** → **Create stack** → *With new resources*.
2. **Template source = Amazon S3 URL** → 강사가 준 **템플릿 S3 URL** 입력. (⚠️ "Upload a template file"은 권한 밖 — 반드시 S3 URL)
3. **Stack name**: `nx1-isaaclab-<본인ID>` (예 `nx1-isaaclab-alice`, 소문자/숫자/하이픈).
4. **Parameters**:
   - `UserId` = 본인 ID(스택명과 동일 규칙, 소문자)
   - `InstanceType` = `g6.4xlarge` (capacity 부족 시 `g6e.4xlarge`)
   - `ScriptsZipUrl` = 강사가 준 zip URL
   - 나머지(`SubnetId`,`AmiId`,`KmsKeyArn`,`IdleMinutes` 등)는 **기본값 그대로**
5. **Configure stack options**:
   - **Permissions → IAM role** = **`CloudFormationDeployer`** 선택 ⚠️필수
   - **Tags** → Key `doosan:owner`, Value `BEST_NX1` 추가 ⚠️필수(없으면 생성 거부)
6. **Submit** → 상태 `CREATE_IN_PROGRESS`. UserData 빌드로 **약 90분** 후 `CREATE_COMPLETE`.
   - 진행/실패 사유는 스택 **Events** 탭에서 확인.

---

## 3. CLI 핸즈온 (S3 / nvidia-smi / docker / EFS) — 로컬 설치 0
1. 콘솔 → **Systems Manager** → **Session Manager** → **Start session**.
2. 대상 목록에서 `nx1-isaaclab-<본인ID>` 선택 → **Start session** → 브라우저 셸 오픈.
3. 인스턴스 역할로 동작하므로 `aws s3 ls`, `nvidia-smi`, `docker ps`, `ls /home/ubuntu/environment` 등 바로 사용.
   ```bash
   sudo su - ubuntu      # ubuntu 사용자로 전환(환경/EFS는 ubuntu 홈)
   nvidia-smi
   df -h /home/ubuntu/environment/efs    # EFS 마운트 확인
   ```

---

## 4. Isaac Sim GUI (NICE DCV) — 유일하게 로컬 설치 필요
SSH/DCV 직접 인바운드는 막혀 있어 **SSM 포트포워딩**으로 접속합니다.

**4-1. 로컬 1회 설치** (Windows/Mac 공통)
- AWS CLI v2: https://aws.amazon.com/cli/
- Session Manager plugin: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

**4-2. 자격 증명 로그인** (하루 1회)
```bash
aws sso login --profile BESTNX1-Developer-737138011740
```

**4-3. 포트포워딩 시작** (인스턴스 ID는 스택 **Outputs → PortForwardCmd** 에 그대로 있음)
```bash
aws ssm start-session --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=8443,localPortNumber=8443 \
  --region us-east-1 --profile BESTNX1-Developer-737138011740
```
> Windows에서 인스턴스 ID 조회(태그):
> ```bat
> aws ec2 describe-instances --filters "Name=tag:Name,Values=nx1-isaaclab-<본인ID>" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text --region us-east-1 --profile BESTNX1-Developer-737138011740
> ```

**4-4. 접속**
- 브라우저 → `https://localhost:8443` (자가서명 인증서 경고는 통과)
- 로그인: 사용자 `ubuntu`, 비밀번호 = **Secrets Manager** 콘솔의 `nx1-isaaclab-<본인ID>-secret` (스택 Outputs `DcvSecretArn`) 값.

## 4b. code-server (브라우저 VSCode) — 선택, 개발 친화 UI
DCV(데스크탑)와 별개로, **브라우저 VSCode(code-server)**를 같은 SSM 포트포워딩으로 쓸 수 있습니다(포트만 8888). 코드 편집·터미널 작업엔 이쪽이 편합니다. (`EnableCodeServer=true`로 배포된 경우)
```bash
aws ssm start-session --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=8888,localPortNumber=8888 \
  --region us-east-1 --profile BESTNX1-Developer-737138011740
```
- 브라우저 → `http://localhost:8888` · 비밀번호 = DCV와 동일(`nx1-isaaclab-<본인ID>-secret`).
- CloudFront 아님 — SSM 터널 localhost로만 접근(인바운드0 SG). 작업 중엔 idle auto-stop도 안 걸림(8888 연결을 활성으로 인식).

---

## 5. 종료 / Teardown
- **한 번에 끝내기**: 자리 비우면 idle 120분 후 자동 정지 → 재시작은 강사만 가능.
- **정리(필수)**: 콘솔 → CloudFormation → 본인 스택 선택 → **Delete**.
  - EC2/EFS/Secret/Role 일괄 삭제. EFS의 데이터가 필요하면 삭제 전 S3로 백업.

---

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| Create stack에서 "Upload" 후 실패 | 멤버는 템플릿 업로드 불가 → **S3 URL**로 지정 |
| `CreateStack` 거부 | IAM role을 `CloudFormationDeployer`로 지정했는지 / 태그 `doosan:owner=BEST_NX1` 넣었는지 확인 |
| Session Manager 대상 목록에 인스턴스 없음 | 빌드 미완(`CREATE_COMPLETE` 전) 또는 SSM 에이전트 미기동 — 몇 분 대기 |
| `localhost:8443` 접속 안 됨 | 포트포워딩 세션이 살아있는지, 8443 로컬 포트 충돌 없는지 확인 |
| 인스턴스가 꺼져 있음 | idle 120분 자동 정지됨 → 강사에게 재시작 요청 |
