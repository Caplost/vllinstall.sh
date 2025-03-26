#!/usr/bin/env python3
import os
import sys
import ray
from ray import serve
import argparse
import socket
import logging
import time
import uuid
import json
from typing import Dict, List, Optional, Union
import torch
import asyncio

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger("DeepSeek-R1-Int4-AMD")

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
    print_colored(f"错误: {text}", RED)
    logger.error(text)

def print_warning(text):
    print_colored(f"警告: {text}", YELLOW)
    logger.warning(text)

def print_info(text):
    print_colored(text, BLUE)
    logger.info(text)

def print_success(text):
    print_colored(text, GREEN)
    logger.info(text)

# 解析命令行参数
parser = argparse.ArgumentParser(description="Deploy DeepSeek-R1-Int4-AWQ model with Ray Serve on AMD GPU")
parser.add_argument("--model-path", type=str, required=True, help="Path to the model directory")
parser.add_argument("--app-name", type=str, default="deepseek_r1_int4_amd", help="Application name")
parser.add_argument("--port", type=int, default=8000, help="Port for the HTTP server")
parser.add_argument("--num-gpus", type=str, default="auto", help="Number of GPUs to use per replica (number or 'auto')")
parser.add_argument("--num-replicas", type=int, default=1, help="Number of replicas to deploy")
parser.add_argument("--max-concurrent-queries", type=int, default=8, help="Maximum number of concurrent queries per worker")
parser.add_argument("--no-shutdown", action="store_true", help="Don't shut down existing deployments")
parser.add_argument("--debug", action="store_true", help="Enable debug mode")
parser.add_argument("--ray-address", type=str, default="auto", help="Ray cluster address (already running)")
parser.add_argument("--tensor-parallel-size", type=int, default=16, help="Tensor parallel size for distributed inference (default: 16)")
parser.add_argument("--distributed", action="store_true", default=True, help="Enable distributed mode (required for tensor-parallel-size > 8)")
parser.add_argument("--force-cpu", action="store_true", help="Force CPU mode even if no GPU is detected")
args = parser.parse_args()

# 启用调试模式
if args.debug:
    logger.setLevel(logging.DEBUG)
    print_info("调试模式已启用")

# 处理自动GPU数量 - 简化处理，不进行详细检测
if args.num_gpus == "auto":
    try:
        available_gpus = torch.cuda.device_count()
        args.num_gpus = float(available_gpus) if available_gpus > 0 else 0
        print_info(f"GPU设置: {args.num_gpus}")
    except:
        print_warning("无法自动检测GPU数量，使用默认值1")
        args.num_gpus = 1
else:
    try:
        args.num_gpus = float(args.num_gpus)
    except ValueError:
        print_error(f"无效的GPU数量: {args.num_gpus}，必须是数字或'auto'")
        sys.exit(1)

# 显示参数
print_info(f"模型路径: {args.model_path}")
print_info(f"应用名称: {args.app_name}")
print_info(f"端口: {args.port}")
print_info(f"每个副本使用GPU数量: {args.num_gpus}")
print_info(f"副本数量: {args.num_replicas}")
print_info(f"每个工作进程最大并发查询数: {args.max_concurrent_queries}")
print_info(f"张量并行度: {args.tensor_parallel_size}")
print_info(f"不关闭已有部署: {args.no_shutdown}")
print_info(f"分布式模式: {args.distributed}")
print_info(f"Ray集群地址: {args.ray_address}")

# 检测张量并行度是否合理
if args.tensor_parallel_size > 8 and not args.distributed:
    print_warning(f"张量并行度 {args.tensor_parallel_size} 大于8，但分布式模式未启用。自动启用分布式模式。")
    args.distributed = True

# 检查模型路径
if not os.path.exists(args.model_path):
    print_error(f"模型路径不存在: {args.model_path}")
    sys.exit(1)

if not os.path.isdir(args.model_path):
    print_error(f"模型路径不是目录: {args.model_path}")
    sys.exit(1)

if not os.access(args.model_path, os.R_OK):
    print_error(f"无法读取模型目录: {args.model_path}")
    sys.exit(1)

# 检查主机名
hostname = socket.gethostname()
print_info(f"主机名: {hostname}")

try:
    # 连接到已经存在的Ray集群
    print_info(f"连接到Ray集群: {args.ray_address}")
    ray.init(address=args.ray_address, namespace="vllm", ignore_reinit_error=True)
    print_success(f"成功连接到Ray集群")
    
    # 获取集群资源信息
    cluster_resources = ray.cluster_resources()
    total_gpus = int(cluster_resources.get('GPU', 0))
    print_info("Ray集群资源:")
    print_info(f"- 总CPU: {int(cluster_resources.get('CPU', 0))}")
    print_info(f"- 总GPU: {total_gpus}")
    print_info(f"- 总内存: {cluster_resources.get('memory', 0) / (1024**3):.1f} GB")
    
    # 简化张量并行度检查
    if total_gpus < args.tensor_parallel_size:
        print_warning(f"集群中只有 {total_gpus} 个GPU，但张量并行度设置为 {args.tensor_parallel_size}")
        print_warning(f"继续运行，但可能会因资源不足而失败")

    # 如果需要，关闭已有部署
    if not args.no_shutdown:
        try:
            serve.delete(args.app_name)
            print_info(f"已关闭已有 {args.app_name} 部署")
        except Exception as e:
            # 如果部署不存在，忽略错误
            pass

    # 启动Ray Serve
    serve.start(http_options={"host": "0.0.0.0", "port": args.port}, detached=True)
    print_success(f"Ray Serve 启动成功，监听端口 {args.port}")

    # 导入模型相关库
    try:
        from vllm import LLM, SamplingParams
        print_success("vLLM 导入成功")
    except ImportError as e:
        print_error(f"导入 vLLM 失败: {str(e)}")
        print_warning("请安装支持AMD的vLLM版本")
        sys.exit(1)

    # 为张量并行处理设置更多资源
    deployment_kwargs = {
        "num_replicas": args.num_replicas,
        "ray_actor_options": {"num_gpus": args.num_gpus},
    }
    
    # 对于大规模分布式推理的资源设置
    if args.distributed:
        try:
            available_gpus = torch.cuda.device_count()
        except:
            available_gpus = 0
            
        if args.tensor_parallel_size > available_gpus:
            deployment_kwargs["ray_actor_options"].update({
                "resources": {"worker_group": 1},  # 帮助Ray在多个节点上分配资源
            })

    @serve.deployment(**deployment_kwargs)
    class DeepSeekInt4AMD:
        def __init__(self):
            """初始化DeepSeek模型服务（AMD版本）"""
            self.model_path = args.model_path
            self.device = "cuda"
            self.request_counter = 0
            self.hostname = socket.gethostname()
            self.model_id = str(uuid.uuid4())[:8]
            self.max_concurrent_queries = args.max_concurrent_queries
            self.semaphore = asyncio.Semaphore(self.max_concurrent_queries)
            
            try:
                print_info(f"正在加载模型: {self.model_path}")
                print_info(f"设备: {self.device}")
                print_info(f"最大并发请求数: {self.max_concurrent_queries}")
                
                # 配置张量并行参数
                tp_size = args.tensor_parallel_size
                print_info(f"设置张量并行度: {tp_size}")
                
                # 分布式模式下的优化选项
                load_kwargs = {}
                if args.distributed:
                    load_kwargs.update({
                        "quantization": "awq",           # 使用AWQ量化
                        "block_size": 16,                # 增大块大小以提高吞吐量
                        "gpu_memory_utilization": 0.92,  # 使用更多GPU内存
                        "max_model_len": 32768,          # 支持更长的上下文
                        "enforce_eager": True,           # 在分布式环境中更可靠
                        "enable_lora": False,            # 禁用LoRA以提高性能
                    })
                else:
                    load_kwargs.update({
                        "gpu_memory_utilization": 0.95, 
                        "max_model_len": 16384,
                        "enforce_eager": True,
                        "enable_lora": False,
                    })
                
                # 加载模型 (适用于大规模分布式部署)
                self.model = LLM(
                    model=self.model_path,
                    tensor_parallel_size=tp_size,
                    trust_remote_code=True,
                    dtype="auto",
                    **load_kwargs
                )
                
                print_success(f"模型加载成功：{self.model_path}")
                print_success(f"使用张量并行度: {tp_size}，跨机器分布式推理启用")
                self.model_loaded = True
            except Exception as e:
                print_error(f"加载模型时出错: {str(e)}")
                # 设置标志以便后续请求知道模型未加载
                self.model_loaded = False
        
        async def __call__(self, request):
            """处理API请求"""
            # 增加请求计数器
            self.request_counter += 1
            request_id = str(uuid.uuid4())
            start_time = time.time()
            
            if not self.model_loaded:
                return {
                    "error": "Model failed to load. Check server logs for details.",
                    "status_code": 500
                }
            
            # 使用信号量控制并发请求数
            async with self.semaphore:
                # 解析请求数据
                try:
                    if isinstance(request, dict):
                        data = request
                    else:
                        data = await request.json()
                    
                    # 获取请求参数
                    prompt = data.get("prompt", "")
                    max_tokens = data.get("max_tokens", 1024)
                    temperature = data.get("temperature", 0.7)
                    top_p = data.get("top_p", 0.9)
                    top_k = data.get("top_k", 40)
                    
                    # 验证请求
                    if not prompt:
                        return {
                            "error": "Prompt is required",
                            "status_code": 400
                        }
                    
                    # 记录请求信息（调试模式）
                    if args.debug:
                        print_info(f"Request #{self.request_counter} [{request_id}]")
                        print_info(f"Prompt: {prompt[:50]}...")
                        print_info(f"Max Tokens: {max_tokens}")
                        print_info(f"Temperature: {temperature}")
                    
                    # 创建采样参数
                    sampling_params = SamplingParams(
                        temperature=temperature,
                        top_p=top_p,
                        top_k=top_k,
                        max_tokens=max_tokens,
                    )
                    
                    # 生成回复
                    print_info(f"开始生成文本 [{request_id}]")
                    outputs = self.model.generate(prompt, sampling_params)
                    
                    # 处理结果
                    if outputs and len(outputs) > 0:
                        generated_text = outputs[0].outputs[0].text.strip()
                        prompt_tokens = outputs[0].prompt_token_ids
                        completion_tokens = outputs[0].outputs[0].token_ids
                        
                        # 构建响应
                        response = {
                            "id": request_id,
                            "model": "DeepSeek-R1-Int4-AWQ-AMD",
                            "node": self.hostname,
                            "instance": self.model_id,
                            "choices": [
                                {
                                    "text": generated_text,
                                    "index": 0,
                                    "finish_reason": "stop"
                                }
                            ],
                            "usage": {
                                "prompt_tokens": len(prompt_tokens),
                                "completion_tokens": len(completion_tokens),
                                "total_tokens": len(prompt_tokens) + len(completion_tokens)
                            }
                        }
                        
                        end_time = time.time()
                        print_success(f"生成完成 [{request_id}], 耗时: {end_time - start_time:.2f}秒")
                        
                        return response
                    else:
                        print_error(f"生成结果为空 [{request_id}]")
                        return {
                            "error": "Generated text is empty",
                            "status_code": 500
                        }
                        
                except Exception as e:
                    print_error(f"处理请求时出错: {str(e)}")
                    return {
                        "error": str(e),
                        "status_code": 500
                    }

    # 部署模型服务
    print_info(f"正在部署 {args.app_name}...")
    DeepSeekInt4AMD.deploy()
    print_success(f"模型服务 {args.app_name} 部署成功")
    
    # 打印服务URL
    print_success(f"服务已启动: http://localhost:{args.port}/")
    print_info("您可以使用以下命令测试服务:")
    print_info(f"curl -X POST http://localhost:{args.port}/ -H 'Content-Type: application/json' -d '{{\"prompt\":\"你好，请介绍一下自己\",\"max_tokens\":1000}}'")
    
    # 保持脚本运行
    while True:
        time.sleep(60)
        
except KeyboardInterrupt:
    print_info("接收到中断信号，正在退出...")
    sys.exit(0)
    
except Exception as e:
    print_error(f"启动服务时出错: {str(e)}")
    sys.exit(1) 