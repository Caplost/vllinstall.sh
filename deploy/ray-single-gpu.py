#!/usr/bin/env python3
import ray
from ray import serve
from vllm import LLM, SamplingParams
from fastapi import FastAPI, Request
import time
import os

# 初始化Ray和Serve
ray.init(address="auto", namespace="vllm")

# 打印集群信息
print("==== 集群信息 ====")
print(f"节点数量: {len(ray.nodes())}")
for i, node in enumerate(ray.nodes()):
    print(f"节点 {i+1} - ID: {node['NodeID'][:8]}... - GPU: {node['Resources'].get('GPU', 0)}")
    
# 计算集群中的总GPU数量
total_gpus = sum(node['Resources'].get('GPU', 0) for node in ray.nodes())
print(f"集群中的总GPU数量: {total_gpus}")

# 检查是否有现有服务运行
status = serve.status()
if any("vllm_multi_service" in app for app in status.applications):
    print("发现现有服务 'vllm_multi_service' 正在运行")
    print("将尝试替换现有服务...")
    # 使用相同的名称将替换现有服务
    service_name = "vllm_multi_service"
else:
    # 使用新名称
    service_name = "vllm_single_gpu_service"

# 启动或重用现有的Serve实例
serve.start(detached=True, http_options={"host": "0.0.0.0", "port": 8000})

# 确定合理的replica数量 - 不超过可用GPU数量
replicas = min(2, max(1, total_gpus)) # 最多使用2个replica，至少1个，不超过总GPU数

# 定义服务 - 单GPU部署方案，极致优化内存使用
@serve.deployment(
    ray_actor_options={"num_gpus": 1},  # 每个副本只使用1个GPU
    max_ongoing_requests=16,  # 大幅减少并发请求数，降低内存压力
    num_replicas=replicas,    # 根据可用GPU数量动态设置副本数
)
class VLLMDeployment:
    def __init__(self):
        # 记录节点信息
        self.node_id = ray.get_runtime_context().get_node_id()
        print(f"模型部署初始化在节点: {self.node_id}")
        
        # 初始化模型 - 极致内存优化
        MODEL_CTX_LEN = 4096  # 进一步减小上下文长度，大幅降低内存需求
        
        self.llm = LLM(
            model="/home/models/DeepSeek-R1-Distill-Qwen-32B",
            tensor_parallel_size=1,    # 单GPU运行
            trust_remote_code=True,
            max_model_len=MODEL_CTX_LEN,  # 显著减小最大上下文长度
            gpu_memory_utilization=0.65,  # 进一步降低内存使用率，更多缓冲空间
            max_num_seqs=8,               # 大幅减小批处理大小
            max_num_batched_tokens=MODEL_CTX_LEN,  # 与max_model_len保持一致
            swap_space=16,               # 增加更多交换空间，减轻GPU内存压力
            block_size=8,                # 使用更小的块大小，进一步优化内存
            enable_lora=False,           # 禁用LoRA，减少内存使用
            disable_custom_all_reduce=True, # 处理内存问题
            enforce_eager=True,          # 强制即时执行，可能有助于解决某些内存问题
            dtype="half"                 # 使用半精度以减少内存使用
        )
        print(f"模型加载完成，节点: {self.node_id}，上下文长度: {MODEL_CTX_LEN}")
    
    async def __call__(self, request: Request):
        start_time = time.time()
        data = await request.json()
        prompt = data.get("prompt", "")
        max_tokens = min(data.get("max_tokens", 1024), 1024)  # 进一步限制最大生成长度为1024
        
        sampling_params = SamplingParams(
            max_tokens=max_tokens,
            temperature=data.get("temperature", 0.7)
        )
        
        try:
            outputs = self.llm.generate([prompt], sampling_params)
            completion_text = outputs[0].outputs[0].text
            
            process_time = time.time() - start_time
            print(f"请求处理时间: {process_time:.2f}秒, 节点: {self.node_id}")
            
            return {
                "id": f"cmpl-{time.time()}",
                "object": "text_completion",
                "created": int(time.time()),
                "model": data.get("model", "DeepSeek-R1"),
                "node": self.node_id,
                "choices": [{"text": completion_text, "index": 0, "finish_reason": "stop"}],
                "usage": {
                    "prompt_tokens": len(outputs[0].prompt_token_ids),
                    "completion_tokens": len(outputs[0].outputs[0].token_ids),
                    "total_tokens": len(outputs[0].prompt_token_ids) + len(outputs[0].outputs[0].token_ids)
                }
            }
        except Exception as e:
            error_time = time.time() - start_time
            print(f"错误: {str(e)}, 处理时间: {error_time:.2f}秒, 节点: {self.node_id}")
            return {
                "error": str(e),
                "node": self.node_id
            }

# 部署服务
deployment = VLLMDeployment.bind()
handle = serve.run(deployment, name=service_name)

print(f"\n服务已启动 - 针对GPU内存不足问题优化，极致降低内存使用")
print(f"服务名称: {service_name}")
print(f"副本数量: {replicas}")
print("请通过 http://localhost:8000/ 访问服务")
print("检查副本分布: ray status -v")
print("警告：已大幅减小上下文长度为4096，生成长度限制为1024，以解决内存不足问题") 