#!/bin/bash
# =============================================================================
# setup-greengrass-nx1.sh
# GR00T N1.6 Pick-Orange workshop - Greengrass install + component registration
# (NX1 GOVERNANCE EDITION of setup-greengrass-workshop-N16.sh)
#
# WHAT CHANGED FROM THE ORIGINAL (and why):
#   The original script self-provisioned IoT/IAM at runtime:
#     - aws ecr create-repository                 -> NX1 Developer can only create nx1/*
#     - --provision true (creates Thing/cert/TES) -> NX1 blocks iot:CreatePolicy / iam:CreateRole
#     - put-role-policy on the shared TES role     -> NX1 self-escalation forbidden
#   NX1 pre-creates ALL of that with CloudFormation BEFORE this script runs:
#     - day2-shared.yaml  -> shared ECR repo nx1/groot-edge-inference (+ SageMaker repos)
#     - day3-greengrass.yaml (stack nx1-groot-<UserId>-gg) -> IoT Thing, ThingGroup,
#       core IoT policy, per-user TES role + role alias, and a scoped gg-provision
#       managed policy attached to the Day1 instance role.
#   So this script does NOT create those resources. It:
#     1. builds + pushes the edge inference image to the SHARED ECR repo (per-user tag)
#     2. stages the model into the per-user day2 S3 bucket
#     3. installs Greengrass with --provision FALSE against the pre-created resources
#     4. registers the com.workshop.<UserId>.* components (NX1 ECR/S3 substituted)
#
# Usage: sudo bash setup-greengrass-nx1.sh <USER_ID>
#        sudo bash setup-greengrass-nx1.sh <USER_ID> --uninstall
#
# PREREQUISITE (instructor or self-deploy, once per participant):
#   aws cloudformation create-stack --stack-name nx1-groot-<USER_ID>-gg \
#     --template-url <dibh>/nx1/day3/day3-greengrass.yaml \
#     --parameters UserId=<USER_ID> \
#                  ModelArtifactBucket=nx1-groot-<USER_ID>-<ACCT> \
#                  InstanceRoleName=nx1-isaaclab-<USER_ID>-role \
#     --role-arn arn:aws:iam::<ACCT>:role/CloudFormationDeployer \
#     --tags Key=doosan:owner,Value=BEST_NX1 --capabilities CAPABILITY_NAMED_IAM
#   (and day2-shared deployed once for the whole workshop)
#
# NO put-role-policy here. NO ecr create-repository. NO --provision true.
# =============================================================================
set -euo pipefail

# --- userId ------------------------------------------------------------------
if [ -z "${1:-}" ]; then
  echo "Usage: sudo bash setup-greengrass-nx1.sh <USER_ID> [--uninstall]"
  echo "  install:   sudo bash setup-greengrass-nx1.sh seokjus"
  echo "  uninstall: sudo bash setup-greengrass-nx1.sh seokjus --uninstall"
  exit 1
fi
USER_ID="$1"
UNINSTALL="${2:-}"

# --- environment detection (IMDSv2) ------------------------------------------
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | python3 -c "import sys,json;print(json.load(sys.stdin)['accountId'])")

# --- NX1 naming (matches day3-greengrass.yaml + day2-shared.yaml) ------------
THING_NAME="nx1-groot-${USER_ID}"                 # day3 CoreThing
THING_GROUP="nx1-groot-${USER_ID}-group"          # day3 CoreThingGroup
IOT_POLICY="nx1-groot-${USER_ID}-ggcore-policy"   # day3 CoreIotPolicy
TES_ROLE_ALIAS="nx1-groot-${USER_ID}-tes"         # day3 TesRoleAlias
S3_BUCKET="nx1-groot-${USER_ID}-${ACCOUNT_ID}"    # day2 per-user bucket (ModelArtifactBucket)
ECR_REPO="nx1/groot-edge-inference"               # day2-shared EdgeInferenceRepo (shared)
ECR_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:${USER_ID}"   # per-user tag
GG_ROOT="/greengrass/v2"
NUCLEUS_VERSION="2.17.0"

# --- Uninstall ---------------------------------------------------------------
# Only removes what THIS script created (Greengrass install, cert, components,
# deployments). The IoT Thing/Group/Policy/TES role are owned by CloudFormation
# (delete the nx1-groot-<UserId>-gg stack to remove those).
if [ "$UNINSTALL" = "--uninstall" ]; then
  echo "============================================"
  echo " NX1 N1.6 Greengrass Workshop Uninstall"
  echo "============================================"
  echo " Thing:  $THING_NAME   (Thing/Group/Policy/TES remain - owned by CFN stack nx1-groot-${USER_ID}-gg)"
  echo ""

  echo ">>> [1/4] Stopping Greengrass service"
  systemctl stop greengrass.service 2>/dev/null || true
  systemctl disable greengrass.service 2>/dev/null || true
  rm -rf "$GG_ROOT"
  rm -f /etc/systemd/system/greengrass.service
  systemctl daemon-reload 2>/dev/null || true
  echo "   Greengrass removed"

  echo ">>> [2/4] Cancelling and deleting Greengrass deployments"
  for TARGET in "thing/${THING_NAME}" "thinggroup/${THING_GROUP}"; do
    DEPLOYS=$(aws greengrassv2 list-deployments --target-arn "arn:aws:iot:${REGION}:${ACCOUNT_ID}:${TARGET}" \
      --query 'deployments[].deploymentId' --output text --region "$REGION" 2>/dev/null || echo "")
    for DEPLOY_ID in $DEPLOYS; do
      aws greengrassv2 cancel-deployment --deployment-id "$DEPLOY_ID" --region "$REGION" 2>/dev/null || true
      aws greengrassv2 delete-deployment --deployment-id "$DEPLOY_ID" --region "$REGION" 2>/dev/null || true
      echo "   Deleted deployment: $DEPLOY_ID"
    done
  done
  aws greengrassv2 delete-core-device --core-device-thing-name "$THING_NAME" --region "$REGION" 2>/dev/null && \
    echo "   Deleted core device: $THING_NAME" || true

  echo ">>> [3/4] Detaching + deleting device certificate (Thing itself kept)"
  PRINCIPALS=$(aws iot list-thing-principals --thing-name "$THING_NAME" --region "$REGION" --query 'principals[*]' --output text 2>/dev/null || echo "")
  for CERT_ARN in $PRINCIPALS; do
    CERT_ID=$(echo "$CERT_ARN" | awk -F'/' '{print $NF}')
    aws iot detach-policy --policy-name "$IOT_POLICY" --target "$CERT_ARN" --region "$REGION" 2>/dev/null || true
    aws iot detach-thing-principal --thing-name "$THING_NAME" --principal "$CERT_ARN" --region "$REGION" 2>/dev/null || true
    aws iot update-certificate --certificate-id "$CERT_ID" --new-status INACTIVE --region "$REGION" 2>/dev/null || true
    aws iot delete-certificate --certificate-id "$CERT_ID" --force-delete --region "$REGION" 2>/dev/null || true
    echo "   Deleted certificate: $CERT_ID"
  done

  echo ">>> [4/4] Deleting com.workshop.${USER_ID}.* components"
  for COMP in benchmark docker-build inference setup; do
    ARN="arn:aws:greengrass:${REGION}:${ACCOUNT_ID}:components:com.workshop.${USER_ID}.${COMP}"
    VERSIONS=$(aws greengrassv2 list-component-versions --arn "$ARN" \
      --query "componentVersions[?starts_with(componentVersion,'1.')].componentVersion" \
      --output text --region "$REGION" 2>/dev/null || echo "")
    for VER in $VERSIONS; do
      aws greengrassv2 delete-component --arn "${ARN}:versions:${VER}" --region "$REGION" 2>/dev/null && \
        echo "   Deleted: com.workshop.${USER_ID}.${COMP} v$VER" || true
    done
  done

  echo ""
  echo " Uninstall complete. To remove IoT/TES resources too:"
  echo "   aws cloudformation delete-stack --stack-name nx1-groot-${USER_ID}-gg --role-arn arn:aws:iam::${ACCOUNT_ID}:role/CloudFormationDeployer"
  echo ""
  exit 0
fi

echo "============================================"
echo " GR00T N1.6 Greengrass Workshop Setup (NX1)"
echo "============================================"
echo " Region:   $REGION"
echo " Account:  $ACCOUNT_ID"
echo " UserId:   $USER_ID"
echo " Thing:    $THING_NAME   (pre-created by CFN)"
echo " Group:    $THING_GROUP  (pre-created by CFN)"
echo " IoTPol:   $IOT_POLICY   (pre-created by CFN)"
echo " TESalias: $TES_ROLE_ALIAS (pre-created by CFN)"
echo " S3:       s3://${S3_BUCKET}/"
echo " ECR:      $ECR_IMAGE"
echo "============================================"
echo ""

# --- preflight: verify what THIS role can actually verify --------------------
# NOTE: the instance role (gg-provision policy) intentionally has only the WRITE
# actions needed to install (CreateKeysAndCertificate/AttachThingPrincipal/
# AttachPolicy/AddThingToThingGroup/DescribeEndpoint). It does NOT have iot:GetPolicy
# / iot:DescribeRoleAlias, and iot:DescribeThing additionally needs kms:Decrypt on
# the IoT Core CMK (not granted). So we do NOT probe those here - they would fail on
# permissions, not on resource absence. Resource existence was verified at deploy time
# (stack nx1-groot-<UserId>-gg). We only confirm the IoT endpoints resolve; if the
# Thing/policy/alias are actually missing, the install step below fails clearly.
echo ">>> [0/6] Preflight: resolving IoT endpoints (role-scoped checks only)"
DATA_EP_PRE=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --region "$REGION" --query endpointAddress --output text 2>&1) \
  && echo "   data endpoint: $DATA_EP_PRE" \
  || { echo "   ERROR: cannot resolve IoT data endpoint: $DATA_EP_PRE"; exit 1; }
echo "   (Thing/policy/TES existence was verified at CFN deploy time; install will fail clearly if absent.)"

# --- Step 1: prerequisites ---------------------------------------------------
echo ">>> [1/6] Prerequisites (java, unzip, jq)"
apt-get update -qq
apt-get install -y -qq default-jdk unzip curl jq 2>/dev/null

# --- Step 2: stage model into per-user S3 bucket -----------------------------
# Bucket is pre-created (day2-user). We stage the hi-space model once; the
# component (TES role) downloads it from S3 on the edge device.
echo ">>> [2/6] Model staging (hi-space -> s3://${S3_BUCKET}/workshop/)"
MODEL_KEY="workshop/GR00T-N1.6-3B-Pick-Orange.tar.gz"
DATASET_KEY="workshop/leisaac-pick-orange.tar.gz"
# hi-space CloudFront origin (one-time pull; requires egress through Cloud One)
HISPACE_CF="https://d3ru2qz80ictoo.cloudfront.net/workshop"

if aws s3 ls "s3://${S3_BUCKET}/${MODEL_KEY}" --region "$REGION" >/dev/null 2>&1; then
  echo "   Model already in S3, skipping"
else
  echo "   Downloading N1.6 model from hi-space CloudFront -> S3..."
  wget -q --show-progress -O /tmp/model.tar.gz "${HISPACE_CF}/GR00T-N1.6-3B-Pick-Orange.tar.gz"
  aws s3 cp /tmp/model.tar.gz "s3://${S3_BUCKET}/${MODEL_KEY}" --region "$REGION"
  rm -f /tmp/model.tar.gz
  echo "   Model uploaded"
fi

if aws s3 ls "s3://${S3_BUCKET}/${DATASET_KEY}" --region "$REGION" >/dev/null 2>&1; then
  echo "   Dataset already in S3, skipping"
else
  echo "   Downloading dataset from hi-space CloudFront -> S3..."
  wget -q --show-progress -O /tmp/dataset.tar.gz "${HISPACE_CF}/leisaac-pick-orange.tar.gz"
  aws s3 cp /tmp/dataset.tar.gz "s3://${S3_BUCKET}/${DATASET_KEY}" --region "$REGION"
  rm -f /tmp/dataset.tar.gz
  echo "   Dataset uploaded"
fi
aws s3 ls "s3://${S3_BUCKET}/workshop/" --region "$REGION" --human-readable 2>/dev/null || true

# --- Step 3: build + push edge inference image to SHARED ECR (per-user tag) ---
# ECR repo is pre-created (day2-shared EdgeInferenceRepo). We do NOT create it.
# Day1 role has ecr build/push to nx1/* (nx1-isaaclab-least-priv); the edge
# device pulls via the day3 TES role (scoped to nx1/groot-*).
echo ">>> [3/6] ECR build + push ($ECR_IMAGE)"
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

if aws ecr describe-images --repository-name "$ECR_REPO" --image-ids imageTag="$USER_ID" --region "$REGION" >/dev/null 2>&1; then
  echo "   Image already in ECR: $ECR_IMAGE (skipping build)"
else
  echo "   Building N1.6 Docker image (PyTorch + TRT 10.7)..."
  BUILD_DIR="/tmp/groot-n16-build"
  rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

  cat > "$BUILD_DIR/Dockerfile" << 'DKEOF'
# Base: pytorch:24.12-py3 - CUDA 12.4, Python 3.12, system TRT 10.7
FROM nvcr.io/nvidia/pytorch:24.12-py3
ENV DEBIAN_FRONTEND=noninteractive
ENV NVIDIA_DRIVER_CAPABILITIES=graphics,utility,compute

RUN apt-get update && apt-get install -y git git-lfs ffmpeg wget curl && rm -rf /var/lib/apt/lists/*
RUN pip install uv

# Upgrade torch + transformers (Qwen3 support required for N1.6)
RUN pip install --upgrade torch torchvision --index-url https://download.pytorch.org/whl/cu124
RUN pip install --upgrade transformers accelerate

# Isaac-GR00T N1.6 stable - uv sync handles all deps + dataclass compat
RUN git clone https://github.com/NVIDIA/Isaac-GR00T.git /workspace/gr00t-repo && \
    cd /workspace/gr00t-repo && \
    git checkout 5dc80c4afd726b34faad1d8f7e007a13b34e4c88 && \
    uv sync && uv pip install -e .

# ONNX export dependencies (must be after uv sync creates the venv)
RUN uv pip install --python /workspace/gr00t-repo/.venv/bin/python onnxscript onnx onnxruntime

ENV VIRTUAL_ENV="/workspace/gr00t-repo/.venv"
ENV PATH="/workspace/gr00t-repo/.venv/bin:${PATH}"
ENV PYTHONPATH="/workspace/gr00t-repo:/workspace"

# TRT fix: remove pip TRT 10.16 (CUDA error 35 bug), use system TRT 10.7
RUN VENV_SP="/workspace/gr00t-repo/.venv/lib/python3.12/site-packages" && \
    SYS_SP="/usr/local/lib/python3.12/dist-packages" && \
    rm -rf $VENV_SP/tensorrt $VENV_SP/tensorrt_libs $VENV_SP/tensorrt_bindings \
           $VENV_SP/tensorrt_cu12* $VENV_SP/tensorrt-* $VENV_SP/tensorrt_*.dist-info && \
    ln -sf $SYS_SP/tensorrt $VENV_SP/tensorrt && \
    [ -d $SYS_SP/tensorrt_libs ] && ln -sf $SYS_SP/tensorrt_libs $VENV_SP/tensorrt_libs; \
    [ -d $SYS_SP/tensorrt_bindings ] && ln -sf $SYS_SP/tensorrt_bindings $VENV_SP/tensorrt_bindings; \
    for f in $SYS_SP/tensorrt-10.7*.dist-info $SYS_SP/tensorrt_*10.7*.dist-info; do \
      [ -e "$f" ] && ln -sf "$f" "$VENV_SP/$(basename $f)"; \
    done; \
    python -c "import tensorrt as trt; print('TRT', trt.__version__)"

WORKDIR /workspace/gr00t-repo
ENV LD_LIBRARY_PATH="/usr/local/lib/python3.12/dist-packages/torch/lib:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:${LD_LIBRARY_PATH}"
ENTRYPOINT ["python", "-m", "gr00t.eval.run_gr00t_server"]
DKEOF

  # local tag kept as groot-n16-inference so recipes' docker-images grep still matches
  docker build -t "groot-n16-inference:latest" "$BUILD_DIR"
  docker tag "groot-n16-inference:latest" "$ECR_IMAGE"
  docker push "$ECR_IMAGE"
  rm -rf "$BUILD_DIR"
  echo "   Image pushed: $ECR_IMAGE"
fi

# --- Step 4: install Greengrass with --provision FALSE -----------------------
# Manual provisioning per AWS docs: create cert in IoT, attach to the pre-created
# Thing + IoT policy, write config.yaml referencing the pre-created TES role alias,
# then run the installer with --init-config (no AWS creds passed to installer for
# provisioning; --provision defaults to false).
if [ -f "$GG_ROOT/bin/greengrass-cli" ]; then
  echo ">>> [4/6] Greengrass already installed (skipping)"
else
  echo ">>> [4/6] Installing Greengrass (--provision false, manual resources)"

  CERT_DIR="${GG_ROOT}/certs"
  mkdir -p "$CERT_DIR"

  # Endpoints (from the pre-created account resources)
  DATA_EP=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --region "$REGION" --query endpointAddress --output text)
  CRED_EP=$(aws iot describe-endpoint --endpoint-type iot:CredentialProvider --region "$REGION" --query endpointAddress --output text)

  # Device certificate (instance role has iot:CreateKeysAndCertificate via day3 gg-provision)
  echo "   Creating device certificate..."
  CERT_ARN=$(aws iot create-keys-and-certificate --set-as-active --region "$REGION" \
    --certificate-pem-outfile "$CERT_DIR/device.pem.crt" \
    --public-key-outfile "$CERT_DIR/public.pem.key" \
    --private-key-outfile "$CERT_DIR/private.pem.key" \
    --query certificateArn --output text)
  echo "   Certificate: $CERT_ARN"

  # Root CA
  curl -s -o "$CERT_DIR/AmazonRootCA1.pem" https://www.amazontrust.com/repository/AmazonRootCA1.pem

  # Attach cert to the pre-created Thing + IoT policy, add Thing to the Group
  aws iot attach-thing-principal --thing-name "$THING_NAME" --principal "$CERT_ARN" --region "$REGION"
  aws iot attach-policy --policy-name "$IOT_POLICY" --target "$CERT_ARN" --region "$REGION"
  aws iot add-thing-to-thing-group --thing-name "$THING_NAME" --thing-group-name "$THING_GROUP" --region "$REGION" 2>/dev/null || true

  # Download Greengrass nucleus installer (AWS official CloudFront - not hi-space)
  echo "   Downloading Greengrass nucleus installer..."
  curl -s https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip -o /tmp/gg.zip
  unzip -qo /tmp/gg.zip -d /tmp/gg

  # config.yaml for manual provisioning (no iotRoleAlias creation - it pre-exists)
  cat > /tmp/gg/config.yaml << CFGEOF
---
system:
  certificateFilePath: "${CERT_DIR}/device.pem.crt"
  privateKeyPath: "${CERT_DIR}/private.pem.key"
  rootCaPath: "${CERT_DIR}/AmazonRootCA1.pem"
  rootpath: "${GG_ROOT}"
  thingName: "${THING_NAME}"
services:
  aws.greengrass.Nucleus:
    componentType: "NUCLEUS"
    version: "${NUCLEUS_VERSION}"
    configuration:
      awsRegion: "${REGION}"
      iotRoleAlias: "${TES_ROLE_ALIAS}"
      iotDataEndpoint: "${DATA_EP}"
      iotCredEndpoint: "${CRED_EP}"
CFGEOF

  sudo -E java -Droot="$GG_ROOT" -Dlog.store=FILE \
    -jar /tmp/gg/lib/Greengrass.jar \
    --init-config /tmp/gg/config.yaml \
    --component-default-user ggc_user:ggc_group \
    --setup-system-service true

  rm -rf /tmp/gg /tmp/gg.zip
  # Greengrass CLI is deployed below (cannot use --deploy-dev-tools without --provision true)
  echo "   Greengrass installed. Deploying Greengrass CLI component..."
  aws greengrassv2 create-deployment \
    --target-arn "arn:aws:iot:${REGION}:${ACCOUNT_ID}:thing/${THING_NAME}" \
    --deployment-name "nx1-${USER_ID}-cli" \
    --components "{\"aws.greengrass.Cli\":{\"componentVersion\":\"${NUCLEUS_VERSION}\"}}" \
    --region "$REGION" >/dev/null 2>&1 || true

  for i in $(seq 1 30); do
    [ -f "$GG_ROOT/bin/greengrass-cli" ] && break
    sleep 5
  done
  echo "   Greengrass install complete"
fi

# --- Step 5: register com.workshop.<UserId>.* components (NX1 ECR/S3) --------
echo ">>> [5/6] Registering components (N1.6, NX1)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENTS_DIR="${SCRIPT_DIR}/../workshop-components/N1.6"
[ -d "$COMPONENTS_DIR" ] || COMPONENTS_DIR="$(pwd)/workshop-components/N1.6"
if [ ! -d "$COMPONENTS_DIR" ]; then
  echo "   Syncing components from S3..."
  COMPONENTS_DIR="/tmp/workshop-components/N1.6"
  aws s3 sync "s3://${S3_BUCKET}/workshop-components/N1.6" "$COMPONENTS_DIR" --region "$REGION" 2>/dev/null || true
fi

# Recipes ship with explicit NX1 placeholders that this script substitutes:
#   ECR_IMAGE_PLACEHOLDER -> <acct>.dkr.ecr.<region>.amazonaws.com/nx1/groot-edge-inference:<userId>
#   ECR_REPO_PLACEHOLDER  -> <acct>.dkr.ecr.<region>.amazonaws.com/nx1/groot-edge-inference
#   IMAGE_TAG_PLACEHOLDER -> <userId>
#   S3_BUCKET_PLACEHOLDER -> nx1-groot-<userId>-<acct>
#   DATASET_URL_PLACEHOLDER -> s3://<bucket>/workshop/leisaac-pick-orange.tar.gz
# A defensive rewrite also catches any legacy hi-space hardcoded ECR, so the same
# script works whether recipes are NX1-templated or still carry legacy values.
NEW_ECR_IMAGE="$ECR_IMAGE"
NEW_ECR_REPO="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
LEGACY_ECR_IMG_RE="[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/groot-n16-inference-[a-z0-9-]+:latest"
LEGACY_ECR_REPO_RE="[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/groot-n16-inference-[a-z0-9-]+"

for RECIPE in "$COMPONENTS_DIR"/com.workshop.*/recipe.yaml; do
  [ -f "$RECIPE" ] || continue
  COMP_VER=$(grep 'ComponentVersion:' "$RECIPE" | awk -F'"' '{print $2}')
  TEMP_RECIPE="/tmp/recipe-$(basename "$(dirname "$RECIPE")").yaml"

  # 1) explicit NX1 placeholders (order: full image, repo, tag)
  sed "s|ECR_IMAGE_PLACEHOLDER|${NEW_ECR_IMAGE}|g" "$RECIPE" > "$TEMP_RECIPE"
  sed -i "s|ECR_REPO_PLACEHOLDER|${NEW_ECR_REPO}|g" "$TEMP_RECIPE"
  sed -i "s|IMAGE_TAG_PLACEHOLDER|${USER_ID}|g" "$TEMP_RECIPE"
  # 2) defensive: legacy hi-space ECR (full image with :latest, then bare repo)
  sed -i -E "s|${LEGACY_ECR_IMG_RE}|${NEW_ECR_IMAGE}|g" "$TEMP_RECIPE"
  sed -i -E "s|${LEGACY_ECR_REPO_RE}|${NEW_ECR_REPO}|g" "$TEMP_RECIPE"
  # 3) S3 bucket placeholder -> per-user day2 bucket
  sed -i "s|S3_BUCKET_PLACEHOLDER|${S3_BUCKET}|g" "$TEMP_RECIPE"
  # 4) dataset URL placeholder / legacy CloudFront -> per-user day2 S3 (staged in Step 2)
  sed -i "s|DATASET_URL_PLACEHOLDER|s3://${S3_BUCKET}/${DATASET_KEY}|g" "$TEMP_RECIPE"
  sed -i "s|https://d3ru2qz80ictoo.cloudfront.net/workshop/leisaac-pick-orange.tar.gz|s3://${S3_BUCKET}/${DATASET_KEY}|g" "$TEMP_RECIPE"
  # 5) component names -> per-user namespace (avoid cross-participant collisions)
  sed -i "s|ComponentName: com.workshop\.|ComponentName: com.workshop.${USER_ID}.|g" "$TEMP_RECIPE"
  sed -i "s|com.workshop.docker-build|com.workshop.${USER_ID}.docker-build|g" "$TEMP_RECIPE"
  sed -i "s|com.workshop.setup|com.workshop.${USER_ID}.setup|g" "$TEMP_RECIPE"
  sed -i "s|com.workshop.inference|com.workshop.${USER_ID}.inference|g" "$TEMP_RECIPE"
  sed -i "s|com.workshop.benchmark|com.workshop.${USER_ID}.benchmark|g" "$TEMP_RECIPE"

  COMP_NAME_FINAL=$(grep 'ComponentName:' "$TEMP_RECIPE" | awk '{print $2}')
  echo "   Registering: $COMP_NAME_FINAL v$COMP_VER"
  aws greengrassv2 create-component-version \
    --inline-recipe "fileb://$TEMP_RECIPE" \
    --region "$REGION" >/dev/null 2>&1 && echo "     OK" || echo "     Already exists / skipped"
  rm -f "$TEMP_RECIPE"
done

# --- Step 6: print deployment commands ---------------------------------------
echo ">>> [6/6] Done. Deploy components with:"
echo ""
echo " [1/3] Environment prep (Docker pull + model + TRT build):"
echo "   aws greengrassv2 create-deployment \\"
echo "     --target-arn arn:aws:iot:${REGION}:${ACCOUNT_ID}:thinggroup/${THING_GROUP} \\"
echo "     --deployment-name \"nx1-${USER_ID}-setup\" \\"
echo "     --components '{\"aws.greengrass.Nucleus\":{\"componentVersion\":\"${NUCLEUS_VERSION}\"},\"aws.greengrass.Cli\":{\"componentVersion\":\"${NUCLEUS_VERSION}\"},\"com.workshop.${USER_ID}.docker-build\":{\"componentVersion\":\"1.0.0\"},\"com.workshop.${USER_ID}.setup\":{\"componentVersion\":\"1.0.0\"}}' \\"
echo "     --region $REGION"
echo ""
echo " [2/3] Benchmark (PyTorch vs TRT):"
echo "   ... add com.workshop.${USER_ID}.benchmark to the components map"
echo ""
echo " [3/3] Inference server (Policy Server :5555):"
echo "   ... add com.workshop.${USER_ID}.inference to the components map"
echo ""
echo " Expected benchmark (L40S): PyTorch ~126ms/7.9Hz | TRT ~60ms/16.6Hz (2.1x)"
echo "============================================"
echo " NX1 Setup Complete!"
echo "============================================"
