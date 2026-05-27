#!/bin/bash
# =============================================================================
# nx1-idle-autostop-install.sh  (NX1 전용 신규 — Spec A.5 idle 자가 auto-stop)
# =============================================================================
# 5분 주기 systemd timer가 idle 판정. idle = 아래 4개가 연속 IDLE_MINUTES(기본 120)분:
#   - DCV 세션 없음        (dcv list-sessions 비었거나 :8443 ESTAB 없음)
#   - SSM 세션 없음        (ssm-session-worker 프로세스 없음)
#   - GPU 유휴             (utilization.gpu < 5%)
#   - (보조) CPU load<0.2
# 충족 시 자기 인스턴스 stop-instances. 멤버는 재시작 불가 → runbook "한 번에 완료" 경고.
# IAM: 인스턴스 역할에 ec2:StopInstances (자기 스택 인스턴스 한정) 필요 — Day1 template A.3.
# =============================================================================
echo "===== [$(date)] START: nx1-idle-autostop-install.sh ====="

IDLE_MINUTES="${IDLE_MINUTES:-120}"
CHECK_INTERVAL_MIN=5
NEEDED_STREAK=$(( IDLE_MINUTES / CHECK_INTERVAL_MIN ))   # 연속 idle 카운트 임계 (기본 24)

# --- idle 판정 스크립트 ---
cat > /usr/local/bin/nx1-idle-check.sh <<EOF
#!/bin/bash
STATE=/var/run/nx1-idle-streak
NEEDED=${NEEDED_STREAK}
REGION="\$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)"
TOKEN="\$(curl -sf -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' 2>/dev/null)"
IID="\$(curl -sf -H "X-aws-ec2-metadata-token: \$TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)"

is_busy() {
  # DCV 세션
  if command -v dcv >/dev/null 2>&1; then
    dcv list-sessions 2>/dev/null | grep -q "Session:" && return 0
  fi
  ss -tn 2>/dev/null | grep -qE ':(8443|8888) .*ESTAB' && return 0   # DCV(8443) 또는 code-server(8888) 연결 중
  # SSM 세션
  pgrep -f ssm-session-worker >/dev/null 2>&1 && return 0
  # GPU 사용률 >= 5%
  if command -v nvidia-smi >/dev/null 2>&1; then
    U=\$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | sort -rn | head -1)
    [ -n "\$U" ] && [ "\$U" -ge 5 ] 2>/dev/null && return 0
  fi
  # CPU load (보조)
  L=\$(awk '{print \$1}' /proc/loadavg)
  awk "BEGIN{exit !(\$L > 0.2)}" && return 0
  return 1
}

if is_busy; then
  echo 0 > "\$STATE"
  exit 0
fi
N=\$(cat "\$STATE" 2>/dev/null || echo 0); N=\$((N+1)); echo \$N > "\$STATE"
echo "[nx1-idle] idle streak \$N/\$NEEDED"
if [ "\$N" -ge "\$NEEDED" ]; then
  echo "[nx1-idle] idle threshold reached -> stopping \$IID"
  aws ec2 stop-instances --instance-ids "\$IID" --region "\$REGION"
fi
EOF
chmod +x /usr/local/bin/nx1-idle-check.sh

# --- systemd service + timer (5분 주기) ---
cat > /etc/systemd/system/nx1-idle-check.service <<'EOF'
[Unit]
Description=NX1 idle auto-stop check
[Service]
Type=oneshot
ExecStart=/usr/local/bin/nx1-idle-check.sh
EOF

cat > /etc/systemd/system/nx1-idle-check.timer <<'EOF'
[Unit]
Description=NX1 idle auto-stop check timer (every 5 min)
[Timer]
OnBootSec=10min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF

echo 0 > /var/run/nx1-idle-streak
systemctl daemon-reload || true
systemctl enable --now nx1-idle-check.timer || true

echo "===== [$(date)] END: nx1-idle-autostop-install.sh (IDLE_MINUTES=${IDLE_MINUTES}) ====="
