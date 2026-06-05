---
created: 2026-02-20
updated: 2026-02-20
tags:
  - physical-ai
  - k-paiig
  - gpu
  - capacity
---

# GPU Capacity 확인 가이드

Physical AI 데모 구축 시 필요한 GPU 인스턴스 가용량 확인 방법 정리.

> [!warning] 내부 전용
> 이 문서의 모든 정보는 내부용이며, 고객에게 공유하면 안 됩니다.

---

## 주요 도구

### 1. EC2 Baywatch (범용)

**URL**: https://ec2-baywatch-prod-iad.iad.proxy.amazon.com

| 페이지 | 경로 | 용도 |
|--------|------|------|
| Pool Viewer | `/pages/poolViewer` | 리전/AZ별 인스턴스 가용 수량 확인 |
| Instance Configuration | `/pages/instanceConfiguration` | 리전별 인스턴스 타입 GA 여부 확인 |
| Account Info | `/pages/accountInfo` | 고객 계정의 AZ 매핑 및 쿼터 확인 |
| Limit Increase | `/pages/limitIncrease/request` | vCPU 한도 증가 요청 |

> [!caution] Baywatch 부정확 인스턴스
> 아래 인스턴스는 Baywatch 정보가 부정확하므로 별도 도구 사용 필요:
> `trn2p`, `trn2u`, `trn2`, `trn2n`, `p5`, `p5e`, `p5en`, `p6-gb`, `p6e-gb200`, `p6-b200`, `p6-b300`

### 2. GPU Availability Check (대형 GPU용)

**URL**: https://gpu-availability.emea-genai.startups.aws.dev/gpu-availability/

Baywatch가 부정확한 P5/P6/Trn2 등 대형 GPU 인스턴스의 리전별 가용량 확인.

### 3. Capacity Finder (CB/FTP)

**URL**: https://capacity-finder.emea-genai.startups.aws.dev/capacity-finder/

Capacity Blocks 또는 SageMaker Flexible Training Plans 검색.

### 4. EC2 Spot GPU Capacity

**URL**: https://w.amazon.com/bin/view/Users/hyangelo/EC2SpotGPUCapacity/

Spot으로 사용 가능한 GPU 인스턴스 확인.

---

## Capacity 부족 시 대응 팁

- 모든 **Availability Zone** 활용
- **멀티 리전** 배포 고려
- **다른 인스턴스 타입/사이즈** 탐색 (예: G5 ↔ G4dn 혼합)
- 구매 옵션 유연성 확보: Reserved / Capacity Blocks / On-Demand / Spot
- **서비스 한도(쿼터)** 사전 설정 확인

---

## Capacity 에스컬레이션 프로세스

대규모 GPU 요청 또는 긴급 요청 시:

1. [Capacity Escalation Approvals](https://w.amazon.com/bin/view/AWS/Teams/Core_Services/EC2_Capacity_Escalation_Approvals/#H2.Threestepstosubmitacapacityrequest) — 3단계 요청 프로세스
2. [Accelerated Compute Resources Wiki](https://w.amazon.com/bin/view/AWS/Teams/StartupSA/GPUResources/)
3. [SageMaker Capacity Management](https://w.amazon.com/bin/view/AWS/AmazonAI/Platform/SageMaker/CapacityManagement/)

에스컬레이션 시 필요 정보:
- **긴급 사유**: 왜 이 요청이 긴급한가?
- **정당성**: PPA 딜 규모, 경쟁 상황 등
- **데드라인**: 언제까지 승인이 필요한가?

---

## K-PAIIG 데모 관련 인스턴스

| 용도 | 인스턴스 타입 | 확인 도구 |
|------|-------------|----------|
| Isaac Sim GUI (DCV 접속) | G7e (RTX PRO 6000 Blackwell) | Baywatch |
| GR00T 학습/파인튜닝 | P5 (H100) | GPU Availability Check |
| AWS Batch 분산 학습 | P5 / G7e | GPU Availability Check |
| 추론 (Inference) | G7e / Inf2 | Baywatch |

---

## 참고 Wiki

- [GPU Capacity Playbook (LATAM)](https://w.amazon.com/bin/view/SUP-WWSO-LATAM/GPUEscalation/)
- [GPU Capacity Playbook (EMEA)](https://w.amazon.com/bin/view/SUP-WWSO-EMEA/GPUEscalation/)
- [EMEA Accelerated Compute](https://w.amazon.com/bin/view/WWSO_EMEA/EMEA_Accelerated_Compute)
