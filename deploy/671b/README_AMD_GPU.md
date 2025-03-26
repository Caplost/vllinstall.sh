# DeepSeek-R1-Int4-AWQ 在 AMD/海光 GPU 上的部署指南

本文档提供在搭载 AMD/海光 GPU 的服务器上部署 DeepSeek-R1-Int4-AWQ 模型的详细指南。

## 目录

- [环境要求](#环境要求)
- [部署步骤](#部署步骤)
- [常见问题解决](#常见问题解决)
- [性能优化](#性能优化)
- [完整参数说明](#完整参数说明)

## 环境要求

要在 AMD/海光 GPU 上成功部署 DeepSeek 模型，需要满足以下条件：

1. **硬件要求**：
   - AMD GPU 或海光 GPU
   - 至少 64GB 系统内存
   - 建议使用 NVMe SSD 存储
   
2. **软件环境**：
   - Ubuntu 20.04/22.04 或类似的 Linux 发行版
   - ROCm 5.4.0 或更高版本 (AMD GPU 专用运行时)
   - Python 3.8 或更高版本
   - 支持 ROCm 的 PyTorch 2.0 或更高版本

3. **ROCm 环境设置**：
   - 确保已正确安装 ROCm 运行时
   - 添加当前用户到 `render` 和 `video` 组以获取 GPU 访问权限

## 部署步骤

### 1. 准备 ROCm 环境

在海光/AMD GPU 服务器上，首先需要安装 ROCm 环境：

```bash
# 添加 ROCm 软件源（根据您的发行版选择合适的命令）
wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | sudo apt-key add -
echo 'deb [arch=amd64] https://repo.radeon.com/rocm/apt/debian/ xenial main' | sudo tee /etc/apt/sources.list.d/rocm.list

# 更新软件包列表并安装 ROCm
sudo apt update
sudo apt install rocm-dev

# 添加当前用户到必要的组
sudo usermod -a -G render,video $USER

# 设置环境变量
echo 'export PATH=$PATH:/opt/rocm/bin:/opt/rocm/hip/bin' >> ~/.bashrc
echo 'export HSA_OVERRIDE_GFX_VERSION=10.3.0' >> ~/.bashrc
source ~/.bashrc
```

### 2. 安装 PyTorch 和依赖项

```bash
# 安装 PyTorch ROCm 版本
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm5.4.2

# 安装必要的依赖
pip install ray[default]==2.5.1
pip install vllm==0.2.0
pip install fastapi uvicorn requests
```

### 3. 下载并部署模型

将模型文件放置在 `/home/models/DeepSeek-R1-Int4-AWQ` 目录下，或指定您自己的路径。

使用我们提供的 AMD GPU 专用脚本启动模型服务：

```bash
cd deploy/671b

# 使用基本配置启动
bash start_deepseek_int4_amd.sh

# 如果要指定自定义路径，使用以下命令
bash start_deepseek_int4_amd.sh --model-path /path/to/your/model
```

### 4. 测试部署的模型

部署完成后，使用测试脚本验证服务是否正常运行：

```bash
# 使用默认参数进行测试
python test_deepseek_int4.py

# 自定义测试参数
python test_deepseek_int4.py --url http://localhost:8000/ --prompt "用中文解释量子计算的基本原理" --max-tokens 2000
```

## 常见问题解决

### 1. "找不到 NVIDIA 驱动" 错误

如果出现 `Found no NVIDIA driver on your system` 错误，说明您的环境正在尝试使用 CUDA 而非 ROCm。解决方法：

```bash
# 使用 AMD 专用脚本
bash start_deepseek_int4_amd.sh

# 如果仍有问题，确保启用 CUDA 兼容层
bash start_deepseek_int4_amd.sh --use-cuda-compat
```

### 2. "模型架构检查失败" 错误

如果出现 `Error in inspecting model architecture` 错误，尝试：

```bash
# 启用调试模式查看详细错误
bash start_deepseek_int4_amd.sh --debug

# 如果持续失败，尝试 CPU 模式（不推荐生产环境使用）
bash start_deepseek_int4_amd.sh --cpu-only
```

### 3. 内存不足或 OOM 错误

```bash
# 降低 GPU 内存利用率
bash start_deepseek_int4_amd.sh --model-path <您的模型路径> --ray_actor_option="{\"object_store_memory\": 10000000000, \"memory\": 10000000000}"
```

## 性能优化

### 1. 多 GPU 设置

在多 GPU 环境中，您可以通过设置 `HIP_VISIBLE_DEVICES` 来控制使用哪些 GPU：

```bash
bash start_deepseek_int4_amd.sh --hip-visible-devices 0,1,2,3
```

### 2. 张量并行度调整

根据您的 GPU 数量和模型大小调整张量并行度：

```bash
# 使用 4 张 GPU 进行张量并行
bash start_deepseek_int4_amd.sh --total-gpus 4
```

## 完整参数说明

`start_deepseek_int4_amd.sh` 脚本支持以下参数：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--model-path` | 模型路径 | /home/models/DeepSeek-R1-Int4-AWQ |
| `--tokenizer-path` | 分词器路径 | /home/models/DeepSeek-R1-Int4-AWQ |
| `--dtype` | 数据类型 | int4 |
| `--quantization` | 量化方法 | awq |
| `--app-name` | 应用名称 | deepseek_r1_int4 |
| `--route-prefix` | 路由前缀 | / |
| `--no-shutdown` | 不关闭现有部署 | false |
| `--cpu-only` | 仅使用 CPU | false |
| `--debug` | 启用调试模式 | false |
| `--no-cuda-compat` | 禁用 CUDA 兼容层 | false |
| `--hip-visible-devices` | 指定可见的 HIP 设备 | 无 |
| `--rocm-device-map` | ROCm 设备映射 | auto |

## 停止服务

要停止运行中的服务，请使用以下命令：

```bash
python stop_deepseek_int4.py
```

如需更多技术支持，请参考 ROCm 官方文档和 DeepSeek 模型资源。 