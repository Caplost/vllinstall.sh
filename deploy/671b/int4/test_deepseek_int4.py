#!/usr/bin/env python3
import argparse
import requests
import json
import time
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
parser = argparse.ArgumentParser(description="Test DeepSeek-R1-Int4-AWQ service")
parser.add_argument("--url", type=str, default="http://localhost:8000/", help="Service URL (default: http://localhost:8000/)")
parser.add_argument("--prompt", type=str, default="你好，请介绍一下自己", help="Prompt text")
parser.add_argument("--max-tokens", type=int, default=1000, help="Maximum tokens to generate (default: 1000)")
parser.add_argument("--temperature", type=float, default=0.7, help="Temperature for sampling (default: 0.7)")
parser.add_argument("--model", type=str, default="DeepSeek-R1-Int4-AWQ", help="Model name to report in the request")
parser.add_argument("--times", type=int, default=1, help="Number of times to run the test (default: 1)")
args = parser.parse_args()

# 确保URL格式正确
if not args.url.startswith("http"):
    args.url = "http://" + args.url
if args.url.endswith("/"):
    url = args.url
else:
    url = args.url + "/"

print_info("==== DeepSeek-R1-Int4-AWQ 测试工具 ====")
print_info(f"服务URL: {url}")
print_info(f"提示词: {args.prompt}")
print_info(f"最大生成Token数: {args.max_tokens}")
print_info(f"温度: {args.temperature}")
print_info(f"测试次数: {args.times}")

# 构建请求数据
request_data = {
    "prompt": args.prompt,
    "max_tokens": args.max_tokens,
    "temperature": args.temperature,
    "model": args.model
}

print_info("\n请求数据:")
print_info(json.dumps(request_data, ensure_ascii=False, indent=2))

# 运行测试
total_time = 0
successful_tests = 0

for i in range(args.times):
    print_info(f"\n==== 测试 {i+1}/{args.times} ====")
    start_time = time.time()
    
    try:
        print_info("发送请求...")
        response = requests.post(
            url,
            json=request_data,
            headers={"Content-Type": "application/json"},
            timeout=120  # 120秒超时
        )
        
        end_time = time.time()
        test_time = end_time - start_time
        total_time += test_time
        
        if response.status_code == 200:
            print_success(f"请求成功 (HTTP {response.status_code})，耗时: {test_time:.2f}秒")
            successful_tests += 1
            
            # 解析响应
            try:
                response_data = response.json()
                
                print_info("\n响应数据:")
                # 显示基本信息
                print_info(f"ID: {response_data.get('id', 'N/A')}")
                print_info(f"模型: {response_data.get('model', 'N/A')}")
                print_info(f"节点: {response_data.get('node', 'N/A')}")
                
                # 显示用量信息
                usage = response_data.get("usage", {})
                if usage:
                    print_info(f"输入Token数: {usage.get('prompt_tokens', 'N/A')}")
                    print_info(f"输出Token数: {usage.get('completion_tokens', 'N/A')}")
                    print_info(f"总Token数: {usage.get('total_tokens', 'N/A')}")
                
                # 显示生成的文本
                choices = response_data.get("choices", [])
                if choices and len(choices) > 0:
                    generated_text = choices[0].get("text", "")
                    print_success("\n生成的文本:")
                    print(generated_text)
                else:
                    print_warning("响应中没有找到生成的文本")
                
            except json.JSONDecodeError:
                print_error("无法解析JSON响应")
                print_info("原始响应:")
                print(response.text)
        else:
            print_error(f"请求失败 (HTTP {response.status_code})，耗时: {test_time:.2f}秒")
            print_error(f"错误信息: {response.text}")
    
    except requests.exceptions.RequestException as e:
        print_error(f"发送请求时出错: {str(e)}")
    
    # 多次测试之间添加短暂延迟
    if i < args.times - 1:
        time.sleep(1)

# 打印总结
print_info("\n==== 测试总结 ====")
print_info(f"成功测试: {successful_tests}/{args.times}")
if args.times > 0:
    avg_time = total_time / args.times
    print_info(f"平均响应时间: {avg_time:.2f}秒")
    
    if successful_tests == args.times:
        print_success("所有测试均成功完成！")
    elif successful_tests > 0:
        print_warning(f"部分测试成功 ({successful_tests}/{args.times})")
    else:
        print_error("所有测试均失败") 