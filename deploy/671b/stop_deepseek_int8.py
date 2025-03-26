#!/usr/bin/env python3
import ray
from ray import serve
import argparse

# 解析命令行参数
parser = argparse.ArgumentParser(description="Stop DeepSeek-R1-Channel-INT8 service")
parser.add_argument("--app-name", type=str, default="deepseek_r1_int8", help="Application name to stop")
args = parser.parse_args()

# 初始化Ray
ray.init(address="auto", namespace="vllm")

try:
    # 尝试删除服务
    print(f"正在停止服务: {args.app_name}")
    serve.delete(args.app_name)
    print(f"服务 {args.app_name} 已成功停止")
except Exception as e:
    print(f"停止服务时出错: {str(e)}") 