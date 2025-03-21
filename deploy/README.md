# Ray VLLM 服务部署指南

这个目录包含了基于Ray和VLLM的大语言模型服务部署脚本。以下是各个脚本的介绍和使用方法。

## 脚本说明

### 1. 原始服务脚本 (`ray-product`)

这是原始的服务部署脚本，使用自动扩展配置。当服务负载较大时，理论上应该触发自动扩展创建新副本，但在实际环境中可能不会扩展到第二台机器。

```bash
python ray-product
```

### 2. 强制多副本部署 (`ray-force-multi.py`)

这个脚本直接指定创建固定数量的副本（2个），强制Ray将副本分布到不同节点上。这是最简单直接的解决方案，每个副本会使用8个GPU（张量并行）。

```bash
python ray-force-multi.py
```

- 指定了 `num_replicas=2`，直接创建2个副本
- 每个副本需要8个GPU，Ray调度器会将它们自动分配到不同节点
- 使用张量并行（tensor_parallel_size=8）将模型分散到8个GPU上运行

### 3. 单GPU高密度部署 (`ray-single-gpu.py`) 

**适用于64GB显存GPU**的部署方案，在每个GPU上加载完整的模型，创建最多16个副本（每个节点8个）。

```bash
python ray-single-gpu.py
```

- 每个GPU加载完整的模型（不使用张量并行）
- 针对64GB显存进行了内存优化
- 支持更高的并发请求处理
- **注意：** 此方案仅适用于A100-80G或H100等大显存GPU

### 4. 使用Placement Group的部署 (`ray-placement-group.py`)

这个脚本使用Ray的Placement Group功能，显式指定资源在不同节点上的分布，并创建两个独立的部署实例，确保它们分别在不同节点上运行。

```bash
python ray-placement-group.py
```

- 创建一个跨节点的Placement Group
- 定义两个部署类，分别绑定到不同的bundle
- 使用路由器将请求轮询分发到两个部署

## 选择部署方案

| 部署方案 | 使用场景 | GPU需求 | 并发处理能力 |
|---------|---------|---------|------------|
| ray-force-multi.py | 通用场景，确保使用所有节点 | 每个副本8个GPU | 中等 |
| ray-single-gpu.py | 大显存GPU (64GB+) | 每个副本1个GPU | 高 |
| ray-placement-group.py | 需要精确控制资源分配 | 每个副本8个GPU | 中等 |

## 辅助工具

### 1. 集群状态检查 (`check_cluster.py`)

检查Ray集群状态，显示节点信息和资源分配情况，以及服务副本信息。

```bash
python check_cluster.py
```

### 2. 负载测试 (`load_test.py`)

模拟高并发请求，测试服务性能和负载均衡效果。

```bash
# 默认：20个并发请求，共100个请求
python load_test.py

# 自定义参数
python load_test.py -c 30 -n 150 -p "请简要解释相对论"
```

### 3. 停止服务 (`stop_service.py`)

优雅地停止Ray Serve服务。

```bash
python stop_service.py
```

## 故障排除

如果在使用过程中遇到问题，可以尝试以下步骤：

1. 检查集群状态：`ray status -v`
2. 检查节点资源分配：`python check_cluster.py`
3. 根据GPU显存大小选择合适的部署方案：
   - 常规GPU (16-32GB): 使用 `ray-force-multi.py`（张量并行）
   - 大显存GPU (64GB+): 可以尝试 `ray-single-gpu.py`（单GPU加载完整模型）
4. 观察日志中的错误信息，常见问题及解决方案：
   - `No available memory for the cache blocks`: 
     - 使用更小的 `max_tokens` 值
     - 降低 `gpu_memory_utilization` 
     - 考虑使用张量并行而不是单GPU部署

## 服务API

服务启动后，可以通过HTTP请求访问。示例：

```bash
curl -X POST http://localhost:8000/ \
  -H "Content-Type: application/json" \
  -d '{"prompt": "请简要介绍人工智能的发展历史", "max_tokens": 500}'
```

响应格式：
```json
{
  "id": "cmpl-1234567890",
  "object": "text_completion",
  "created": 1234567890,
  "model": "DeepSeek-R1",
  "node": "节点ID",
  "choices": [{"text": "生成的文本", "index": 0, "finish_reason": "stop"}],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 100,
    "total_tokens": 110
  }
}
``` 