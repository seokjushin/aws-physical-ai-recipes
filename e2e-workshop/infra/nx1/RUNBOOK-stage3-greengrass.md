# Stage 3 RUNBOOK — Greengrass 엣지 실설치·실검증 (NX1, seokjus)

> 목적: `setup-greengrass-nx1.sh` + recipe 4개를 seokjus Day1 GPU 박스에서 실제로 돌려
> Greengrass core 설치 → 컴포넌트 등록 → 배포 → Policy Server :5555 까지 end-to-end 검증.
>
> **실행 환경**: `BESTNX1-Developer`는 `ssm:SendCommand` 차단 → code-server(:8888) 웹터미널에서 수동 실행.
> 각 STEP 출력을 신석주(Claude)에게 공유하면 함께 디버깅. **STEP은 순서 의존** — 앞이 OK여야 다음 진행.
>
> 대상 인스턴스: `i-0fa9deb4d7fc81436` (nx1-isaaclab-seokjus, g6.4xlarge=L4 GPU, us-east-1a)
> 사전 완료(이번 세션): day3 스택 `nx1-groot-seokjus-gg` CREATE_COMPLETE, day2-shared EdgeInferenceRepo, gg-provision 정책 Day1 role 부착.
>
> ## 2026-06-05 실행으로 해소한 day3 gg-provision 권한 갭 (재현 시 이미 반영됨)
> day3-greengrass.yaml에 아래가 추가됨 — 처음 배포한 스택이면 최신 템플릿으로 update 필요:
> 1. **IoT CMK kms:Decrypt** (`IotDataCmk` Sid): NX1 IoT registry가 CMK `alias/bestnx1/iot/data`
>    로 암호화됨 → `iot:CreateKeysAndCertificate`/`attach-*`가
>    `UnauthorizedException: Encryption/Decryption failed with Customer Managed Key`로 실패.
>    `kms:Decrypt/GenerateDataKey/DescribeKey` on 그 키 추가로 해소.
> 2. **IoT Jobs 의존 액션** (`GgDeployIotJobDeps` Sid): `greengrass:CreateDeployment`(thing group 타깃)이
>    `iot:DescribeThingGroup`/`iot:CreateJob` 등 의존 액션 요구 → AccessDenied. 추가로 해소.
> 3. **greengrass:ListCoreDevices/ListDeployments** 추가(상태 조회용).
>
> ## 접근 제약 (검증됨)
> - `BESTNX1-Developer`: `ssm:SendCommand` denied, `ssm:StartSession`(+포트포워딩) allowed →
>   비대화형 자동실행 불가, code-server(:8888) 웹터미널 수동 실행만.
> - 인스턴스 역할 `nx1-isaaclab-seokjus-role`: `iot:GetPolicy`/`iot:DescribeRoleAlias` 없음,
>   `iot:DescribeThing`은 KMS 때문에 실패 → preflight는 endpoint 조회만(설치 시 자연 검증).

---

## STEP 0 — code-server 접속 (로컬 터미널, 사용자 PC)

로컬 터미널에서 포트포워딩 터널을 연다(이미 검증됨 — HTTP 302 응답):

```bash
aws ssm start-session --target i-0fa9deb4d7fc81436 \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=8888,localPortNumber=8888 \
  --region us-east-1 --profile BESTNX1-Developer-737138011740
```

브라우저에서 `http://localhost:8888` → code-server 접속 → **Terminal 열기**.
아래 STEP들은 그 code-server 터미널에서 실행한다.

---

## STEP 1 — 환경 점검 (read-only, ~10초)

```bash
echo "=== id/pwd ==="; id; pwd
echo "=== greengrass 기설치? ==="; ls -la /greengrass/v2/bin/greengrass-cli 2>/dev/null || echo NO_GREENGRASS
echo "=== docker/gpu ==="; docker --version || echo NO_DOCKER
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || echo NO_GPU
echo "=== aws 신원 (인스턴스 역할) ==="; aws sts get-caller-identity --query Arn --output text
echo "=== region ==="; curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')" http://169.254.169.254/latest/meta-data/placement/region; echo
echo "=== disk ==="; df -h / /opt 2>/dev/null | tail -3
echo "=== 기존 groot 이미지 ==="; docker images | grep -i groot || echo NO_GROOT_IMAGES
echo "=== [BONUS] IdleMinutes 자동정지 진단 확정 (백그라운드 조사 후속) ==="
echo "--- idle 타이머 active? ---"; systemctl is-active nx1-idle-check.timer 2>/dev/null; systemctl list-timers nx1-idle-check.timer 2>/dev/null | head -3
echo "--- 현재 idle streak 카운터 (144 도달해야 stop) ---"; cat /var/run/nx1-idle-streak 2>/dev/null || sudo cat /var/run/nx1-idle-streak 2>/dev/null || echo "no streak file"
echo "--- idle-check 최근 로그 (어느 게이트가 busy 유발하나) ---"; sudo journalctl -u nx1-idle-check.service -n 15 --no-pager 2>/dev/null || grep -h "nx1-idle" /var/log/syslog 2>/dev/null | tail -15 || echo "no idle log"
echo "--- 현재 loadavg (0.2 게이트 과민 검증; 16vCPU면 0.2는 매우 낮음) ---"; cat /proc/loadavg
echo "--- 현재 busy 유발 후보: 8443/8888 ESTAB + ssm-session-worker ---"; ss -tn 2>/dev/null | grep -E ':(8443|8888)' | grep ESTAB | head; pgrep -af ssm-session-worker | head

---

## STEP 2 — 스크립트 + recipe 가져오기 (dibh S3에서)

스크립트가 `../workshop-components/N1.6/`를 찾으므로 `edge/` 디렉토리 구조를 복원한다.

```bash
cd ~
mkdir -p nx1-edge/scripts nx1-edge/workshop-components/N1.6
DIBH=s3://dibh-737138011740-us-east-1-cloudformation/nx1/day3/edge
aws s3 cp "$DIBH/scripts/setup-greengrass-nx1.sh" nx1-edge/scripts/ --region us-east-1
for C in docker-build setup inference benchmark; do
  aws s3 cp "$DIBH/workshop-components/N1.6/com.workshop.$C/recipe.yaml" \
    "nx1-edge/workshop-components/N1.6/com.workshop.$C/recipe.yaml" --region us-east-1
done
chmod +x nx1-edge/scripts/setup-greengrass-nx1.sh
echo "=== 가져온 파일 ==="; find nx1-edge -type f
```

> 공유: `find nx1-edge -type f` 출력 (5개 파일이어야 함).

---

## STEP 3 — preflight만 단독 확인 (설치 전 dry, ~10초)

스크립트가 day3 CFN 자원(Thing/IoT policy/TES alias)을 보는지만 먼저 확인.
스크립트 자체 preflight를 쓰되, 설치까지 가기 전에 수동으로 같은 체크:

```bash
REGION=us-east-1
aws iot describe-thing --thing-name nx1-groot-seokjus --region $REGION --query thingName --output text
aws iot get-policy --policy-name nx1-groot-seokjus-ggcore-policy --region $REGION --query policyName --output text
aws iot describe-role-alias --role-alias nx1-groot-seokjus-tes --region $REGION --query roleAliasDescription.roleAlias --output text
echo "=== 인스턴스 역할이 cert 생성 가능한지(gg-provision 정책) ==="
aws iot describe-endpoint --endpoint-type iot:Data-ATS --region $REGION --query endpointAddress --output text
aws iot describe-endpoint --endpoint-type iot:CredentialProvider --region $REGION --query endpointAddress --output text
```

> 공유: 3개 이름(nx1-groot-seokjus / ...-ggcore-policy / ...-tes) + 2개 엔드포인트가 나오면 OK.
> 하나라도 에러면 멈추고 공유 — day3 스택/권한 문제.

---

## STEP 4 — setup 스크립트 실행 (⏱️ 김 — 모델 스테이징 + docker 빌드 10~20분)

> ⚠️ 이 단계가 가장 길고 디버깅 포인트가 많다. **백그라운드 + 로그 파일**로 돌려 끊겨도 추적 가능하게.

```bash
cd ~/nx1-edge/scripts
sudo bash setup-greengrass-nx1.sh seokjus 2>&1 | tee /tmp/nx1-setup.log
```

진행 중 주요 단계(스크립트가 출력):
- `[0/6] Preflight` → Thing/policy/TES 확인
- `[2/6] Model staging` → hi-space CloudFront → day2 S3 (Cloud One egress 첫 시험대)
- `[3/6] ECR build + push` → docker 빌드(13GB+, TRT) → nx1/groot-edge-inference:seokjus push
- `[4/6] Installing Greengrass` → cert 생성 + attach + --provision false + nucleus
- `[5/6] Registering components` → com.workshop.seokjus.* ×4

> 공유 포인트:
> - **막히면**: 어느 `[n/6]`에서 어떤 에러인지 + `/tmp/nx1-setup.log` 마지막 30줄.
> - 특히 STEP [2] wget(hi-space CloudFront)이 Cloud One에서 막히는지, [3] docker pull(nvcr.io)·pip이 막히는지 주목.
> - 성공 시: 맨 끝 "NX1 Setup Complete!" + 컴포넌트 등록 OK 5줄.
```

---

## STEP 5 — Greengrass core 등록 확인

```bash
sudo /greengrass/v2/bin/greengrass-cli component list 2>&1 | head -30
echo "=== core device 클라우드 등록 ==="
aws greengrassv2 list-core-devices --region us-east-1 \
  --query "coreDevices[?coreDeviceThingName=='nx1-groot-seokjus']" --output table
echo "=== 컴포넌트 클라우드 등록 ==="
aws greengrassv2 list-components --region us-east-1 \
  --query "components[?starts_with(componentName,'com.workshop.seokjus')].componentName" --output table
```

> 공유: 컴포넌트 리스트 + core device가 HEALTHY로 보이는지.

---

## STEP 6 — setup 컴포넌트 배포 (모델 다운로드 + TRT 빌드, ⏱️ 김)

> ⚠️ code-server 웹터미널 함정 2가지:
> 1. 긴 인라인 JSON에 줄바꿈 삽입 → `Invalid control character`. **JSON은 파일로 쓰고 `file://`**.
> 2. heredoc(`<<'JSON'`)을 들여쓰기해 붙여넣으면 종료 마커 `JSON`이 인식 안 돼 셸이 `>`에서 멈춤.
>    → **`printf` 방식 사용**(아래). 들여쓰기/종료마커 문제 없음.
> setup은 1.1.0(datasetUrl s3:// 지원). docker-build는 1.0.0.

```bash
REGION=us-east-1; ACCT=737138011740
GROUP_ARN=arn:aws:iot:${REGION}:${ACCT}:thinggroup/nx1-groot-seokjus-group

printf '%s\n' \
'{' \
'  "aws.greengrass.Nucleus": {"componentVersion": "2.17.0"},' \
'  "aws.greengrass.Cli": {"componentVersion": "2.17.0"},' \
'  "com.workshop.seokjus.docker-build": {"componentVersion": "1.0.0"},' \
'  "com.workshop.seokjus.setup": {"componentVersion": "1.1.0"}' \
'}' > /tmp/setup-components.json
python3 -c "import json;json.load(open('/tmp/setup-components.json'));print('JSON OK')"

aws greengrassv2 create-deployment \
  --target-arn "$GROUP_ARN" \
  --deployment-name "nx1-seokjus-setup" \
  --components file:///tmp/setup-components.json \
  --deployment-policies '{"componentUpdatePolicy":{"action":"SKIP_NOTIFY_COMPONENTS"}}' \
  --region $REGION
echo "=== 배포 진행 모니터 (반복 실행) ==="
sudo /greengrass/v2/bin/greengrass-cli component list 2>&1 | grep -B1 -A2 "com.workshop.seokjus"
echo "=== 컴포넌트 로그 (setup) ==="
sudo tail -40 /greengrass/v2/logs/com.workshop.seokjus.setup.log 2>/dev/null || echo "no log yet"
```

> 공유: 배포 후 5~10분 뒤 component list의 STATE(FINISHED/RUNNING/BROKEN) + setup 로그 끝부분.
> docker-build·setup이 `FINISHED`(setup은 TRT 빌드 후 종료)면 OK.

---

## STEP 7 — inference 컴포넌트 배포 → Policy Server :5555

```bash
REGION=us-east-1; ACCT=737138011740
GROUP_ARN=arn:aws:iot:${REGION}:${ACCT}:thinggroup/nx1-groot-seokjus-group

printf '%s\n' \
'{' \
'  "aws.greengrass.Nucleus": {"componentVersion": "2.17.0"},' \
'  "aws.greengrass.Cli": {"componentVersion": "2.17.0"},' \
'  "com.workshop.seokjus.docker-build": {"componentVersion": "1.0.0"},' \
'  "com.workshop.seokjus.setup": {"componentVersion": "1.1.0"},' \
'  "com.workshop.seokjus.inference": {"componentVersion": "1.0.0"}' \
'}' > /tmp/inference-components.json
python3 -c "import json;json.load(open('/tmp/inference-components.json'));print('JSON OK')"

aws greengrassv2 create-deployment \
  --target-arn "$GROUP_ARN" \
  --deployment-name "nx1-seokjus-inference" \
  --components file:///tmp/inference-components.json \
  --deployment-policies '{"componentUpdatePolicy":{"action":"SKIP_NOTIFY_COMPONENTS"}}' \
  --region $REGION
echo "=== Policy Server 포트 확인 (몇 분 뒤) ==="
ss -tlnp | grep 5555 && echo "Policy Server LISTEN :5555" || echo "아직 안 뜸 - inference 로그 확인"
echo "=== inference 로그 ==="
sudo tail -40 /greengrass/v2/logs/com.workshop.seokjus.inference.log 2>/dev/null
docker ps | grep groot-workshop-inference || echo "no inference container yet"
```

> 공유: `ss -tlnp | grep 5555` 결과 + inference 로그 끝부분. :5555 LISTEN이면 **Stage 3 핵심 성공**.

---

## STEP 8 (선택) — benchmark 컴포넌트

```bash
# inference 대신 benchmark를 components 맵에 넣어 배포 (PyTorch vs TRT)
# 기대(L40S): PyTorch ~126ms/7.9Hz | TRT ~60ms/16.6Hz. (g6.4xlarge=L4라 수치 다를 수 있음)
sudo tail -60 /greengrass/v2/logs/com.workshop.seokjus.benchmark.log 2>/dev/null
```

---

## 검증 체크리스트 (Stage 3 완료 기준)

- [ ] STEP 4 스크립트 끝까지 성공 (모델 스테이징·docker push·gg 설치·컴포넌트 등록)
- [ ] STEP 5 `greengrass-cli component list`에 com.workshop.seokjus.* 보임 + core device HEALTHY
- [ ] STEP 6 docker-build·setup 컴포넌트 FINISHED (Cloud One egress: nvcr.io/pip/S3/ECR 도달)
- [ ] STEP 7 inference 컴포넌트 RUNNING + Policy Server :5555 LISTEN
- [ ] Cloud One egress 차단 지점 기록 (있으면 → Dimitri)

## 디버깅 참고

- **Greengrass 전체 로그**: `sudo tail -f /greengrass/v2/logs/greengrass.log`
- **컴포넌트별 로그**: `/greengrass/v2/logs/com.workshop.seokjus.<comp>.log`
- **Cloud One egress 의심**: wget/curl/docker pull이 timeout이면 egress 차단 → 어느 호스트(d3ru2qz80ictoo.cloudfront.net / nvcr.io / pythonhosted / *.amazonaws.com)인지 기록.
- **cert 생성 실패**: gg-provision 정책의 iot:CreateKeysAndCertificate 확인 (이미 simulate allowed).
- **TES 자격 실패**: nucleus 로그에서 role alias `nx1-groot-seokjus-tes` 관련 에러 확인.
- **재실행**: 중간 실패 후 재실행 시 스크립트는 idempotent(이미 있으면 스킵). Greengrass 완전 재설치는 `sudo bash setup-greengrass-nx1.sh seokjus --uninstall` 후 재실행.
