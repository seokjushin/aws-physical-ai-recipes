# `e2e-workshop/openpi/` — π0.5 학습 파이프라인 (DRAFT, Spike 단계)

> **상태**: 2026-05-29 Spike Plan v0.2 §1 Spike A 사전 작업의 Dockerfile + train.py wrapper 초안.
> 빌드·학습 모두 미검증. Spike A(6/2~6/4 예정) 끝나기 전에는 워크샵 자료로 사용 금지.

## 왜 별도 디렉토리인가

워크샵 본 모듈(`e2e-workshop/groot/`)은 NVIDIA GR00T-N1.6 PyTorch 파이프라인이고, MEX
PoC 본 작업의 모델은 Physical Intelligence π0.5(JAX). NX1 인프라(`infra/nx1/*.yaml`)는
model-agnostic이라 그대로 재사용하고, 모델 종속 코드(컨테이너·학습·추론)만 이 폴더에
신설한다.

워크샵 v1(5/29)은 GR00T 그대로 진행. π0.5 도입 일정·범위는 spike 결과 후 결정 메모
v1.0에서 확정.

## 현 디렉토리 구조

```
openpi/
├── README.md                     # 이 파일
├── configs/                      # 워크샵용 ECR repo 이름·MLflow URI 등 (TODO)
└── training/
    ├── container/
    │   ├── Dockerfile            # nvidia/cuda:12.2.2 + uv + openpi clone (DRAFT)
    │   └── train.py              # SageMaker SM_HP_* → openpi CLI wrapper (DRAFT)
    └── data/                     # mcap → LeRobot 변환 (TODO Spike A 후)
```

## openpi 사실 요약 (2026-05-29 fetch)

- **JAX LoRA = first-class config** (`src/openpi/training/config.py`):
  - `pi0_libero_low_mem_finetune` 가 reference: `paligemma_variant="gemma_2b_lora"` +
    `action_expert_variant="gemma_300m_lora"` + `freeze_filter=...get_freeze_filter()`.
  - pi05 LoRA 명시 config는 **현재 없음** — pi05+LoRA 조합은 Spike A에서 직접 검증.
- **`pi05_droid_finetune`** = "10시간 미만 custom DROID 데이터" fine-tune 공식 reference.
  `num_train_steps=20_000`, `batch_size=32`. PI 자신의 권장 학습량.
- **action_dim·action_horizon 변경** = `Pi0Config(pi05=True, action_dim=N, action_horizon=M)`
  config 한 줄. 9ch도 같은 패턴 가능할 것으로 추정 — Spike A에서 확인.
- **Norm stats** = `assets_dir`로 base checkpoint의 stats를 *재사용 권장*
  ("Important: reuse the original DROID norm stats during fine-tuning!").
- **GCS egress** = NX1에서 직접 다운로드 PASS (Spike B 2026-05-29 PASS, 5분 probe).
- **Official Docker** = `scripts/docker/serve_policy.Dockerfile` (추론용). **학습용은 부재**
  → 본 디렉토리 Dockerfile이 필요.

## Spike A 진행 시 검증할 가설

- [ ] G1: nvidia/cuda:12.2.2 base + JAX[cuda12] + openpi `uv sync` 가 단일 L40S(g6e.4xlarge)에
      문제 없이 빌드.
- [ ] G2: `uv run scripts/train.py pi05_libero --exp-name=spike --overwrite` 가 200 step
      동안 OOM 없이 진행. peak GPU memory 측정.
- [ ] G3: `pi0_libero_low_mem_finetune` LoRA recipe를 pi05_base + pi0_libero data로 변형해
      `pi05_libero_low_mem_finetune` 같은 신규 TrainConfig로 동작. peak memory가 LoRA의
      README 22.5GB 가정에 부합.
- [ ] G4: checkpoint가 `convert_jax_model_to_pytorch.py`로 정상 변환.
- [ ] G5: action_dim 9 + action_horizon 50 으로 설정 시 weight_loader가 shape mismatch를
      random-init로 수용하는지(또는 명시적 reset 필요한지).
- [ ] G6: wandb 비활성 + MLflow callback 수동 instrumentation 옵션 vs scripts/train.py
      메인 루프 직접 수정 vs 외부 logger 비교.

## 빌드 (Spike A 시점에만 — 지금 실행 X)

```bash
# Isengard 환경 (GPU 가진 EC2 또는 SageMaker Notebook)
docker build -t openpi-sm-training:0.1 \
  -f e2e-workshop/openpi/training/container/Dockerfile .
```

## SageMaker 호출 예 (Spike A — 미검증)

```python
from sagemaker.estimator import Estimator
est = Estimator(
    image_uri="<ecr>/openpi-sm-training:0.1",
    role="<arn>",
    instance_type="ml.g6e.4xlarge",   # L40S 48GB — LoRA 검증
    instance_count=1,
    use_spot_instances=False,         # Spot은 Spike 후 결정 (interruption + JAX checkpoint)
    hyperparameters={
        "openpi_config": "pi05_libero",   # Spike G2: 일단 full pi05 그대로
        "exp_name": "spike-a-pi05-libero",
        "num_train_steps": "200",
    },
    environment={"OPENPI_CONFIG": "pi05_libero"},
)
est.fit({"dataset": "s3://nx1-.../libero/"})
```

## 알려진 미해결

- `e2e-workshop/openpi/training/data/` 비어있음 (mcap → LeRobot 변환은 Spike A 후, MEX
  본 작업 데이터 들어올 때).
- 추론 컨테이너(`inference/`) 없음. JAX serve_policy → SageMaker Endpoint 또는 JAX→PyTorch
  변환 후 PyTorch endpoint, 둘 중 어느 쪽으로 갈지는 Spike A 결과 G4·G6에 의존.
- Edge(`edge/workshop-components/pi05/`)는 Feasibility Gate 1(TRT FP8/NVFP4 on Thor) 후.
