# F14 패치 — best_nx1 team role에 DCV용 SSM 포트포워딩 권한 추가

> 목적: NX1 Day1 DCV GUI 접속(SSM 포트포워딩)을 가능하게 함. 현재 `BESTNX1-Developer`는
> `ssm:StartSession`을 `instance/*`엔 허용하나 **`AWS-StartPortForwardingSession` 문서엔 미허용**이라
> DCV 터널이 AccessDenied. (IAM 시뮬레이션 확인: `implicitDeny`, MatchedStatements=[].)
> 평셸 세션(문서 미지정)은 동작하므로 이 문서 권한만 추가하면 됨.
>
> 대상 레포: **`DoosanICA/db-aws-teamroles`**, team **`best_nx1`** (CLAUDE.md 셀프서비스 경로).
> ⚠️ seokjushin 계정은 현재 DoosanICA 접근 권한이 없어(레포 0개 visible) 직접 PR 불가 →
> Doosan AD 연동 GitHub 신원 확보(온보딩 "GitHub 핸들 제출") 후 적용, 또는 Dimitri/권한자에게 전달.

## 추가할 IAM 정책 statement (best_nx1 team role / BESTNX1-Developer permission set)

```json
{
  "Sid": "Nx1DcvPortForwarding",
  "Effect": "Allow",
  "Action": "ssm:StartSession",
  "Resource": [
    "arn:aws:ssm:us-east-1::document/AWS-StartPortForwardingSession",
    "arn:aws:ssm:us-east-1::document/AWS-StartPortForwardingSessionToRemoteHost"
  ]
},
{
  "Sid": "Nx1SessionManage",
  "Effect": "Allow",
  "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
  "Resource": "arn:aws:ssm:*:*:session/${aws:userid}-*"
}
```

- 기존 `ssm:StartSession` on `arn:aws:ec2:*:*:instance/*` 는 **유지**(타깃 인스턴스 권한).
- `doosan:owner` 태그 조건 **불필요**(StartSession은 CreateStack과 달리 그 조건 대상 아님).
- 리전을 us-east-2 백업까지 열려면 `us-east-1`→`*` 또는 두 리전 모두 기재.

## PR 정보
- **Title**: `feat(best_nx1): allow SSM port-forwarding documents for NICE DCV access (NX1 MEX PoC)`
- **Body**: Day1 Isaac Lab GPU 호스트는 private 서브넷(public IP 없음, SSH 차단)이라 DCV GUI를 **SSM 포트포워딩**으로만 접근. 현재 team role이 `AWS-StartPortForwardingSession` 문서에 StartSession 미허용 → 9명 전원 DCV 접속 불가. 본 PR이 해당 문서 2종 + 세션 관리 권한을 추가. 인스턴스 타깃 권한·KMS 등 기타는 무변경.
- **Reviewers/태그**: **Dimitri De Wolf + Justin Kruse** (CLAUDE.md PR review 규칙).
- **테스트(머지 전 dev 검증, CLAUDE.md)**: 아래 시뮬레이션이 `allowed`로 바뀌는지 + 실 인스턴스에 포트포워딩 세션 1회.

## 검증 명령 (적용 후 allowed 되어야 함)
```bash
# 1) 정책 시뮬레이션 (현재 implicitDeny → 적용 후 allowed)
aws iam simulate-principal-policy \
  --policy-source-arn <BESTNX1-Developer-role-arn> \
  --action-names ssm:StartSession \
  --resource-arns "arn:aws:ssm:us-east-1::document/AWS-StartPortForwardingSession" \
  --profile BESTNX1-Developer-737138011740 --region us-east-1

# 2) 실 DCV 터널 (Day1 인스턴스 재배포 후)
aws ssm start-session --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=8443,localPortNumber=18443 \
  --profile BESTNX1-Developer-737138011740 --region us-east-1
# → https://localhost:18443 (DCV, ubuntu / Secrets Manager nx1-isaaclab-<id>-secret)
```

## 관련
- Spec §15 **F14** (이 항목), §14 P1 (DCV-over-SSM), RUNBOOK.md Mode 4.
- 함께 해소된 **F13**(SSM 세션 KMS — 인스턴스 역할 kms:Decrypt on alias/ssm/logging)은 Day1 템플릿에서 이미 fix.
