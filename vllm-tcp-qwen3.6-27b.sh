#!/bin/bash
model="/llm/models/Qwen3.6-27B"
served_model_name="Qwen3.6-27B"

# Keep IO
export CCL_ATL_TRANSPORT=ofi
export FI_PROVIDER=tcp
export FI_TCP_IFACE=lo

export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export VLLM_OFFLOAD_WEIGHTS_BEFORE_QUANT=1

python3 -m vllm.entrypoints.openai.api_server \
    --model "$model" \
    --served-model-name "$served_model_name" \
    --dtype=float16 \
    --enforce-eager \
    --port 8001 \
    --host 0.0.0.0 \
    --trust-remote-code \
    --disable-sliding-window \
    --gpu-memory-util=0.9 \
    --max-num-batched-tokens 8192 \
    --max-model-len 264000 \
    --enable-log-requests \
    --enable-prefix-caching \
    --block-size 64 \
    --quantization sym_int4 \
    --tensor-parallel-size 2
