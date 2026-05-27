# README — Working in the BEST NX1 AWS Account (db-best-nx1)

> **대상**: NX1 환경이 처음인 팀원 + **Claude Code(또는 다른 AI 에이전트)로 NX1 위에서 작업하는 경우**.
> NX1은 일반 AWS 계정과 **거버넌스가 크게 다릅니다.** 일반 계정 감각으로 작업하면 거의 다 막힙니다. 시작 전 이 문서를 읽으세요.
> 근거·상세: `Bobcat MEX PoC - Workshop NX1 Adaptation Spec`(검증 로그), `RUNBOOK.md`(접속 절차), 상위 `CLAUDE.md`(거버넌스 원문).
> 모든 사실은 2026-05 BEST NX1(`737138011740`, us-east-1) 라이브 실측 기준.

---

## 0. 30초 요약 (이것만 기억해도 절반)
1. **리소스를 직접 못 만든다.** `ec2:RunInstances`, `iam:Create*`, `s3:PutObject`(임의 버킷) 등 전부 implicitDeny. **모든 생성은 CloudFormation 경유** + 서비스롤 `CloudFormationDeployer` + 스택 태그 **`doosan:owner=BEST_NX1`**(없으면 거부).
2. **SSH 없다. CloudShell 없다.** 접속은 **SSM Session Manager**만. GUI(DCV)·code-server는 **SSM 포트포워딩**.
3. **CDK 금지 → CloudFormation만.** VPC는 공유라 생성 금지(`!ImportValue`로 가져다 씀).
4. **IPv6 egress가 막혀 있다.** 인스턴스에서 IPv4를 강제하지 않으면 다운로드가 타임아웃하며 빌드가 2배+ 느려진다.
5. **us-east-1 기본(us-east-2 백업), 그 외 리전 잠금.** Bedrock 강제. 금요일 오전(CST) `main` 자동배포.

---

## 1. NX1이 무엇인가
- **계정**: `BEST NX1` / `737138011740`. Doosan Bobcat **MEX Physical-AI PoC + 워크샵** 워크로드용.
- **소유/운영**: Doosan Bobcat Cloud Infrastructure(**Dimitri De Wolf** / DDIA). 정책·가드레일·서비스 승인 게이트를 그가 통제.
- **로그인**: AWS Identity Center → `https://ad-doosanad-1s129xqo6hgkh.awsapps.com/start/` → 역할 **`BESTNX1-Developer`**(Doosan AD + MFA SSO). SSO 토큰 8–24h → **하루 1회 `aws sso login`**.
- 역할 2종: `BESTNX1-Developer`(전원 기본), `SageMaker Studio NX1`(개별 AD ID로 제공).

## 2. 배포 모델 (가장 중요)
**Developer 신원 = "읽기 + CloudFormation 조종 + SSM 접속"** 만 가능. 실제 리소스는 CFN이 admin 서비스롤로 만든다.

```bash
aws cloudformation deploy \
  --template-file <t>.yaml --stack-name nx1-<name> \
  --role-arn arn:aws:iam::737138011740:role/CloudFormationDeployer \
  --tags doosan:owner=BEST_NX1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --s3-bucket dibh-737138011740-us-east-1-cloudformation \
  --profile BESTNX1-Developer-737138011740 --region us-east-1
```
- `--tags doosan:owner=BEST_NX1` **누락 시 `CreateStack` 거부**(IAM 하드 조건). `create-stack`은 `--tags Key=doosan:owner,Value=BEST_NX1`.
- `CloudFormationDeployer` = **AdministratorAccess** → CFN으로는 무엇이든 생성 가능(SCP·Firewall Manager·Block-Public-Access·리전잠금만 회피).
- **콘솔 배포**: CloudFormation → Create stack → **"Amazon S3 URL"**(파일 업로드는 멤버 권한 밖이라 실패 → 템플릿을 `dibh-...-cloudformation` 버킷에 올려 URL 참조) → IAM role=`CloudFormationDeployer` → 태그 `doosan:owner=BEST_NX1`.
- 멤버 신원으로 **불가**: `ec2:Run/Start/Stop/Terminate`, `iam:Create*/PutRolePolicy`, `s3:PutObject`(임의), `sagemaker:CreateTrainingJob`, `greengrassv2:CreateDeployment`, `iot:CreatePolicy`, `servicequotas:RequestServiceQuotaIncrease`, `ssm:SendCommand`, `cloudshell:*`. → 전부 CFN(또는 인스턴스/실행 역할)으로 우회.

## 3. 접속 (SSH/CloudShell 없음)
| 작업 | 방법 |
|---|---|
| 인프라 배포/삭제 | CloudFormation 콘솔(위) 또는 CLI |
| CLI 핸즈온(S3·docker·nvidia-smi) | **Systems Manager → Session Manager → Start session**(브라우저 셸, 인스턴스 역할로 동작) |
| GUI: DCV / code-server | 로컬 **AWS CLI v2 + Session Manager plugin** → **SSM 포트포워딩** → `https://localhost:8443`(DCV) / `http://localhost:8888`(code-server) |
```bash
aws ssm start-session --target <iid> --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=8443,localPortNumber=8443 --region us-east-1 --profile BESTNX1-Developer-737138011740
```
- 인스턴스는 **public IP 없음** → 태그(`Name=...`)로 instance-id 조회.
- **reboot 직후 SSM 재연결 ~1–2분** 걸림(터널 전 대기). 멤버는 `StartInstances` 불가 → 정지되면 강사가 재시작.

## 4. 하드 거버넌스 제약
- **CloudFormation only**(CDK 미허용; Kiro로 CDK→CFN ~95% 변환 가능).
- **SSH 17중 차단, EC2 Instance Connect 불가 → Session Manager only.**
- **공유 VPC `vpc-0ba18fea83615b131`(172.16.0.0/16)** — 수정 금지(SG는 OK). 서브넷/NAT는 Networking 계정 소유. `!ImportValue db-aws-network3-*`로 참조.
- **Firewall Manager가 위험 SG 룰(예: SSH-from-internet)을 ~30초 내 자동 삭제.** GSOC 모니터링.
- **Private 서브넷 + Block Public Access.** Public IP 미부여.
- **egress = Trend Micro Cloud One**(Bobcat 관리, AWS 비가시). NAT 경유 outbound 전부 검사.
- **IPv6 fully enabled** — 단 IPv6 egress는 black-hole(§6 주의).
- **Bedrock 강제** — 외부 LLM API 키 = 정책 위반. (Claude Code가 LLM 쓸 일 있으면 Bedrock 경유.)
- **리전**: us-east-1 기본 / us-east-2 백업. 그 외 잠금.
- **⚠️ 금요일 오전(CST) `main` 자동배포** — 미머지 변경은 `main`으로 리셋. 목요일 밤(CST)까지 머지.
- **사전 활성(수정 금지)**: Config, Security Hub, Inspector, CloudTrail, Backup, WAF(CloudFront/NLB), Bedrock Guardrail.
- **Windows 호환** — 멤버 전원 Windows. 로컬 스크립트는 Windows 포팅 고려.

## 5. 재사용 자원 (만들지 말고 가져다 쓰기)
| 자원 | 값 |
|---|---|
| 공유 VPC | `vpc-0ba18fea83615b131` (172.16.0.0/16, IPv6 enabled) |
| Private 서브넷(NAT egress) | AppA `subnet-0824e676b789f5f5d`(1a) · AppB `subnet-09db5ca35015f76e3`(1b) |
| Baseline EC2 SG | `sg-0474b60d84ea19741`(인바운드0) |
| SageMaker Studio 도메인 | `d-evroaqdzfcor`("nx1", **SSO**, VpcOnly) |
| Greengrass/IoT | thing group `proto1-orin`/`proto1-thor`, `GreengrassTokenExchangeRole`+alias (db-best-nx1-core가 생성) |
| SSM 세션 KMS | `alias/ssm/logging` (`c52d7d43-...`) — 세션 암호화 강제 |
| CFN 아티팩트/스테이징 버킷 | `dibh-737138011740-us-east-1-cloudformation` (Developer가 PutObject 가능) |
| 네이밍 규칙 | ECR=**`nx1/*`**, S3=**`nx1-*`** 또는 **`dibh-*`** (SCP 스코프) |

## 6. 검증된 함정 (Gotchas) — 실측으로 깨진 것들
> Claude Code/멤버가 가장 자주 막히는 지점. 전부 NX1에서 실제로 겪고 해결한 것.

1. **🔴 IPv6 egress black-hole** — NAT가 IPv4 전용. dual-stack 인스턴스가 AAAA 호스트(raw.githubusercontent, pythonhosted 등)에 IPv6 먼저 시도→connection timeout→IPv4 폴백 반복 → **빌드 90분+(원래 40분)**. **해결: UserData 최선두에서 IPv4 강제** — `/etc/gai.conf`에 `precedence ::ffff:0:0/96 100`, apt `Acquire::ForceIPv4 "true"`, `sysctl net.ipv6.conf.all.disable_ipv6=1`. (적용 후 ~32분.)
2. **🔴 SSM 세션 KMS** — 계정 기본 Session Manager가 `alias/ssm/logging`로 세션 암호화 강제. **인스턴스 역할에 그 키 `kms:Decrypt`/`GenerateDataKey` 없으면 모든 SSM 세션이 핸드셰이크에서 실패**(등록은 Online인데 세션 시작 불가). 인스턴스 역할에 추가.
3. **🟠 DCV/code-server 포트포워딩 권한** — `ssm:StartSession`이 `instance/*`엔 되지만 `document/AWS-StartPortForwardingSession`엔 별도 권한 필요. best_nx1 team role에 부여됨(Dimitri PR). 없으면 AccessDenied.
4. **🟠 SG description ASCII만** — `GroupDescription`/룰 description에 em-dash(`—`)·`>` 등 비-ASCII/특수문자 넣으면 EC2가 거부 → 스택 롤백.
5. **🟠 콘솔 "템플릿 파일 업로드" 실패** — 멤버 s3 스코프 밖(`cf-templates-*`) → **`dibh-...` 버킷에 올려 S3 URL 참조**.
6. **🟠 Studio user-profile = SSO** — 생성 시 `SingleSignOnUserIdentifier=UserName` + `SingleSignOnUserValue`=**정확한 IdC UserName(전체 이메일형)** 필요. **local-part 아님** (AWS팀 `@doosan.com`, Bobcat `@corp.doosan.com`). IdC는 관리계정 `363445155762` 소유 → Developer는 사용자 목록도 못 읽음.
7. **🟡 egress 호스트별 편차** — HF/CloudFront는 빠른데 pythonhosted(pip)는 느림(IPv6 이슈와 겹침). SSM·nvcr.io·docker·HF·pypi·ubuntu·github는 도달 OK, TLS MITM 없음.
8. **🟡 단일 서브넷=단일 AZ** — capacity 부족 시 폴백 없음 → `SubnetId`/`InstanceType` 파라미터화해 재배포.
9. **🟡 reboot 후 SSM 재연결 지연** — 부팅 직후 "TargetNotConnected" 나면 1–2분 대기.

## 7. Claude Code로 NX1에서 작업할 때 (에이전트 가이드)
- **리소스 생성은 항상 CFN + `CloudFormationDeployer` + `doosan:owner=BEST_NX1` 태그.** 직접 `aws ec2 run-instances` 등은 implicitDeny로 실패한다(시도 말 것).
- **읽기/진단은 자유** — `describe-*`, `simulate-principal-policy`(SCP는 `OrganizationsDecisionDetail.AllowedByOrganizations`로 반영됨), `list-*` 등으로 먼저 환경을 실측하라.
- **인프라 생성·변경은 사용자 승인 후.** 비용/시간 큰 것(GPU 빌드 ~32분 등)은 특히.
- **UserData엔 IPv4 강제(§6-1)를 가장 먼저** 넣어라. 안 하면 빌드가 말없이 느려진다.
- **SSM 세션 쓰는 인스턴스 역할엔 `alias/ssm/logging` `kms:Decrypt`(§6-2)** 필수.
- **SG description·태그 값은 ASCII.** 네이밍은 `nx1/*`(ECR)·`nx1-*`/`dibh-*`(S3).
- **SSH/CloudShell 가정 코드 금지.** 접속은 SSM. 큰 다운로드/긴 작업은 백그라운드 + 폴링.
- **teardown 규율**: 테스트 스택은 `delete-stack`. S3 버킷에 객체 있으면 삭제 막힘(empty 먼저). MLflow tracking server 등 **상시 과금 리소스는 안 쓰면 제거**.
- **us-east-1 고정.** 다른 리전 시도는 잠겨 있다.

## 8. 도움 채널
- **Service Navigator**(`https://servicenavigator.doosan.com/bobcat`) — 루틴/그룹 신청. ⚠️ AD에 매니저 정보 없으면 신청 자체가 막힘(로컬 HR로 해결).
- **Office Hours**(주 3회) · **Design Review**(주요 단계 전후, PowerPoint 불필요·GitHub 마크다운 OK, 보안/거버넌스/인프라 초점).
- **PR Review**: `DoosanICA` repos. PR엔 **Dimitri + Justin Kruse** 태그.
- **핵심 repos**: `db-best-nx1-core`(KMS/Bedrock/Studio foundation), `db-aws-teamroles`(팀 역할 — 권한 추가 PR), `db-githubactions-aws`, `db-aws-config`, `db-best-nx1-vla-workshop`(워크샵 코드).

## 9. 참고
- 접속 절차 상세: `RUNBOOK.md`
- 검증 로그·근거: `Bobcat MEX PoC - Workshop NX1 Adaptation Spec`
- NX1판 CFN: 이 폴더 `day1-isaaclab.yaml` · `day2-shared.yaml` · `day2-user.yaml` · `day3-greengrass.yaml`
- 거버넌스 원문: 상위 `CLAUDE.md`, `2026-05-15 NX1 Onboarding` 회의록
