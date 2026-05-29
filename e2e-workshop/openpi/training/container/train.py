#!/usr/bin/env python3
"""π0.5 SageMaker 학습 엔트리포인트 (DRAFT v0.1 — Spike A에서 검증).

GR00T `e2e-workshop/groot/training/container/train.py`의 SM_HP_* 파싱 패턴을 차용.
openpi는 hydra-style config 이름(`pi05_libero`, `pi05_droid_finetune` 등)을 받아
`scripts/train.py <config_name> --exp-name=... --overwrite` 형태로 실행.

본 wrapper의 책임:
  1. SageMaker 환경변수(SM_HP_*, SM_CHANNEL_*, SM_MODEL_DIR)를 openpi CLI 인자로 매핑
  2. wandb 강제 init을 비활성화 (`WANDB_DISABLED=true`) + MLflow는 별도 polling으로 추가
     [TODO Spike A: scripts/train.py 메인 루프에 mlflow.log_metric 직접 삽입할지,
                   wandb→mlflow 어댑터 작성할지 결정]
  3. 학습 종료 후 checkpoint를 SM_MODEL_DIR로 복사 (HF Trainer가 자동 처리하던 부분)
  4. (선택) GCS pi05_base를 사전 다운로드 — Spike B 결과 GCS egress PASS이므로
     openpi의 weight_loader가 직접 gs://에서 pull 가능. 다만 Cloud One 경유 첫 회 지연
     관찰을 위해 명시 prefetch 옵션도 둠.

⚠️ 미해결 항목 (Spike A에서 답):
  - openpi의 `scripts/compute_norm_stats.py`를 학습 전에 자동 호출할지 (custom dataset 한정)
  - LIBERO smoke test 시 SM_CHANNEL_DATASET 없이 HF에서 직접 받을 수 있는지
  - LoRA freeze_filter는 config 안에 박혀 있는데, 9ch action_dim 변경 시 weight_loader가
    shape mismatch를 어떻게 처리하는지 (random init 자동인지 명시 필요인지)
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

OPENPI_ROOT = Path("/opt/openpi")


def _hp(key: str, default: str = "") -> str:
    """SageMaker hyperparameter — env(`SM_HP_*`) → hyperparameters.json 폴백."""
    for env_key in (f"SM_HP_{key.upper()}", f"SM_HP_{key}"):
        v = os.environ.get(env_key)
        if v is not None:
            return v
    hp = Path("/opt/ml/input/config/hyperparameters.json")
    if hp.exists():
        try:
            return str(json.loads(hp.read_text()).get(key, default))
        except (json.JSONDecodeError, OSError):
            pass
    return default


def _disable_wandb() -> None:
    # openpi train.py는 wandb.init을 강제 호출 — workshop은 MLflow로 통일
    os.environ["WANDB_DISABLED"] = "true"
    os.environ["WANDB_MODE"] = "disabled"


def _resolve_paths() -> dict:
    return {
        "config_name": _hp("openpi_config", os.environ.get("OPENPI_CONFIG", "pi05_droid_finetune")),
        "exp_name": _hp("exp_name", "sm-spike"),
        "dataset_dir": os.environ.get("SM_CHANNEL_DATASET", "/opt/ml/input/data/dataset"),
        "model_dir": os.environ.get("SM_MODEL_DIR", "/opt/ml/model"),
        "num_train_steps": _hp("num_train_steps", "200"),  # smoke 기본
        "batch_size": _hp("batch_size", ""),               # 비우면 config 기본
        "overwrite": _hp("overwrite", "true").lower() == "true",
    }


def _run_training(p: dict) -> int:
    cmd = [
        "/.venv/bin/uv", "run", "scripts/train.py",
        p["config_name"],
        "--exp-name", p["exp_name"],
    ]
    if p["overwrite"]:
        cmd.append("--overwrite")
    if p["batch_size"]:
        cmd.extend(["--batch-size", p["batch_size"]])
    # num_train_steps는 config override가 가능한지 확인 필요(Spike A)
    # 현재는 .env 또는 config dataclass 직접 수정 필요할 수 있음

    env = os.environ.copy()
    env["XLA_PYTHON_CLIENT_MEM_FRACTION"] = env.get("XLA_PYTHON_CLIENT_MEM_FRACTION", "0.9")
    print(f"[train.py] launching: {' '.join(cmd)}", flush=True)
    return subprocess.call(cmd, cwd=str(OPENPI_ROOT), env=env)


def _copy_artifacts(p: dict) -> None:
    """openpi checkpoint dir → SM_MODEL_DIR. checkpoint layout 확인 필요(Spike A)."""
    # openpi 기본 checkpoint_dir = config.checkpoint_dir → 일반적으로 ./checkpoints/<exp_name>
    src = OPENPI_ROOT / "checkpoints" / p["exp_name"]
    if not src.exists():
        print(f"[train.py] WARN: checkpoint dir not found: {src}", flush=True)
        return
    dst = Path(p["model_dir"]) / "checkpoint"
    dst.mkdir(parents=True, exist_ok=True)
    # 추론에 불필요한 optimizer state 등은 후속에 필터링 — Spike A 결과로 결정
    for entry in src.iterdir():
        if entry.is_dir():
            shutil.copytree(entry, dst / entry.name, dirs_exist_ok=True)
        else:
            shutil.copy2(entry, dst / entry.name)
    print(f"[train.py] copied artifacts → {dst}", flush=True)


def main() -> int:
    print("=" * 60)
    print("π0.5 SageMaker training (Spike A draft)")
    print("=" * 60)
    _disable_wandb()
    p = _resolve_paths()
    print(f"config={p['config_name']}  exp={p['exp_name']}  steps={p['num_train_steps']}", flush=True)
    rc = _run_training(p)
    if rc != 0:
        print(f"[train.py] training failed rc={rc}", file=sys.stderr, flush=True)
        return rc
    _copy_artifacts(p)
    print("[train.py] done.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
