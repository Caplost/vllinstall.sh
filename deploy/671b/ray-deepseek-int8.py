#!/usr/bin/env python3
import ray
from ray import serve
from vllm import LLM, SamplingParams
from fastapi import FastAPI, Request
import time
import os
import argparse

# 解析命令行参数
parser = argparse.ArgumentParser(description="Deploy DeepSeek-671B-INT8 model with Ray Serve")
parser.add_argument("--shutdown", action="store_true", help="Shutdown existing deployments before starting")
parser.add_argument("--route-prefix", type=str, default="/", help="URL route prefix (default: /)")
parser.add_argument("--app-name", type=str, default="deepseek_r1_int8", help="Application name")
parser.add_argument("--tokenizer-path", type=str, default="/home/models/DeepSeek-R1-Channel-INT8", 
                    help="Path to the tokenizer (default: /home/models/DeepSeek-R1-Channel-INT8)")
parser.add_argument("--model-path", type=str, default="/home/models/DeepSeek-R1-Channel-INT8", 
                    help="Path to the model (default: /home/models/DeepSeek-R1-Channel-INT8)")
parser.add_argument("--dtype", type=str, default="int8", 
                    help="Model data type (default: int8)")
parser.add_argument("--quantization", type=str, default="awq", 
                    help="Quantization method (default: awq)")
parser.add_argument("--total-gpus", type=int, default=16, 
                    help="Total number of GPUs across all nodes (default: 16)")
parser.add_argument("--distributed", action="store_true", default=True,
                    help="Use distributed deployment mode (default: True)")
args = parser.parse_args()

# 打印版本信息
try:
    import vllm
    print(f"vLLM 版本: {vllm.__version__}")
except:
    print("无法获取 vLLM 版本")

try:
    print(f"Ray 版本: {ray.__version__}")
except:
    print("无法获取 Ray 版本")

# 初始化Ray和Serve
ray.init(address="auto", namespace="vllm")

# 打印集群信息并自动检测GPU
print("==== 集群信息 ====")
print(f"节点数量: {len(ray.nodes())}")

# 检测每个节点的GPU数量和总GPU数量
gpu_counts = {}
total_detected_gpus = 0
for i, node in enumerate(ray.nodes()):
    node_id = node['NodeID'][:8]
    gpu_count = node['Resources'].get('GPU', 0)
    gpu_counts[node_id] = gpu_count
    total_detected_gpus += gpu_count
    print(f"节点 {i+1} - ID: {node_id}... - GPU: {gpu_count}")

print(f"集群中检测到的总GPU数量: {total_detected_gpus}")

# 确定分布式部署策略
nodes_count = len(ray.nodes())
is_multi_node = nodes_count > 1

if is_multi_node:
    print(f"检测到多节点环境: {nodes_count} 个节点")
    use_distributed = args.distributed
else:
    print("检测到单节点环境")
    use_distributed = False

# 确定要使用的GPU资源策略
if use_distributed:
    # 使用分布式部署，每个节点一个副本
    print("使用分布式部署模式")
    # 找出每个节点上最少的GPU数量作为每个副本使用的GPU数量
    min_gpus_per_node = min(gpu_counts.values()) if gpu_counts else 0
    if min_gpus_per_node <= 0:
        print("警告: 无法检测到每个节点的GPU数量，使用默认值8")
        min_gpus_per_node = 8
    
    # 每个副本的GPU数量和副本数
    gpus_per_replica = min_gpus_per_node
    num_replicas = nodes_count
    tensor_parallel_size = gpus_per_replica
    print(f"将部署 {num_replicas} 个副本，每个副本使用 {gpus_per_replica} 个GPU")
    print(f"每个副本的张量并行度: {tensor_parallel_size}")
else:
    # 使用单节点部署，使用所有GPU
    print("使用单节点部署模式")
    gpus_per_replica = total_detected_gpus
    num_replicas = 1
    tensor_parallel_size = total_detected_gpus
    print(f"将部署 {num_replicas} 个副本，使用所有 {gpus_per_replica} 个GPU")
    print(f"张量并行度: {tensor_parallel_size}")

# 如果需要，关闭已有部署
if args.shutdown:
    try:
        print(f"尝试关闭现有部署: {args.app_name}")
        serve.delete(args.app_name)
        print(f"成功关闭部署: {args.app_name}")
    except Exception as e:
        print(f"关闭部署时出错 (如果是首次部署可以忽略): {str(e)}")

# 启动Serve
serve.start(detached=True, http_options={"host": "0.0.0.0", "port": 8000})

# 定义服务
@serve.deployment(
    ray_actor_options={"num_gpus": gpus_per_replica},  # 每个副本使用的GPU数量
    max_ongoing_requests=100,
    num_replicas=num_replicas  # 部署多个副本，每个节点一个
)
class VLLMDeployment:
    def __init__(self):
        # 记录节点信息
        self.node_id = ray.get_runtime_context().get_node_id()
        print(f"模型部署初始化在节点: {self.node_id}")
        
        try:
            # 初始化模型
            print(f"开始加载模型，使用模型路径: {args.model_path}")
            print(f"使用tokenizer路径: {args.tokenizer_path}")
            print(f"使用数据类型: {args.dtype}, 量化方法: {args.quantization}")
            print(f"使用 {tensor_parallel_size} 个GPU进行张量并行")
            
            self.llm = LLM(
                model=args.model_path,  # INT8量化模型路径
                tokenizer=args.tokenizer_path,  # 使用原始模型的tokenizer
                tensor_parallel_size=tensor_parallel_size,  # 每个副本使用的张量并行度
                trust_remote_code=True,
                max_model_len=16384,  # 减小最大长度以节省内存
                tokenizer_mode="auto",
           
                quantization=args.quantization,
                enforce_eager=True,
                gpu_memory_utilization=0.95,  # 增加内存利用率以适应大模型
            )
            print(f"模型加载完成，节点: {self.node_id}")
        except Exception as e:
            print(f"模型加载失败: {str(e)}")
            import traceback
            print(traceback.format_exc())
            raise
    
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
            "model": data.get("model", "DeepSeek-671B-INT8"),
            "node": self.node_id,  # 返回处理请求的节点ID
            "choices": [{"text": completion_text, "index": 0, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": len(outputs[0].prompt_token_ids),
                "completion_tokens": len(outputs[0].outputs[0].token_ids),
                "total_tokens": len(outputs[0].prompt_token_ids) + len(outputs[0].outputs[0].token_ids)
            }
        }

# 部署服务 - 使用多个副本，每个节点一个
app = VLLMDeployment.bind()
handle = serve.run(app, name=args.app_name, route_prefix=args.route_prefix)

print(f"\n服务已启动，使用 {num_replicas} 个副本，每个副本使用 {gpus_per_replica} 个GPU")
print(f"部署模式: {'分布式多节点' if use_distributed else '单节点'}")
print(f"每个副本的张量并行度: {tensor_parallel_size}")
print(f"应用名称: {args.app_name}")
print(f"路由前缀: {args.route_prefix}")
print(f"模型路径: {args.model_path}")
print(f"Tokenizer路径: {args.tokenizer_path}")
print(f"数据类型: {args.dtype}")
print(f"量化方法: {args.quantization}")
print(f"请通过 http://localhost:8000{args.route_prefix} 访问服务")
print("检查Ray状态: ray status -v")
print(f"GPU使用情况: 总共使用 {total_detected_gpus} 个GPU进行分布式部署")
print("\n示例请求:")
print(f"curl -X POST http://localhost:8000{args.route_prefix} \\")
print('  -H "Content-Type: application/json" \\')
print('  -d \'{"prompt": "你好，请介绍一下自己", "max_tokens": 1000, "temperature": 0.7}\'') 