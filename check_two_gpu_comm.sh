#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./check_two_gpu_comm.sh [container_name]
# Default container name matches docker-backend.sh
CONTAINER_NAME="${1:-llm-serving}"
MASTER_PORT="${MASTER_PORT:-29617}"
STEP5_TIMEOUT_SEC="${STEP5_TIMEOUT_SEC:-120}"

STEP1_STATUS="FAIL"
STEP2_STATUS="FAIL"
STEP3_STATUS="FAIL"
STEP4_STATUS="FAIL"
STEP5_STATUS="FAIL"

STEP1_MSG="not run"
STEP2_MSG="not run"
STEP3_MSG="not run"
STEP4_MSG="not run"
STEP5_MSG="not run"

STEP3_NOTE="(Note: On consumer Intel Core platforms, direct P2P is typically unsupported.)"

print_summary() {
  echo
  echo "================ Two-GPU Communication Summary ================"
  printf "%-6s %-6s %s\n" "Step" "Result" "Details"
  printf "%-6s %-6s %s\n" "1" "$STEP1_STATUS" "$STEP1_MSG"
  printf "%-6s %-6s %s\n" "2" "$STEP2_STATUS" "$STEP2_MSG"
  printf "%-6s %-6s %s %s\n" "3" "$STEP3_STATUS" "$STEP3_MSG" "$STEP3_NOTE"
  printf "%-6s %-6s %s\n" "4" "$STEP4_STATUS" "$STEP4_MSG"
  printf "%-6s %-6s %s\n" "5" "$STEP5_STATUS" "$STEP5_MSG"

  # Required checks for practical serving communication health.
  if [[ "$STEP1_STATUS" == "PASS" && "$STEP2_STATUS" == "PASS" && "$STEP4_STATUS" == "PASS" && "$STEP5_STATUS" == "PASS" ]]; then
    echo "Overall: PASS"
    return 0
  else
    echo "Overall: FAIL"
    return 1
  fi
}

echo "[1/5] Host GPU discovery"
if xpu-smi discovery; then
  STEP1_STATUS="PASS"
  STEP1_MSG="xpu-smi discovery succeeded"
else
  STEP1_STATUS="FAIL"
  STEP1_MSG="xpu-smi discovery failed"
fi

echo
echo "[2/5] Host GPU topology matrix (expect NODE/XL, not necessarily P2P)"
if xpu-smi topology -m; then
  STEP2_STATUS="PASS"
  STEP2_MSG="xpu-smi topology -m succeeded"
else
  STEP2_STATUS="FAIL"
  STEP2_MSG="xpu-smi topology -m failed"
fi

echo
echo "[3/5] Low-level P2P test tool check"
if command -v ze_peer >/dev/null 2>&1; then
  echo "ze_peer found: $(command -v ze_peer)"
  echo "Running: ze_peer -t transfer_bw -o write --parallel_pair_targets 0:1"
  set +e
  ze_peer -t transfer_bw -o write --parallel_pair_targets 0:1
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "ze_peer failed (rc=$rc). This means direct L0 P2P path is unavailable on this platform/driver."
    echo "It does NOT always mean tensor-parallel collective communication is unusable."
    STEP3_STATUS="FAIL"
    STEP3_MSG="ze_peer failed (rc=$rc), direct P2P unavailable"
  else
    STEP3_STATUS="PASS"
    STEP3_MSG="ze_peer transfer_bw passed"
  fi
else
  echo "ze_peer not found on host"
  STEP3_STATUS="FAIL"
  STEP3_MSG="ze_peer not found"
fi

echo
echo "[4/5] Check container and XPU visibility"
if ! sudo docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container $CONTAINER_NAME is not running"
  STEP4_STATUS="FAIL"
  STEP4_MSG="container not running"
else
  set +e
  sudo docker exec "$CONTAINER_NAME" bash -lc 'python3 - <<"PY"
import torch
print("torch", torch.__version__)
print("xpu_available", torch.xpu.is_available())
print("xpu_count", torch.xpu.device_count())
if not torch.xpu.is_available() or torch.xpu.device_count() < 2:
    raise SystemExit("Need 2 visible XPUs in container")
PY'
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    STEP4_STATUS="PASS"
    STEP4_MSG="container sees at least 2 XPUs"
  else
    STEP4_STATUS="FAIL"
    STEP4_MSG="container XPU visibility check failed"
  fi
fi

echo
echo "[5/5] Container distributed collective test (xccl all_reduce)"
if [[ "$STEP4_STATUS" != "PASS" ]]; then
  echo "Skipping step 5 because step 4 failed"
  STEP5_STATUS="FAIL"
  STEP5_MSG="skipped due to step 4 failure"
else
  set +e
  sudo docker exec "$CONTAINER_NAME" bash -lc 'cat > /tmp/xpu_collective_check.py <<"PY"
import os
import socket
import torch
import torch.distributed as dist

backend = os.environ.get("DIST_BACKEND", "xccl")
rank = int(os.environ["RANK"])
local_rank = int(os.environ.get("LOCAL_RANK", rank))

assert torch.xpu.is_available(), "XPU unavailable"
torch.xpu.set_device(local_rank)
device = torch.device(f"xpu:{local_rank}")

dist.init_process_group(backend=backend)

x = torch.tensor([rank + 1.0], device=device)
dist.all_reduce(x, op=dist.ReduceOp.SUM)
print(f"rank={rank} host={socket.gethostname()} device={device} all_reduce={x.item()}")

dist.barrier()
dist.destroy_process_group()
PY'
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    STEP5_STATUS="FAIL"
    STEP5_MSG="failed to create collective check script in container"
  else
    # Try multiple transport profiles because consumer Core platforms often need host/tcp fallback.
    PROFILE_NAME=""
    PROFILE_ENV=""
    PROFILE_RC=1
    SUCCESS_PROFILE=""
    LAST_FAIL_REASON=""

    for PROFILE in \
      "default|DIST_BACKEND=xccl" \
      "tcp_no_ipc|DIST_BACKEND=xccl CCL_ATL_TRANSPORT=ofi FI_PROVIDER=tcp CCL_IPC=0" \
      "tcp_no_ipc_composite|DIST_BACKEND=xccl CCL_ATL_TRANSPORT=ofi FI_PROVIDER=tcp CCL_IPC=0 ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1"; do
      PROFILE_NAME="${PROFILE%%|*}"
      PROFILE_ENV="${PROFILE#*|}"

      echo "Trying profile: $PROFILE_NAME"
      set +e
      sudo docker exec "$CONTAINER_NAME" bash -lc "timeout --signal=TERM --kill-after=10s ${STEP5_TIMEOUT_SEC}s env ${PROFILE_ENV} python3 -m torch.distributed.run --master_port=${MASTER_PORT} --nproc_per_node=2 /tmp/xpu_collective_check.py"
      PROFILE_RC=$?
      set -e

      if [[ $PROFILE_RC -eq 0 ]]; then
        SUCCESS_PROFILE="$PROFILE_NAME"
        break
      fi

      if [[ $PROFILE_RC -eq 124 ]]; then
        LAST_FAIL_REASON="timeout(${STEP5_TIMEOUT_SEC}s) with profile ${PROFILE_NAME}"
      else
        LAST_FAIL_REASON="rc=${PROFILE_RC} with profile ${PROFILE_NAME}"
      fi
    done

    if [[ -n "$SUCCESS_PROFILE" ]]; then
      STEP5_STATUS="PASS"
      STEP5_MSG="xccl all_reduce succeeded (profile=${SUCCESS_PROFILE})"
    else
      STEP5_STATUS="FAIL"
      STEP5_MSG="xccl all_reduce failed (${LAST_FAIL_REASON})"
    fi
  fi
fi

echo
echo "Result: Collective communication on 2 XPUs is healthy if both ranks print all_reduce=3.0"

print_summary
