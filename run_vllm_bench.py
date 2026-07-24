#!/usr/bin/env python3
# python bench.py --model /model/gpt-oss-20b --input-len 8192 --output-len 1024
import subprocess
import re
import time
import csv
import argparse
from typing import List, Dict

#BATCH_SIZES = [1, 2, 4, 8, 10, 16, 32]
BATCH_SIZES = [1]
#input_len = [1024,2048,4096,8192,16384,32768,65536,102400,131072,262144,524288]
input_len = [1024,2048,4096,8192,16384,32768]
# 占位，真正内容由 argparse 填入
BASE_CMD = [
    "vllm", "bench", "serve",
    "--dataset-name", "random",
    "--ignore-eos",
    "--trust_remote_code",
    "--request-rate", "inf",
    "--backend", "vllm",
    "--port", "8001",
]

RE_PATTERNS = {
    "Benchmark Duration (s)": r"Benchmark duration \(s\):\s+([\d.]+)",
    "Total Input Tokens": r"Total input tokens:\s+(\d+)",
    "Total Generated Tokens": r"Total generated tokens:\s+(\d+)",
    "Request Throughput (req/s)": r"Request throughput \(req/s\):\s+([\d.]+)",
    "Output Token Throughput (tok/s)": r"Output token throughput \(tok/s\):\s+([\d.]+)",
    "Total Token Throughput (tok/s)": r"Total token throughput \(tok/s\):\s+([\d.]+)",
    "Mean TTFT (ms)": r"Mean TTFT \(ms\):\s+([\d.]+)",
    "P99 TTFT (ms)": r"P99 TTFT \(ms\):\s+([\d.]+)",
    "Mean TPOT (ms)": r"Mean TPOT \(ms\):\s+([\d.]+)",
    "P99 TPOT (ms)": r"P99 TPOT \(ms\):\s+([\d.]+)",
    "Mean ITL (ms)": r"Mean ITL \(ms\):\s+([\d.]+)",
    "P99 ITL (ms)": r"P99 ITL \(ms\):\s+([\d.]+)"
}

def extract_values(log: str, batch_size: int) -> Dict[str, float]:
    row = {"Batch Size": batch_size}
    for col, pat in RE_PATTERNS.items():
        match = re.search(pat, log)
        row[col] = float(match.group(1)) if match else None
    return row

def run_benchmark(bs: int, model: str, in_len: int, out_len: int) -> str:
    cmd = BASE_CMD + [
        "--model", model,
        "--served-model-name","Qwen3.6-27B",
        "--random-input-len", str(in_len),
        "--random-output-len", str(out_len),
        "--num-prompt", str(bs)
    ]
    print(f"[INFO] Running: {' '.join(cmd)}")
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=True
    )
    return proc.stdout

def main():
    parser = argparse.ArgumentParser(description="vLLM benchmark sweep over batch sizes")
    parser.add_argument("--model", required=True, default="/llm/models/Qwen3.6-27B", help="path to model")
    #parser.add_argument("--input-len", type=int, default=1024, required=True, help="random input length")
    parser.add_argument("--output-len", type=int, default=512, required=True, help="random output length")
    args = parser.parse_args()

    headers = ["Batch Size"] + list(RE_PATTERNS.keys())
    rows: List[Dict[str, float]] = []

    for bs in BATCH_SIZES:
        try:
            for inputlen in input_len:
                log = run_benchmark(bs, args.model, inputlen, args.output_len)
                #log = run_benchmark(bs, args.model, args.input_len, args.output_len)
                rows.append(extract_values(log, bs))
            print(f"[SUCCESS] Batch Size {bs} done.")
        except Exception as e:
            print(f"[ERROR] Batch Size {bs} failed: {e}")
            rows.append({"Batch Size": bs, **{k: None for k in RE_PATTERNS}})
        time.sleep(10)

    out_file = "./vllm_benchmark.csv"
    with open(out_file, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(headers)
        writer.writerows([[row[h] for h in headers] for row in rows])

    print(f"\nResults saved to {out_file}")

if __name__ == "__main__":
    main()
