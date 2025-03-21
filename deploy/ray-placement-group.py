#!/usr/bin/env python3
import ray
from ray import serve
from ray.util.placement_group import placement_group, PlacementGroupSchedulingStrategy
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

# 创建显式的placement group，要求跨节点
# 假设每个节点有8个GPU
NUM_NODES = len(ray.nodes())
NUM_GPUS_PER_NODE = 8

print(f"\n创建跨{NUM_NODES}个节点的placement group")
pg_bundles = [{"GPU": NUM_GPUS_PER_NODE} for _ in range(NUM_NODES)]
pg = placement_group(bundles=pg_bundles, strategy="SPREAD")
ray.get(pg.ready())
print(f"Placement Group创建成功: {pg.id}")

# 服务配置
serve.start(detached=True, http_options={"host": "0.0.0.0", "port": 8000})

@serve.deployment(
    ray_actor_options={
        "num_gpus": 8,
        "placement_group": pg,
        "placement_group_bundle_index": 0  # 第一个副本使用第一个bundle
    },
    max_ongoing_requests=100,
    num_replicas=1  # 先启动一个副本
)
class VLLMDeployment1:
    def __init__(self):
        # 打印节点信息
        self.node_id = ray.get_runtime_context().get_node_id()
        print(f"部署1初始化在节点: {self.node_id}")
        
        self.llm = LLM(
            model="/home/models/DeepSeek-R1-Distill-Qwen-32B",
            tensor_parallel_size=8,
            trust_remote_code=True,
            max_model_len=131072
        )
    
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
            "node": self.node_id,  # 额外返回节点ID以便识别
            "choices": [{"text": completion_text, "index": 0, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": len(outputs[0].prompt_token_ids),
                "completion_tokens": len(outputs[0].outputs[0].token_ids),
                "total_tokens": len(outputs[0].prompt_token_ids) + len(outputs[0].outputs[0].token_ids)
            }
        }

@serve.deployment(
    ray_actor_options={
        "num_gpus": 8,
        "placement_group": pg,
        "placement_group_bundle_index": 1  # 第二个副本使用第二个bundle
    },
    max_ongoing_requests=100,
    num_replicas=1  # 先启动一个副本
)
class VLLMDeployment2:
    def __init__(self):
        # 打印节点信息
        self.node_id = ray.get_runtime_context().get_node_id()
        print(f"部署2初始化在节点: {self.node_id}")
        
        self.llm = LLM(
            model="/home/models/DeepSeek-R1-Distill-Qwen-32B",
            tensor_parallel_size=8,
            trust_remote_code=True,
            max_model_len=131072
        )
    
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
            "node": self.node_id,  # 额外返回节点ID以便识别
            "choices": [{"text": completion_text, "index": 0, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": len(outputs[0].prompt_token_ids),
                "completion_tokens": len(outputs[0].outputs[0].token_ids),
                "total_tokens": len(outputs[0].prompt_token_ids) + len(outputs[0].outputs[0].token_ids)
            }
        }

# 创建路由器来分发请求
@serve.deployment(route_prefix="/")
class Router:
    def __init__(self, deployment1, deployment2):
        self.deployment1 = deployment1
        self.deployment2 = deployment2
        self.current = 0  # 用于轮询
    
    async def __call__(self, request: Request):
        # 简单的轮询分发
        if self.current == 0:
            self.current = 1
            return await self.deployment1.remote(request)
        else:
            self.current = 0
            return await self.deployment2.remote(request)

# 部署服务
deployment1 = VLLMDeployment1.bind()
deployment2 = VLLMDeployment2.bind()
router = Router.bind(deployment1, deployment2)

# 启动服务
handle = serve.run(router)

print("\n服务已启动，两个节点都应该各自使用8个GPU")
print("请通过 http://localhost:8000/ 访问服务")
print("查看服务状态: ray status -v") 