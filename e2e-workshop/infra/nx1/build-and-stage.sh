#!/bin/bash
# =============================================================================
# build-and-stage.sh  (강사용 — Day1 UserData 스크립트 zip 빌드 + dibh 버킷 업로드)
# =============================================================================
# 업스트림 isaaclab/assets/userdata 의 필요한 스크립트 + NX1 전용 스크립트
# (nx1-prepatch.sh, nx1-idle-autostop-install.sh) + workshop/ 에셋을 한 zip으로
# 묶어 dibh 아티팩트 버킷에 올린다. 출력된 S3 URL을 Day1 스택의 ScriptsZipUrl 파라미터로 사용.
#   ⚠️ code-server.sh / groot.sh / cloudwatch-agent.sh 는 의도적으로 제외(Spec A.4).
# Windows 멤버는 이 단계 불요 — 강사가 미리 스테이징한 URL만 받으면 됨(runbook).
# 사용: ./build-and-stage.sh [PROFILE] [REGION] [BUCKET]
# =============================================================================
set -euo pipefail
PROFILE="${1:-BESTNX1-Developer-737138011740}"
REGION="${2:-us-east-1}"
BUCKET="${3:-dibh-737138011740-us-east-1-cloudformation}"

HERE="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM="$HERE/../isaaclab/assets/userdata"
WORKSHOP="$HERE/../isaaclab/assets/workshop"
STAGE="$(mktemp -d)/userdata"
mkdir -p "$STAGE/workshop"

# 업스트림 스크립트 (필요한 것만)
for f in common.sh nvidia-driver.sh isaac-lab.sh efs-mount.sh code-server.sh; do
  cp "$UPSTREAM/$f" "$STAGE/$f"
done
# NX1 전용 스크립트
cp "$HERE/assets/nx1-prepatch.sh" "$STAGE/nx1-prepatch.sh"
cp "$HERE/assets/nx1-idle-autostop-install.sh" "$STAGE/nx1-idle-autostop-install.sh"
# workshop 에셋
cp "$WORKSHOP/Dockerfile" "$STAGE/workshop/Dockerfile"
cp "$WORKSHOP/distributed_run.bash" "$STAGE/workshop/distributed_run.bash"

VER="$(date -u +%Y%m%d-%H%M%S)"
ZIP="/tmp/nx1-day1-userdata-$VER.zip"
( cd "$STAGE" && zip -qr "$ZIP" . )
KEY="nx1/day1/userdata-$VER.zip"
aws s3 cp "$ZIP" "s3://$BUCKET/$KEY" --profile "$PROFILE" --region "$REGION"

echo
echo "=== ScriptsZipUrl (Day1 스택 파라미터로 사용) ==="
echo "s3://$BUCKET/$KEY"
