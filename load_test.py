#!/usr/bin/env python3
import requests
import json
import time
import concurrent.futures
import argparse

def send_request(prompt, max_tokens=100):
    """发送请求到服务并测量响应时间"""
    url = "http://localhost:8000/"
    payload = {
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": 0.7
    }
    
    start_time = time.time()
    try:
        response = requests.post(url, json=payload)
        duration = time.time() - start_time
        
        if response.status_code == 200:
            result = response.json()
            return {
                "status": "success",
                "duration": duration,
                "tokens": result.get("usage", {}).get("total_tokens", 0)
            }
        else:
            return {
                "status": "error",
                "duration": duration,
                "error": f"Status code: {response.status_code}"
            }
    except Exception as e:
        duration = time.time() - start_time
        return {
            "status": "error",
            "duration": duration,
            "error": str(e)
        }

def run_load_test(concurrent_requests, total_requests, prompt_template):
    """运行负载测试"""
    print(f"开始负载测试: {concurrent_requests}个并发请求，总共{total_requests}个请求")
    
    prompts = [
        f"{prompt_template} {i}" for i in range(total_requests)
    ]
    
    results = []
    start_time = time.time()
    
    # 使用线程池并发发送请求
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrent_requests) as executor:
        futures = [executor.submit(send_request, prompt) for prompt in prompts]
        
        for i, future in enumerate(concurrent.futures.as_completed(futures)):
            result = future.result()
            results.append(result)
            
            # 定期打印进度
            if (i + 1) % 10 == 0 or i + 1 == total_requests:
                success_count = sum(1 for r in results if r["status"] == "success")
                avg_time = sum(r["duration"] for r in results) / len(results)
                print(f"进度: {i+1}/{total_requests}, 成功率: {success_count/(i+1):.2%}, 平均响应时间: {avg_time:.2f}秒")
    
    total_time = time.time() - start_time
    success_count = sum(1 for r in results if r["status"] == "success")
    
    # 汇总统计信息
    print("\n==== 测试结果汇总 ====")
    print(f"总请求数: {total_requests}")
    print(f"成功请求数: {success_count}")
    print(f"成功率: {success_count/total_requests:.2%}")
    print(f"总耗时: {total_time:.2f}秒")
    print(f"平均响应时间: {sum(r['duration'] for r in results) / len(results):.2f}秒")
    print(f"最短响应时间: {min(r['duration'] for r in results):.2f}秒")
    print(f"最长响应时间: {max(r['duration'] for r in results):.2f}秒")
    print(f"吞吐量: {total_requests/total_time:.2f} 请求/秒")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="LLM服务负载测试工具")
    parser.add_argument("-c", "--concurrent", type=int, default=20, help="并发请求数")
    parser.add_argument("-n", "--total", type=int, default=100, help="总请求数")
    parser.add_argument("-p", "--prompt", type=str, default="请用简短的语言解释量子物理学", help="提示词模板")
    
    args = parser.parse_args()
    run_load_test(args.concurrent, args.total, args.prompt) 