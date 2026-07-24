# vllm-multi-Arc
enable vllm on intel multi-arc

下载模型Qwen3.6-27B，放在 ~/LLM

下载docker-backend.sh ，vllm-qwen3.6-27b-openaikey.sh， run_vllm_bench.py放在~/llm-server

下载镜像
```
docker pull intel/llm-scaler-vllm:0.21.0-b1
```

快速操作指令：
第一个窗口启动Qwen3.6-27B-INT4模型服务。
```
~$ cd ~/llm-server
~$ sudo bash docker-backend.sh 
~$ sudo docker exec -it llm-serving bash 
~# cd /llm
~# bash vllm-qwen3.6-27b-openaikey.sh
```

Note: vllm-qwen3.6-27b-openaikey.sh里修改上下文长度--max-model-len 注意这里是（输入+输出）x batch size的最大值。

--quantization sym_int4 或者fp8。

--tensor-parallel-size 是intel独显的部署数量

第二个窗口测试vllm benchmark。
```
~$ sudo docker exec -it llm-serving bash
~# cd /llm
~# python run_vllm_bench.py --model /llm/models/Qwen3.6-27B --output-len 512
```
脚本run_vllm_bench.py 里BATCH_SIZE=[ ], input_len=[ ] 要手动改，测试结果vllm_benchmark.csv保存到~/llm-server文件夹里

