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

serve.start(detached=True, http_options={"host": "0.0.0.0", "port": 8000})

# 定义服务
@serve.deployment(
    ray_actor_options={"num_gpus": 8},
    max_ongoing_requests=100,
    # 关键：直接创建固定数量的副本，而不是依赖自动扩展
    num_replicas=2
)
class VLLMDeployment:
    def __init__(self):
        # 记录节点信息
        self.node_id = ray.get_runtime_context().get_node_id()
        print(f"模型部署初始化在节点: {self.node_id}")
        
        # 初始化模型
        self.llm = LLM(
            model="/home/models/DeepSeek-R1-Distill-Qwen-32B",
            tensor_parallel_size=8,
            trust_remote_code=True,
            max_model_len=131072
        )
        print(f"模型加载完成，节点: {self.node_id}")
    
    async def __call__(self, request: Request):
        start_time = time.time()
        data = await request.json()
        prompt = data.get("prompt", "")
        max_tokens = data.get("max_tokens", 1000)
        
        sampling_params = SamplingParams(
            max_tokens=max_tokens,
            temperature=data.get("temperature", 0.7)
        )
        
        outputs = self.llm.generate([prompt], sampling_params)
        completion_text = outputs[0].outputs[0].text
        
        process_time = time.time() - start_time
        print(f"请求处理时间: {process_time:.2f}秒, 节点: {self.node_id}")
        
        return {
            "id": f"cmpl-{time.time()}",
            "object": "text_completion",
            "created": int(time.time()),
            "model": data.get("model", "DeepSeek-R1"),
            "node": self.node_id,  # 返回处理请求的节点ID
            "choices": [{"text": completion_text, "index": 0, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": len(outputs[0].prompt_token_ids),
                "completion_tokens": len(outputs[0].outputs[0].token_ids),
                "total_tokens": len(outputs[0].prompt_token_ids) + len(outputs[0].outputs[0].token_ids)
            }
        }

# 部署服务 - 使用固定的2个副本，Ray会自动将它们分配到不同节点
deployment = VLLMDeployment.bind()
handle = serve.run(deployment, name="vllm_multi_service")

print("\n服务已启动，会自动创建2个副本并分配到不同节点")
print("请通过 http://localhost:8000/ 访问服务")
print("检查副本分布: ray status -v")
print("注意: 由于每个副本需要8个GPU，Ray应会自动将它们分配到不同节点") 