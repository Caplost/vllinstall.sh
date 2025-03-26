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

def check_model_directory(model_path):
    """检查模型目录结构，返回关键文件列表"""
    try:
        if not os.path.exists(model_path):
            return f"路径不存在: {model_path}"
        
        if not os.path.isdir(model_path):
            return f"不是目录: {model_path}"
        
        # 收集目录中的文件
        files = os.listdir(model_path)
        key_files = []
        
        # 检查关键文件
        if "config.json" in files:
            key_files.append("config.json")
        if "tokenizer.json" in files or "tokenizer_config.json" in files:
            key_files.append("tokenizer_config")
        
        # 检查模型文件
        model_files = [f for f in files if f.endswith(".safetensors") or f.endswith(".bin")]
        if model_files:
            key_files.append(f"模型文件: {len(model_files)}个")
        
        # 检查量化文件
        awq_files = [f for f in files if "awq" in f.lower()]
        if awq_files:
            key_files.append(f"AWQ文件: {len(awq_files)}个")
            
        return f"目录结构正常, 关键文件: {', '.join(key_files)}"
    except Exception as e:
        return f"检查目录时出错: {str(e)}"

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
parser.add_argument("--force-amd", action="store_true", help="Force AMD mode for ROCm/HIP GPUs")
args = parser.parse_args()

# 启用调试模式
if args.debug:
    logger.setLevel(logging.DEBUG)
    print_info("调试模式已启用")

# 处理自动GPU数量 - 简化处理，不进行详细检测
if args.num_gpus == "auto":
    try:
        # 检测AMD GPU而不是CUDA GPU
        if torch.cuda.is_available():
            available_gpus = torch.cuda.device_count()
            gpu_type = "CUDA"
        elif hasattr(torch, 'hip') and torch.hip.is_available():
            available_gpus = torch.hip.device_count()
            gpu_type = "HIP/ROCm"
        else:
            available_gpus = 0
            gpu_type = "未检测到"
            
        args.num_gpus = float(available_gpus) if available_gpus > 0 else 0
        print_info(f"GPU设置: {args.num_gpus} ({gpu_type})")
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
            # 检测AMD GPU而不是CUDA GPU
            if torch.cuda.is_available():
                available_gpus = torch.cuda.device_count()
            elif hasattr(torch, 'hip') and torch.hip.is_available():
                available_gpus = torch.hip.device_count()
            else:
                available_gpus = 0
        except:
            available_gpus = 0
            
        # 移除worker_group资源指定
        if args.tensor_parallel_size > available_gpus:
            print_info(f"张量并行度({args.tensor_parallel_size})大于可用GPU数量({available_gpus})，分布式模式已启用")
            # 不再指定worker_group资源

    @serve.deployment(**deployment_kwargs)
    class DeepSeekInt4AMD:
        def __init__(self):
            """初始化DeepSeek模型服务（AMD版本）"""
            self.model_path = args.model_path
            # 根据实际可用的设备设置或强制AMD设置
            if args.force_amd:
                # 强制使用AMD GPU
                self.device = "hip"
                self.device_type = "AMD (ROCm/HIP) [强制模式]"
            elif args.force_cpu:
                # 强制使用CPU
                self.device = "cpu"
                self.device_type = "CPU [强制模式]"
            elif torch.cuda.is_available():
                self.device = "cuda"
                self.device_type = "NVIDIA (CUDA)"
            elif hasattr(torch, 'hip') and torch.hip.is_available():
                self.device = "hip"
                self.device_type = "AMD (ROCm/HIP)"
            else:
                self.device = "cpu"
                self.device_type = "CPU (无GPU可用)"
            
            self.request_counter = 0
            self.hostname = socket.gethostname()
            self.model_id = str(uuid.uuid4())[:8]
            self.max_concurrent_queries = args.max_concurrent_queries
            self.semaphore = asyncio.Semaphore(self.max_concurrent_queries)
            
            try:
                print_info(f"正在加载模型: {self.model_path}")
                print_info(f"设备: {self.device} ({self.device_type})")
                print_info(f"最大并发请求数: {self.max_concurrent_queries}")
                
                # 检查模型目录结构
                model_dir_status = check_model_directory(self.model_path)
                print_info(f"模型目录检查: {model_dir_status}")
                
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
                
                # AMD GPU特定选项
                if self.device == "hip" or args.force_amd:
                    # AMD GPU特定的vLLM设置
                    print_info("应用AMD GPU特定设置")
                    load_kwargs.update({
                        "device": "rocm",            # 有些vLLM版本需要显式指定"rocm"
                        "use_amd": True,             # 启用AMD特定优化
                        "max_model_len": 16384,      # 对于AMD可能需要限制上下文长度
                        "gpu_memory_utilization": 0.85,  # AMD GPU通常需要更保守的内存设置
                        "enforce_eager": True,       # 对AMD GPU更重要
                        "trust_remote_code": True,   # 确保加载自定义代码
                        "tokenizer": None,           # 允许自动检测tokenizer
                        "tokenizer_mode": "auto",    # 自动选择tokenizer模式
                        "seed": 42,                  # 设置随机种子以确保一致性
                        "download_dir": None,        # 允许自动下载模型文件
                        "load_format": "auto",       # 自动检测模型格式
                    })
                    
                    # 添加DeepSeek模型特定参数
                    if "deepseek" in self.model_path.lower():
                        print_info("检测到DeepSeek模型，应用特定优化")
                        load_kwargs.update({
                            "model_type": "deepseek",    # 明确指定模型类型
                            "revision": "main",          # 使用主分支
                            "tokenizer_revision": "main",# 使用主分支的tokenizer
                            "disable_custom_all_reduce": True,  # 在某些环境中可能需要禁用自定义all_reduce
                        })
                
                # 加载模型 (适用于大规模分布式部署)
                # 根据设备类型选择适当的加载参数
                load_args = {
                    "model": self.model_path,
                    "tensor_parallel_size": tp_size,
                    "dtype": "auto",
                    "trust_remote_code": True,  # 确保这个参数在顶层设置
                }
                # 合并所有加载参数
                load_args.update(load_kwargs)
                
                # 添加额外的参数以支持自定义模型
                extra_params = {
                    "revision": "main",  # 尝试使用主分支
                    "download_dir": None,  # 允许自动下载
                    "load_format": "auto",  # 自动检测模型格式
                    "trust_remote_code": True,  # 再次确保这个参数设置正确
                }
                load_args.update(extra_params)
                
                # 实际加载模型
                try:
                    print_info(f"使用以下配置加载模型: {', '.join([f'{k}={v}' for k, v in load_args.items() if k != 'model'])}")
                    self.model = LLM(**load_args)
                    print_success(f"模型加载成功：{self.model_path}")
                    print_success(f"使用张量并行度: {tp_size}，跨机器分布式推理启用")
                    self.model_loaded = True
                except Exception as e:
                    import traceback
                    error_details = traceback.format_exc()
                    print_error(f"加载模型时出错: {str(e)}")
                    print_error(f"详细错误信息: {error_details}")
                    print_warning("尝试以不同方式加载模型...")
                    
                    try:
                        # 尝试使用更严格的参数加载
                        strict_load_args = {
                            "model": self.model_path,
                            "tensor_parallel_size": tp_size,
                            "dtype": "auto",
                            "trust_remote_code": True,
                            "device": "auto",
                            "revision": "main",
                            "tokenizer_revision": "main",
                            "quantization": "awq" if args.distributed else None,
                            "seed": 42,
                        }
                        print_info("使用严格参数重新尝试加载...")
                        self.model = LLM(**strict_load_args)
                        print_success(f"使用严格参数模型加载成功：{self.model_path}")
                        print_success(f"使用张量并行度: {tp_size}")
                        self.model_loaded = True
                    except Exception as retry_error:
                        print_error(f"重试加载模型时出错: {str(retry_error)}")
                        print_warning("尝试最后的备选方案...")
                        
                        try:
                            # 如果模型路径看起来像Hugging Face ID，尝试直接从Hugging Face加载
                            if os.path.isdir(self.model_path) and not self.model_path.startswith(("/", ".")):
                                print_info(f"尝试将 {self.model_path} 视为Hugging Face模型ID直接加载")
                            
                            # 尝试最小化参数加载
                            minimal_args = {
                                "model": self.model_path,
                                "trust_remote_code": True,
                                "tensor_parallel_size": 1 if tp_size > 4 else tp_size,  # 减少张量并行度
                                "dtype": "half",  # 使用半精度
                                "max_model_len": 8192,  # 减少上下文长度
                                "quantization": None,  # 禁用量化
                            }
                            
                            print_info("使用最小化参数尝试加载...")
                            self.model = LLM(**minimal_args)
                            print_success(f"使用最小化参数成功加载模型：{self.model_path}")
                            self.model_loaded = True
                        except Exception as last_error:
                            print_error(f"所有加载尝试均失败: {str(last_error)}")
                            self.model_loaded = False
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
    # 使用新版Ray Serve API部署服务
    serve.run(DeepSeekInt4AMD.bind(), name=args.app_name)
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