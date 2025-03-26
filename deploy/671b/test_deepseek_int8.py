#!/usr/bin/env python3
import requests
import json
import time
import argparse

# 解析命令行参数
parser = argparse.ArgumentParser(description="Test DeepSeek-R1-Channel-INT8 service")
parser.add_argument("--host", type=str, default="localhost", help="Host address (default: localhost)")
parser.add_argument("--port", type=int, default=8000, help="Port number (default: 8000)")
parser.add_argument("--route-prefix", type=str, default="/", help="URL route prefix (default: /)")
parser.add_argument("--prompt", type=str, default="你好，请介绍一下自己", help="Prompt to send to the model")
parser.add_argument("--max-tokens", type=int, default=1000, help="Maximum tokens to generate (default: 1000)")
parser.add_argument("--temperature", type=float, default=0.7, help="Sampling temperature (default: 0.7)")
args = parser.parse_args()

# 构建URL
url = f"http://{args.host}:{args.port}{args.route_prefix}"

# 构建请求数据
data = {
    "prompt": args.prompt,
    "max_tokens": args.max_tokens,
    "temperature": args.temperature
}

print(f"发送请求到: {url}")
print(f"请求数据: {json.dumps(data, ensure_ascii=False)}")

# 发送请求
start_time = time.time()
try:
    response = requests.post(
        url,
        json=data,
        headers={"Content-Type": "application/json"}
    )
    
    elapsed_time = time.time() - start_time
    
    # 打印响应
    print(f"\n请求耗时: {elapsed_time:.2f}秒")
    print(f"状态码: {response.status_code}")
    
    if response.status_code == 200:
        response_json = response.json()
        print("\n响应内容:")
        print(json.dumps(response_json, ensure_ascii=False, indent=2))
        
        # 打印生成的文本
        if "choices" in response_json and len(response_json["choices"]) > 0:
            print("\n生成的回复:")
            print(response_json["choices"][0]["text"])
    else:
        print(f"错误: {response.text}")
except Exception as e:
    print(f"请求失败: {str(e)}") 