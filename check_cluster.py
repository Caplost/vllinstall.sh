#!/usr/bin/env python3
import ray
import time
import os

# 连接到Ray集群
ray.init(address="auto", namespace="vllm", ignore_reinit_error=True)

# 打印集群信息
print("==== Ray集群信息 ====")
print(f"节点数量: {len(ray.nodes())}")
for i, node in enumerate(ray.nodes()):
    print(f"节点 {i+1}:")
    print(f"  节点ID: {node['NodeID']}")
    print(f"  IP地址: {node['NodeManagerAddress']}")
    print(f"  可用资源: {node['Resources']}")
    print(f"  GPU数量: {node['Resources'].get('GPU', 0)}")

# 检查服务实例
from ray import serve

print("\n==== Ray Serve部署信息 ====")
status = serve.status()
for deployment_name, deployment_info in status.applications.items():
    print(f"应用: {deployment_name}")
    for deployment, info in deployment_info.deployments.items():
        print(f"  部署: {deployment}")
        print(f"  状态: {info.status}")
        print(f"  副本数: {info.num_replicas}")

# 可选：强制在所有节点上创建副本（谨慎使用）
def force_replicas():
    print("\n尝试强制在所有节点上创建副本...")
    
    @ray.remote(num_gpus=8)
    class DummyActor:
        def __init__(self):
            self.node_id = ray.get_runtime_context().get_node_id()
            print(f"创建了一个Actor在节点: {self.node_id}")
        
        def get_node_id(self):
            return self.node_id
    
    # 尝试创建多个Actor，它们会被分布到不同节点上
    actors = [DummyActor.remote() for _ in range(len(ray.nodes()))]
    node_ids = ray.get([actor.get_node_id.remote() for actor in actors])
    print(f"成功创建Actor的节点: {node_ids}")

# 取消注释下面的行来启用强制创建副本
# force_replicas()

print("\n查看Ray仪表盘或运行 'ray status' 获取更多信息") 