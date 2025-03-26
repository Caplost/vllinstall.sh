#!/usr/bin/env python3
import ray
from ray import serve
from vllm import LLM, SamplingParams
from fastapi import FastAPI, Request
import time
import os
import sys
import argparse
import subprocess
import torch
import platform

# 定义颜色代码
GREEN = '\033[0;32m'
BLUE = '\033[0;34m'
RED = '\033[0;31m'
YELLOW = '\033[1;33m'
NC = '\033[0m'  # No Color

def print_colored(text, color):
    """打印彩色文本"""
    print(f"{color}{text}{NC}")

def print_error(text):
    """打印错误信息"""
    print_colored(f"错误: {text}", RED)

def print_warning(text):
    """打印警告信息"""
    print_colored(f"警告: {text}", YELLOW)

def print_info(text):
    """打印信息"""
    print_colored(text, BLUE)

def print_success(text):
    """打印成功信息"""
    print_colored(text, GREEN)

def check_gpu_availability():
    """检查GPU是否可用"""
    # 首先检查系统是否有NVIDIA GPU
    try:
        # 尝试使用nvidia-smi命令检测GPU
        result = subprocess.run(
            ["nvidia-smi"], 
            stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE,
            text=True,
            check=False
        )
        
        if result.returncode != 0:
            print_error("nvidia-smi命令失败，可能没有安装NVIDIA驱动或者没有GPU")
            print_error(f"错误详情: {result.stderr}")
            return False
            
        # 检查PyTorch是否能访问CUDA
        if not torch.cuda.is_available():
            print_error("PyTorch无法访问CUDA。请确保已正确安装支持CUDA的PyTorch版本")
            return False
            
        # 获取可用的GPU数量
        gpu_count = torch.cuda.device_count()
        if gpu_count == 0:
            print_error("PyTorch检测到0个GPU。请确认GPU是否正常工作")
            return False
            
        # 获取GPU信息
        print_success(f"检测到 {gpu_count} 个可用的GPU:")
        for i in range(gpu_count):
            gpu_name = torch.cuda.get_device_name(i)
            print_info(f"  GPU {i}: {gpu_name}")
            
        return True
    except Exception as e:
        print_error(f"检测GPU时出错: {str(e)}")
        return False

# 解析命令行参数
parser = argparse.ArgumentParser(description="Deploy DeepSeek-R1-Int4 model with Ray Serve")
parser.add_argument("--shutdown", action="store_true", help="Shutdown existing deployments before starting")
parser.add_argument("--route-prefix", type=str, default="/", help="URL route prefix (default: /)")
parser.add_argument("--app-name", type=str, default="deepseek_r1_int4", help="Application name")
parser.add_argument("--tokenizer-path", type=str, default="/home/models/DeepSeek-R1-Int4-AWQ", 
                    help="Path to the tokenizer (default: /home/models/DeepSeek-R1-Int4-AWQ)")
parser.add_argument("--model-path", type=str, default="/home/models/DeepSeek-R1-Int4-AWQ", 
                    help="Path to the model (default: /home/models/DeepSeek-R1-Int4-AWQ)")
parser.add_argument("--dtype", type=str, default="int4", 
                    help="Model data type (default: int4)")
parser.add_argument("--quantization", type=str, default="awq", 
                    help="Quantization method (default: awq)")
parser.add_argument("--total-gpus", type=int, default=16, 
                    help="Total number of GPUs across all nodes (default: 16)")
parser.add_argument("--distributed", action="store_true", default=True,
                    help="Use distributed deployment mode (default: True)")
parser.add_argument("--cpu-only", action="store_true", 
                    help="Run in CPU-only mode (not recommended for production)")
parser.add_argument("--debug", action="store_true", 
                    help="Enable debug mode with more detailed logging")
args = parser.parse_args()

# 系统信息
print_info("==== 系统信息 ====")
print_info(f"操作系统: {platform.system()} {platform.release()}")
print_info(f"Python版本: {sys.version}")

# 打印版本信息
try:
    import vllm
    print_info(f"vLLM 版本: {vllm.__version__}")
except Exception as e:
    print_error(f"无法获取 vLLM 版本: {str(e)}")

try:
    print_info(f"Ray 版本: {ray.__version__}")
except Exception as e:
    print_error(f"无法获取 Ray 版本: {str(e)}")

try:
    print_info(f"PyTorch 版本: {torch.__version__}")
    if torch.cuda.is_available():
        print_info(f"CUDA 版本: {torch.version.cuda}")
    else:
        print_warning("PyTorch 无法访问 CUDA")
except Exception as e:
    print_error(f"检查 PyTorch 版本时出错: {str(e)}")

# 检查模型路径是否存在
if not os.path.exists(args.model_path):
    print_error(f"模型路径不存在: {args.model_path}")
    print_error("请确保模型已下载并指定正确的路径")
    sys.exit(1)

# 在非CPU模式下检查GPU可用性
if not args.cpu_only:
    print_info("\n==== GPU 检测 ====")
    if not check_gpu_availability():
        print_error("\nGPU检测失败。您有以下选择:")
        print_error("1. 确保NVIDIA驱动已正确安装")
        print_error("2. 确保PyTorch CUDA版本与系统CUDA版本兼容")
        print_error("3. 如果在Docker中运行，确保正确传递了GPU设备")
        print_error("4. 使用 --cpu-only 参数以CPU模式运行（不推荐生产环境使用）")
        sys.exit(1)

# 初始化Ray和Serve
try:
    print_info("\n==== 初始化Ray ====")
    ray.init(address="auto", namespace="vllm", ignore_reinit_error=True)
    print_success("Ray 初始化成功")
except Exception as e:
    print_error(f"Ray 初始化失败: {str(e)}")
    sys.exit(1)

# 打印集群信息并自动检测GPU
print_info("\n==== 集群信息 ====")
print_info(f"节点数量: {len(ray.nodes())}")

# 检测每个节点的GPU数量和总GPU数量
gpu_counts = {}
total_detected_gpus = 0
for i, node in enumerate(ray.nodes()):
    node_id = node['NodeID'][:8]
    gpu_count = node['Resources'].get('GPU', 0)
    gpu_counts[node_id] = gpu_count
    total_detected_gpus += gpu_count
    print_info(f"节点 {i+1} - ID: {node_id}... - GPU: {gpu_count}")

print_info(f"集群中检测到的总GPU数量: {total_detected_gpus}")

if total_detected_gpus == 0 and not args.cpu_only:
    print_error("Ray集群未检测到任何GPU资源！")
    print_error("请确保Ray集群有可用的GPU资源，或者使用 --cpu-only 参数")
    sys.exit(1)

# 确定分布式部署策略
nodes_count = len(ray.nodes())
is_multi_node = nodes_count > 1

if is_multi_node:
    print_info(f"检测到多节点环境: {nodes_count} 个节点")
    use_distributed = args.distributed
else:
    print_info("检测到单节点环境")
    use_distributed = False

# 确定要使用的GPU资源策略
if args.cpu_only:
    print_info("使用CPU模式（性能将大幅降低）")
    gpus_per_replica = 0
    num_replicas = 1
    tensor_parallel_size = None
else:
    if use_distributed:
        # 使用分布式部署，每个节点一个副本
        print_info("使用分布式部署模式")
        # 找出每个节点上最少的GPU数量作为每个副本使用的GPU数量
        min_gpus_per_node = min(gpu_counts.values()) if gpu_counts else 0
        if min_gpus_per_node <= 0:
            print_warning("警告: 无法检测到每个节点的GPU数量，使用默认值8")
            min_gpus_per_node = 8
        
        # 每个副本的GPU数量和副本数
        gpus_per_replica = min_gpus_per_node
        num_replicas = nodes_count
        tensor_parallel_size = gpus_per_replica
        print_info(f"将部署 {num_replicas} 个副本，每个副本使用 {gpus_per_replica} 个GPU")
        print_info(f"每个副本的张量并行度: {tensor_parallel_size}")
    else:
        # 使用单节点部署，使用所有GPU
        print_info("使用单节点部署模式")
        gpus_per_replica = total_detected_gpus
        num_replicas = 1
        tensor_parallel_size = total_detected_gpus
        print_info(f"将部署 {num_replicas} 个副本，使用所有 {gpus_per_replica} 个GPU")
        print_info(f"张量并行度: {tensor_parallel_size}")

# 如果需要，关闭已有部署
if args.shutdown:
    try:
        print_info(f"尝试关闭现有部署: {args.app_name}")
        serve.delete(args.app_name)
        print_success(f"成功关闭部署: {args.app_name}")
    except Exception as e:
        print_warning(f"关闭部署时出错 (如果是首次部署可以忽略): {str(e)}")

# 启动Serve
try:
    print_info("\n==== 启动Ray Serve ====")
    serve.start(detached=True, http_options={"host": "0.0.0.0", "port": 8000})
    print_success("Ray Serve 启动成功")
except Exception as e:
    print_error(f"启动Ray Serve失败: {str(e)}")
    sys.exit(1)

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
        print_info(f"模型部署初始化在节点: {self.node_id}")
        
        try:
            # 初始化模型
            print_info(f"开始加载模型，使用模型路径: {args.model_path}")
            print_info(f"使用tokenizer路径: {args.tokenizer_path}")
            print_info(f"使用数据类型: {args.dtype}, 量化方法: {args.quantization}")
            if not args.cpu_only:
                print_info(f"使用 {tensor_parallel_size} 个GPU进行张量并行")
            
            # 构建LLM参数
            llm_kwargs = {
                "model": args.model_path,  # INT4量化模型路径
                "tokenizer": args.tokenizer_path,  # 使用原始模型的tokenizer
                "trust_remote_code": True,
                "max_model_len": 16384,  # 减小最大长度以节省内存
                "tokenizer_mode": "auto",
                "quantization": args.quantization,
                "enforce_eager": True,
            }
            
            # 根据是否使用GPU添加相关参数
            if not args.cpu_only:
                llm_kwargs.update({
                    "tensor_parallel_size": tensor_parallel_size,
                    "gpu_memory_utilization": 0.95,  # 增加内存利用率以适应大模型
                    "dtype": args.dtype,  # 使用命令行参数指定的数据类型
                })
            else:
                # CPU模式设置
                llm_kwargs.update({
                    "device": "cpu",  # 强制使用CPU
                    "dtype": "float32",  # CPU模式下使用float32
                })
            
            # Debug模式下打印完整参数
            if args.debug:
                print_info("LLM初始化参数:")
                for k, v in llm_kwargs.items():
                    print_info(f"  {k}: {v}")
            
            self.llm = LLM(**llm_kwargs)
            print_success(f"模型加载完成，节点: {self.node_id}")
        except Exception as e:
            print_error(f"模型加载失败: {str(e)}")
            import traceback
            print_error(traceback.format_exc())
            raise
    
    async def __call__(self, request: Request):
        start_time = time.time()
        try:
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
            print_info(f"请求处理时间: {process_time:.2f}秒, 节点: {self.node_id}")
            
            return {
                "id": f"cmpl-{time.time()}",
                "object": "text_completion",
                "created": int(time.time()),
                "model": data.get("model", "DeepSeek-R1-Int4-AWQ"),
                "node": self.node_id,  # 返回处理请求的节点ID
                "choices": [{"text": completion_text, "index": 0, "finish_reason": "stop"}],
                "usage": {
                    "prompt_tokens": len(outputs[0].prompt_token_ids),
                    "completion_tokens": len(outputs[0].outputs[0].token_ids),
                    "total_tokens": len(outputs[0].prompt_token_ids) + len(outputs[0].outputs[0].token_ids)
                }
            }
        except Exception as e:
            error_time = time.time() - start_time
            print_error(f"处理请求时出错，耗时 {error_time:.2f}秒: {str(e)}")
            raise

# 部署服务 - 使用多个副本，每个节点一个
print_info("\n==== 部署服务 ====")
try:
    app = VLLMDeployment.bind()
    handle = serve.run(app, name=args.app_name, route_prefix=args.route_prefix)
    print_success(f"服务 {args.app_name} 部署成功！")
except Exception as e:
    print_error(f"部署服务时出错: {str(e)}")
    if args.debug:
        import traceback
        print_error(traceback.format_exc())
    sys.exit(1)

print_success(f"\n服务已启动，使用 {num_replicas} 个副本，每个副本使用 {gpus_per_replica} 个GPU")
print_info(f"部署模式: {'分布式多节点' if use_distributed else '单节点'}")
if not args.cpu_only:
    print_info(f"每个副本的张量并行度: {tensor_parallel_size}")
print_info(f"应用名称: {args.app_name}")
print_info(f"路由前缀: {args.route_prefix}")
print_info(f"模型路径: {args.model_path}")
print_info(f"Tokenizer路径: {args.tokenizer_path}")
print_info(f"数据类型: {args.dtype}")
print_info(f"量化方法: {args.quantization}")
print_info(f"请通过 http://localhost:8000{args.route_prefix} 访问服务")
print_info("检查Ray状态: ray status -v")
print_info(f"GPU使用情况: 总共使用 {total_detected_gpus} 个GPU进行{'分布式' if use_distributed else ''}部署")
print_info("\n示例请求:")
print_info(f"curl -X POST http://localhost:8000{args.route_prefix} \\")
print_info('  -H "Content-Type: application/json" \\')
print_info('  -d \'{"prompt": "你好，请介绍一下自己", "max_tokens": 1000, "temperature": 0.7}\'') 