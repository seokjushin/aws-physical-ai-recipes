# =============================================================================
# π0.5 SageMaker 학습 컨테이너 (DRAFT v0.1 — 빌드 미검증, Spike A에서 검증)
# =============================================================================
# Base: nvidia/cuda:12.2.2-cudnn8 (openpi serve_policy.Dockerfile과 동일 base)
# 포함: Python 3.11.9, uv, JAX[cuda12], openpi clone (LFS skip)
# 엔트리포인트: train.py (SageMaker 학습 엔트리포인트, GR00T 컨테이너 패턴 차용)
#
# ⚠️ 미검증 항목 (Spike A에서 채워야 함):
#   - JAX[cuda12] vs CUDA 12.2 호환성 (jaxlib wheel 매트릭스)
#   - LeRobot LFS skip 했을 때 학습 데이터 로딩 영향
#   - flash-attn 같은 대용량 휠 빌드 — JAX는 native 의존이므로 GR00T 대비 더 단순할 가능성
#   - SageMaker 학습 entry는 sagemaker-training toolkit 통해 train.py를 직접 부르는데,
#     openpi의 hydra-style config (`uv run scripts/train.py pi05_libero --exp-name=...`)와
#     호환시키려면 wrapper가 필요 (아래 train.py 참조)
# =============================================================================

FROM nvidia/cuda:12.2.2-cudnn8-runtime-ubuntu22.04@sha256:2d913b09e6be8387e1a10976933642c73c840c0b735f0bf3c28d97fc9bc422e0

ARG OPENPI_REF=main
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/.venv \
    GIT_LFS_SKIP_SMUDGE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    git git-lfs ca-certificates curl build-essential clang \
    linux-headers-generic ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# uv (openpi pyproject가 uv lockfile 사용)
COPY --from=ghcr.io/astral-sh/uv:0.5.1 /uv /uvx /bin/

# openpi clone (학습 코드 + scripts/train.py + configs)
WORKDIR /opt
RUN git clone https://github.com/Physical-Intelligence/openpi.git openpi \
    && cd openpi && git checkout ${OPENPI_REF} && git submodule update --init --recursive

WORKDIR /opt/openpi
RUN uv venv --python 3.11.9 ${UV_PROJECT_ENVIRONMENT} \
    && uv sync --frozen --no-install-project --no-dev

# transformers_replace 패치 (PyTorch 추론 호환성용 — 학습엔 미사용일 수 있음)
RUN cp -r src/openpi/models_pytorch/transformers_replace /tmp/ \
    && /.venv/bin/python -c "import transformers; print(transformers.__file__)" \
       | xargs dirname | xargs -I{} cp -r /tmp/transformers_replace/. {} \
    && rm -rf /tmp/transformers_replace

# SageMaker training toolkit (HF Trainer-shaped script-mode 진입을 위해)
RUN /.venv/bin/pip install --no-cache-dir sagemaker-training mlflow sagemaker-mlflow

# SageMaker 디렉토리 + entrypoint
RUN mkdir -p /opt/ml/code /opt/ml/model /opt/ml/input/data /opt/ml/output

ENV PYTHONPATH="/opt/openpi/src:/opt/ml/code"
WORKDIR /opt/ml/code

# Default openpi config name (overridable by SM_HP_OPENPI_CONFIG at runtime)
ENV OPENPI_CONFIG=pi05_droid_finetune
