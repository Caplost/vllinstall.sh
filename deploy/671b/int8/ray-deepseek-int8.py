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

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger("DeepSeek-R1-Int8")

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
parser = argparse.ArgumentParser(description="Deploy DeepSeek-R1-Channel-INT8 model with Ray Serve")
parser.add_argument("--model-path", type=str, required=True, help="Path to the model directory")
parser.add_argument("--app-name", type=str, default="deepseek_r1_int8", help="Application name")
parser.add_argument("--port", type=int, default=8000, help="Port for the HTTP server")
parser.add_argument("--num-gpus", type=float, default=1, help="Number of GPUs to use per replica")
parser.add_argument("--num-replicas", type=int, default=1, help="Number of replicas to deploy")
parser.add_argument("--max-concurrent-queries", type=int, default=4, help="Maximum number of concurrent queries per worker")
parser.add_argument("--no-shutdown", action="store_true", help="Don't shut down existing deployments")
parser.add_argument("--debug", action="store_true", help="Enable debug mode")
args = parser.parse_args()

# 启用调试模式
if args.debug:
    logger.setLevel(logging.DEBUG)
    print_info("调试模式已启用")

# 显示参数
print_info(f"模型路径: {args.model_path}")
print_info(f"应用名称: {args.app_name}")
print_info(f"端口: {args.port}")
print_info(f"每个副本使用GPU数量: {args.num_gpus}")
print_info(f"副本数量: {args.num_replicas}")
print_info(f"每个工作进程最大并发查询数: {args.max_concurrent_queries}")
print_info(f"不关闭已有部署: {args.no_shutdown}")

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

# 检查是否有GPU可用
if not torch.cuda.is_available():
    print_error("检测不到CUDA GPU。INT8模型需要GPU才能运行。")
    print_error("如果有GPU但检测不到，请检查CUDA环境配置。")
    sys.exit(1)

# 检查可用的GPU数量
available_gpus = torch.cuda.device_count()
print_info(f"检测到 {available_gpus} 个GPU")
if available_gpus < args.num_gpus * args.num_replicas:
    print_warning(f"配置请求 {args.num_gpus * args.num_replicas} GPU，但只有 {available_gpus} 个可用")
    print_warning(f"将GPU数量限制为每个副本 {available_gpus / args.num_replicas}")
    args.num_gpus = min(args.num_gpus, available_gpus / args.num_replicas)

# 检查主机名
hostname = socket.gethostname()
print_info(f"主机名: {hostname}")

try:
    # 初始化Ray，如果已经初始化则忽略错误
    ray.init(address="auto", namespace="vllm", ignore_reinit_error=True)
    print_success("Ray 初始化成功")

    # 如果需要，关闭已有部署
    if not args.no_shutdown:
        try:
            serve.delete(args.app_name)
            print_info(f"已关闭已有 {args.app_name} 部署")
        except Exception as e:
            # 如果部署不存在，忽略错误
            pass

    # 启动Ray Serve
    serve.start(http_options={"host": "0.0.0.0", "port": args.port})
    print_success(f"Ray Serve 启动成功，监听端口 {args.port}")

    # 导入模型相关库
    try:
        from vllm import LLM, SamplingParams
        print_success("vLLM 导入成功")
    except ImportError as e:
        print_error(f"导入 vLLM 失败: {str(e)}")
        print_warning("请安装 vLLM: pip install vllm")
        sys.exit(1)

    @serve.deployment(
        num_replicas=args.num_replicas,
        ray_actor_options={"num_gpus": args.num_gpus},
        max_concurrent_queries=args.max_concurrent_queries
    )
    class DeepSeekInt8:
        def __init__(self):
            """初始化DeepSeek模型服务"""
            self.model_path = args.model_path
            self.device = "cuda"
            self.request_counter = 0
            self.hostname = socket.gethostname()
            self.model_id = str(uuid.uuid4())[:8]
            
            try:
                print_info(f"正在加载模型: {self.model_path}")
                print_info(f"设备: {self.device}")
                
                # 加载模型
                self.model = LLM(
                    model=self.model_path,
                    tensor_parallel_size=int(args.num_gpus),
                    trust_remote_code=True,
                    dtype="int8",  # INT8量化
                    gpu_memory_utilization=0.9,
                    max_model_len=4096,  # 根据您的资源调整
                )
                
                print_success(f"模型加载成功：{self.model_path}")
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
                        "model": "DeepSeek-R1-Channel-INT8",
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
    DeepSeekInt8.deploy()
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