#!/usr/bin/env python3
import ray
from ray import serve

# 连接到现有的Ray集群
ray.init(address="auto", namespace="vllm", ignore_reinit_error=True)

# 关闭特定的服务部署
serve.delete("vllm_service")

# 或者关闭所有Serve服务
serve.shutdown()

print("服务已停止") 