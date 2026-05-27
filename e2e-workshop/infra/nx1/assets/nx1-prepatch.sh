#!/bin/bash
# =============================================================================
# nx1-prepatch.sh  (NX1 전용, 레포 업스트림에는 없는 신규 스크립트 — Spec A.4 M1 패치)
# =============================================================================
# common.sh보다 먼저 source 되어 apt lock / unattended-upgrades / rosdep 충돌을
# 선제 차단한다. 2026-05-13 Day1 UserData 5회 실패(공통 원인 = apt lock 경합)의 픽스.
# set -e 환경에서도 죽지 않도록 모든 줄을 || true 로 방어.
# =============================================================================
echo "===== [$(date)] START: nx1-prepatch.sh (NX1 M1 patch) ====="

# ⓪ [NX1 핵심] IPv4 우선 강제 — NX1 VPC는 IPv6 enabled이나 공유 NAT는 IPv4 전용이라
#    IPv6 egress가 black-hole. dual-stack 클라가 AAAA(IPv6)를 먼저 시도하다 connection-timeout
#    후에야 IPv4로 폴백 → 호스트마다 수 분 지연(40분 빌드를 90분+로). 모든 다운로드 前에 차단.
#    (근거: 2026-05-25 계측 빌드 buildlog — raw.githubusercontent IPv6 connection timed out.)
echo "[nx1] forcing IPv4 preference (NAT is IPv4-only; IPv6 egress black-holed)"
# getaddrinfo가 IPv4(::ffff:0:0/96)를 IPv6보다 우선 반환하도록 (wget/curl/pip/python 모두 영향)
printf 'precedence ::ffff:0:0/96  100\n' > /etc/gai.conf
# apt는 명시적으로 IPv4 강제
printf 'Acquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99-nx1-force-ipv4
# 확실히: 커널 IPv6 egress 비활성 (SSM은 IPv4 NAT로 동작 확인됨 → 안전)
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
cat > /etc/sysctl.d/99-nx1-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

# ① dpkg/apt lock 타임아웃: lock 잡혀 있으면 즉시 죽지 말고 600s 대기
cat > /etc/apt/apt.conf.d/99-nx1-lock-timeout <<'EOF'
DPkg::Lock::Timeout "600";
Acquire::Retries "5";
EOF

# ② 부팅 직후 자동 apt 작업 정지+비활성+mask (lock 경합 근절)
systemctl stop    apt-daily.timer apt-daily-upgrade.timer unattended-upgrades 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer unattended-upgrades 2>/dev/null || true
systemctl mask    apt-daily.timer apt-daily-upgrade.timer unattended-upgrades 2>/dev/null || true
systemctl kill --kill-who=all apt-daily.service 2>/dev/null || true
# 진행 중인 unattended-upgrade가 lock을 놓을 때까지 짧게 대기
for i in $(seq 1 60); do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || { echo "dpkg lock free ($i)"; break; }
  echo "waiting dpkg lock release ($i/60)"; sleep 5
done

# ③ rosdep 모듈 충돌 선제거: common.sh의 python3-rosdep2 / pip rosdep 설치가
#    기존 catkin/rospkg/rosdistro modules 와 충돌해 실패하는 것을 방지
apt-get remove -y python3-catkin-pkg-modules python3-rospkg-modules python3-rosdistro-modules 2>/dev/null || true

echo "===== [$(date)] END: nx1-prepatch.sh ====="
