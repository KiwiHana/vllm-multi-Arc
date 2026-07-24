import time
import requests
import statistics
 
url = "http://localhost:8001/v1/chat/completions"
headers = {"Authorization": "Bearer intel123", "Content-Type": "application/json"}
 
def test_once(target_tokens):
    base = "人工智能是计算机科学的一个重要分支，致力于研究、开发用于模拟、延伸和扩展人类智能的理论与技术。"
    chars = int(target_tokens * 1.5)
    prompt = (base * (chars // len(base) + 2))[:chars]
    data = {
        "model": "Qwen3.6-27B",
        "messages": [{"role": "user", "content": f"总结下文：\n\n{prompt}"}],
        "max_tokens": 300,
        "temperature": 0.7
    }
    start = time.time()
    try:
        resp = requests.post(url, json=data, headers=headers, timeout=180)
        if resp.status_code != 200:
            return None
        result = resp.json()
        pt = result['usage']['prompt_tokens']
        ct = result['usage']['completion_tokens']
        dur = time.time() - start
        return {"prompt": pt, "tps": ct / dur, "dur": dur}
    except:
        return None
 
print("=" * 70)
print("🚀 终极严谨测试：32k → 128k (每个长度测3次)")
print("=" * 70)
 
# 测试范围
for target in range(32768, 131073, 4096):
    print(f"\n📏 目标输入: {target} tokens")
    results = []
    for i in range(3):
        res = test_once(target)
        if res is None:
            print(f"   ❌ 第 {i+1} 次请求失败 (OOM或超时)，停止测试！")
            print(f"   🛑 硬件极限约为: {target - 4096} tokens")
            exit(0)
        results.append(res['tps'])
        print(f"   第 {i+1} 次: TPS={res['tps']:.2f}, 输入={res['prompt']}")
    avg_tps = statistics.mean(results)
    print(f"   ✅ 平均 TPS: {avg_tps:.2f}")
