#!/usr/bin/env python3
import ray
from ray import serve
import argparse
import sys

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

def print_warning(text):
    print_colored(f"警告: {text}", YELLOW)

def print_info(text):
    print_colored(text, BLUE)

def print_success(text):
    print_colored(text, GREEN)

# 解析命令行参数
parser = argparse.ArgumentParser(description="Stop DeepSeek-R1-Int8 service")
parser.add_argument("--app-name", type=str, default="deepseek_r1_int8", help="Application name to stop")
args = parser.parse_args()

print_info("==== 停止 DeepSeek-R1-Channel-INT8 服务 ====")
print_info(f"准备停止应用: {args.app_name}")

try:
    # 初始化Ray
    ray.init(address="auto", namespace="vllm", ignore_reinit_error=True)
    print_info("Ray 初始化成功")
    
    # 停止服务
    print_info(f"正在停止 {args.app_name} 服务...")
    serve.delete(args.app_name)
    print_success(f"成功停止 {args.app_name} 服务")
    
except Exception as e:
    print_error(f"停止服务时出错: {str(e)}")
    sys.exit(1) 