#!/usr/bin/env python3
import os
import sys
import ray
from ray import serve
import argparse
import logging
import time
import socket

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger("DeepSeek-R1-Int4-AMD-Stop")

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
parser = argparse.ArgumentParser(description="Stop DeepSeek-R1-Int4-AWQ Ray Serve Deployment")
parser.add_argument("--app-name", type=str, default="deepseek_r1_int4_amd", help="Application name to stop")
parser.add_argument("--ray-address", type=str, default="auto", help="Ray cluster address")
parser.add_argument("--force", action="store_true", help="Force shutdown even if errors occur")
parser.add_argument("--shutdown-ray", action="store_true", help="Shutdown Ray cluster after stopping deployment")
args = parser.parse_args()

# 检查主机名
hostname = socket.gethostname()
print_info(f"主机名: {hostname}")

try:
    # 连接到Ray集群
    print_info(f"连接到Ray集群: {args.ray_address}")
    ray.init(address=args.ray_address, namespace="vllm", ignore_reinit_error=True)
    print_success(f"成功连接到Ray集群")
    
    # 检查应用是否存在
    try:
        deployments = serve.list_deployments()
        if args.app_name in deployments:
            print_info(f"找到应用 {args.app_name}，准备停止...")
        else:
            print_warning(f"应用 {args.app_name} 未找到，可能已经停止")
            if not args.force:
                print_info("使用 --force 参数强制继续操作")
                sys.exit(0)
    except Exception as e:
        print_warning(f"检查应用状态时出错: {str(e)}")
        if not args.force:
            print_error("检查失败，使用 --force 参数强制继续操作")
            sys.exit(1)
    
    # 停止Ray Serve应用
    try:
        print_info(f"正在停止应用 {args.app_name}...")
        serve.delete(args.app_name)
        print_success(f"应用 {args.app_name} 已成功停止")
    except Exception as e:
        print_error(f"停止应用时出错: {str(e)}")
        if not args.force:
            sys.exit(1)
    
    # 根据参数决定是否关闭Ray集群
    if args.shutdown_ray:
        print_info("正在关闭Ray集群...")
        try:
            ray.shutdown()
            print_success("Ray集群已关闭")
        except Exception as e:
            print_error(f"关闭Ray集群时出错: {str(e)}")
            if not args.force:
                sys.exit(1)
    else:
        print_info("保留Ray集群运行状态")
    
    print_success("停止操作完成")

except KeyboardInterrupt:
    print_info("接收到中断信号，正在退出...")
    sys.exit(0)
    
except Exception as e:
    print_error(f"停止服务时出错: {str(e)}")
    sys.exit(1) 