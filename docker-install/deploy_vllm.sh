#!/bin/bash
# vllm+Ray 多机多卡一体化部署脚本
# 使用方法:
# 1. 在头节点上运行: ./deploy_vllm.sh head <头节点IP>
# 2. 在工作节点上运行: ./deploy_vllm.sh worker <头节点IP> <工作节点IP>
# 3. 下载模型: ./deploy_vllm.sh model-download <模型ID> [来源]
# 4. 启动服务: ./deploy_vllm.sh start-service <模型名称> [TP大小]
# 5. 查看状态: ./deploy_vllm.sh status

set -e

# 脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# 加载配置文件
CONFIG_FILE="${SCRIPT_DIR}/config.env"
if [ -f "$CONFIG_FILE" ]; then
    echo "加载配置文件: $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "错误: 配置文件不存在: $CONFIG_FILE"
    echo "请先创建配置文件，可以从模板复制: cp config.env.template config.env"
    exit 1
fi

# 命令行参数
COMMAND=$1
shift

# 功能：检查必要的配置
check_config() {
    local missing_vars=()
    
    # 检查基础配置
    [ -z "$BASE_IMAGE" ] && missing_vars+=("BASE_IMAGE")
    [ -z "$CONTAINER_PREFIX" ] && missing_vars+=("CONTAINER_PREFIX")
    [ -z "$PROJECT_PATH" ] && missing_vars+=("PROJECT_PATH")
    [ -z "$MODEL_PATH" ] && missing_vars+=("MODEL_PATH")
    [ -z "$SHM_SIZE" ] && missing_vars+=("SHM_SIZE")
    
    # 如果有缺失的变量
    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "错误: 配置文件中缺少以下必要变量:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        echo "请编辑配置文件: $CONFIG_FILE"
        exit 1
    fi
    
    # 检查目录
    if [ ! -d "$PROJECT_PATH" ]; then
        echo "警告: 项目目录不存在: $PROJECT_PATH"
        read -p "是否创建此目录? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            mkdir -p "$PROJECT_PATH"
            echo "已创建目录: $PROJECT_PATH"
        else
            echo "请手动创建目录后再运行此脚本"
            exit 1
        fi
    fi
    
    if [ ! -d "$MODEL_PATH" ]; then
        echo "警告: 模型目录不存在: $MODEL_PATH"
        read -p "是否创建此目录? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            mkdir -p "$MODEL_PATH"
            echo "已创建目录: $MODEL_PATH"
        else
            echo "请手动创建目录后再运行此脚本"
            exit 1
        fi
    fi
}

# 功能：部署头节点
deploy_head() {
    local HEAD_IP=$1
    
    if [ -z "$HEAD_IP" ]; then
        echo "错误: 未提供头节点IP"
        echo "用法: $0 head <头节点IP>"
        exit 1
    fi
    
    echo "开始部署头节点: $HEAD_IP"
    
    # 拉取基础镜像
    echo "拉取基础镜像: $BASE_IMAGE"
    docker pull $BASE_IMAGE
    
    # 获取镜像ID
    IMAGE_ID=$(docker images -q $BASE_IMAGE)
    if [ -z "$IMAGE_ID" ]; then
        echo "错误: 无法获取镜像ID"
        exit 1
    fi
    echo "获取到镜像ID: $IMAGE_ID"
    
    # 创建安装脚本
    create_install_script
    
    # 创建头节点启动脚本
    CONTAINER_NAME="${CONTAINER_PREFIX}-head"
    
    cat > start_ray_head.sh << EOF
#!/bin/bash
set -e

# 获取所有可用的GPU设备
GPU_DEVICES=\$(ls /dev/dri/renderD* 2>/dev/null | wc -l || echo "0")
echo "检测到 \$GPU_DEVICES 个GPU设备"

# 启动Ray头节点
echo "启动Ray头节点..."
ray start --head \\
    --port=${RAY_PORT} \\
    --dashboard-port=${DASHBOARD_PORT} \\
    --dashboard-host=0.0.0.0 \\
    --num-gpus=\$GPU_DEVICES \\
    --block

# 这句不会执行，因为ray start --block会阻塞
echo "Ray头节点已启动"
EOF

    chmod +x start_ray_head.sh
    
    # 创建服务管理脚本
    create_service_script
    
    # 创建模型管理脚本
    create_model_script
    
    echo "启动头节点容器: $CONTAINER_NAME"
    docker run --shm-size $SHM_SIZE --network=host --name=$CONTAINER_NAME --privileged \
        --device=/dev/kfd --device=/dev/dri --group-add video --cap-add=SYS_PTRACE \
        --security-opt seccomp=unconfined \
        -v $PROJECT_PATH:/home/ \
        -v $MODEL_PATH:/models/ \
        -v $HYHAL_PATH:/opt/hyhal:ro \
        -v $(pwd)/install_vllm_ray.sh:/install_vllm_ray.sh \
        -v $(pwd)/start_ray_head.sh:/start_ray_head.sh \
        -v $(pwd)/service.py:/service.py \
        -v $(pwd)/model_manager.py:/model_manager.py \
        -e CONFIG_FILE="/config.env" \
        -v $(pwd)/config.env:/config.env \
        -d $IMAGE_ID /bin/bash -c "/install_vllm_ray.sh && /start_ray_head.sh"
    
    echo "头节点已部署，Ray dashboard地址: http://$HEAD_IP:$DASHBOARD_PORT"
    echo "您可以使用以下命令查看日志:"
    echo "docker logs -f $CONTAINER_NAME"
    
    # 创建便捷脚本
    create_helper_scripts "$HEAD_IP"
}

# 功能：部署工作节点
deploy_worker() {
    local HEAD_IP=$1
    local WORKER_IP=$2
    
    if [ -z "$HEAD_IP" ]; then
        echo "错误: 未提供头节点IP"
        echo "用法: $0 worker <头节点IP> <工作节点IP>"
        exit 1
    fi
    
    if [ -z "$WORKER_IP" ]; then
        echo "工作节点需要提供工作节点IP"
        echo "用法: $0 worker <头节点IP> <工作节点IP>"
        exit 1
    fi
    
    echo "开始部署工作节点: $WORKER_IP，连接到头节点: $HEAD_IP"
    
    # 拉取基础镜像
    echo "拉取基础镜像: $BASE_IMAGE"
    docker pull $BASE_IMAGE
    
    # 获取镜像ID
    IMAGE_ID=$(docker images -q $BASE_IMAGE)
    if [ -z "$IMAGE_ID" ]; then
        echo "错误: 无法获取镜像ID"
        exit 1
    fi
    echo "获取到镜像ID: $IMAGE_ID"
    
    # 创建安装脚本
    create_install_script
    
    # 创建工作节点启动脚本
    CONTAINER_NAME="${CONTAINER_PREFIX}-worker-$(date +%s)"
    
    cat > start_ray_worker.sh << EOF
#!/bin/bash
set -e

# 获取所有可用的GPU设备
GPU_DEVICES=\$(ls /dev/dri/renderD* 2>/dev/null | wc -l || echo "0")
echo "检测到 \$GPU_DEVICES 个GPU设备"

# 启动Ray工作节点
echo "启动Ray工作节点，连接到头节点: ${HEAD_IP}:${RAY_PORT}..."
ray start --address=${HEAD_IP}:${RAY_PORT} \\
    --num-gpus=\$GPU_DEVICES \\
    --block

# 这句不会执行，因为ray start --block会阻塞
echo "Ray工作节点已启动"
EOF

    chmod +x start_ray_worker.sh
    
    echo "启动工作节点容器: $CONTAINER_NAME"
    docker run --shm-size $SHM_SIZE --network=host --name=$CONTAINER_NAME --privileged \
        --device=/dev/kfd --device=/dev/dri --group-add video --cap-add=SYS_PTRACE \
        --security-opt seccomp=unconfined \
        -v $PROJECT_PATH:/home/ \
        -v $MODEL_PATH:/models/ \
        -v $HYHAL_PATH:/opt/hyhal:ro \
        -v $(pwd)/install_vllm_ray.sh:/install_vllm_ray.sh \
        -v $(pwd)/start_ray_worker.sh:/start_ray_worker.sh \
        -e CONFIG_FILE="/config.env" \
        -v $(pwd)/config.env:/config.env \
        -d $IMAGE_ID /bin/bash -c "/install_vllm_ray.sh && /start_ray_worker.sh"
    
    echo "工作节点已部署，连接到头节点: $HEAD_IP:$RAY_PORT"
    echo "您可以使用以下命令查看日志:"
    echo "docker logs -f $CONTAINER_NAME"
}

# 功能：创建安装脚本
create_install_script() {
    cat > install_vllm_ray.sh << 'EOF'
#!/bin/bash
set -e

# 检查环境
echo "检查环境..."
python --version
pip --version

# 安装lmslim和vllm
echo "安装lmslim和vllm..."
pip install https://download.sourcefind.cn:65024/directlink/4/lmslim/DAS1.3/lmslim-0.1.2+das.dtk24043-cp310-cp310-manylinux_2_28_x86_64.whl
pip install https://download.sourcefind.cn:65024/directlink/4/vllm/DAS1.3/vllm-0.6.2+das.opt1.dtk24043-cp310-cp310-manylinux_2_28_x86_64.whl

# 安装Ray和其他依赖
echo "安装Ray和依赖..."
pip install ray==2.9.3 "ray[default]"
pip install fastapi uvicorn pydantic tqdm requests

# 验证安装
echo "验证安装..."
python -c "import vllm; import ray; print('vllm 版本:', vllm.__version__); print('ray 版本:', ray.__version__)"

echo "安装完成!"
EOF

    chmod +x install_vllm_ray.sh
}

# 功能：创建服务管理脚本
create_service_script() {
    cat > service.py << 'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vllm+Ray推理服务管理脚本
"""

import argparse
import json
import os
import sys
import time
import logging
from typing import Dict, List, Optional, Union, Any
import threading

import ray
import uvicorn
from fastapi import FastAPI, HTTPException, Request, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

try:
    from vllm import LLM, SamplingParams
    from vllm.lora.request import LoRARequest
except ImportError:
    print("错误: 未安装vllm，请先安装vllm")
    sys.exit(1)

# 配置日志
logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO").upper()),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("vllm-service")

# 加载配置
def load_config():
    config_file = os.environ.get("CONFIG_FILE", "/config.env")
    config = {}
    
    if os.path.exists(config_file):
        with open(config_file, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    try:
                        key, value = line.split("=", 1)
                        config[key.strip()] = value.strip().strip('"')
                    except ValueError:
                        pass
    
    return config

CONFIG = load_config()

# API请求模型
class GenerationRequest(BaseModel):
    prompt: str
    max_tokens: int = Field(512, ge=1, le=4096)
    temperature: float = Field(0.7, ge=0.0, le=2.0)
    top_p: float = Field(0.95, ge=0.0, le=1.0)
    top_k: int = Field(-1, ge=-1)
    presence_penalty: float = Field(0.0, ge=-2.0, le=2.0)
    frequency_penalty: float = Field(0.0, ge=-2.0, le=2.0)
    stop: Optional[Union[str, List[str]]] = None
    stream: bool = False

class BatchGenerationRequest(BaseModel):
    prompts: List[str]
    max_tokens: int = Field(512, ge=1, le=4096)
    temperature: float = Field(0.7, ge=0.0, le=2.0)
    top_p: float = Field(0.95, ge=0.0, le=1.0)
    top_k: int = Field(-1, ge=-1)
    presence_penalty: float = Field(0.0, ge=-2.0, le=2.0)
    frequency_penalty: float = Field(0.0, ge=-2.0, le=2.0)
    stop: Optional[Union[str, List[str]]] = None

# 服务类
class VLLMService:
    def __init__(self, model_path: str, tensor_parallel_size: int = 0):
        self.model_path = model_path
        self.tensor_parallel_size = tensor_parallel_size
        self.llm = None
        self.app = None
        self.start_time = time.time()
        self.request_count = 0
        self.token_count = 0
        
        # 初始化Ray（如果尚未初始化）
        if not ray.is_initialized():
            ray.init(address="auto")
            logger.info("已连接到Ray集群")
            logger.info(f"Ray集群节点数量: {len(ray.nodes())}")
            logger.info(f"可用GPU数量: {ray.cluster_resources().get('GPU', 0)}")
        
        # 加载模型
        self._load_model()
        
        # 创建API应用
        self._create_app()
    
    def _load_model(self):
        """加载模型"""
        start_time = time.time()
        logger.info(f"开始加载模型: {self.model_path}, tensor_parallel_size={self.tensor_parallel_size}")
        
        if self.tensor_parallel_size <= 0:
            # 自动设置tensor_parallel_size
            available_gpus = int(ray.cluster_resources().get("GPU", 1))
            self.tensor_parallel_size = available_gpus
            logger.info(f"自动设置tensor_parallel_size为{self.tensor_parallel_size}")
        
        try:
            # 获取模型格式
            quantization = CONFIG.get("QUANTIZATION", "none").lower()
            quantization_options = {}
            
            if quantization != "none":
                logger.info(f"使用量化: {quantization}")
                if quantization == "int8":
                    quantization_options = {"quantization": "awq"}
                elif quantization == "int4":
                    quantization_options = {"quantization": "gptq"}
            
            self.llm = LLM(
                model=self.model_path,
                tensor_parallel_size=self.tensor_parallel_size,
                trust_remote_code=True,
                download_dir=None,
                seed=42,
                **quantization_options
            )
            load_time = time.time() - start_time
            logger.info(f"模型加载完成，耗时: {load_time:.2f}秒")
        except Exception as e:
            logger.error(f"模型加载失败: {e}")
            raise
    
    def _create_app(self):
        """创建FastAPI应用"""
        app = FastAPI(
            title="vllm Ray推理服务", 
            description="基于vllm+Ray的高性能推理服务",
            version="1.0.0"
        )
        
        # 添加CORS中间件
        app.add_middleware(
            CORSMiddleware,
            allow_origins=["*"],
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )
        
        # 添加路由
        @app.get("/")
        async def root():
            """服务状态检查"""
            uptime = time.time() - self.start_time
            return {
                "status": "running",
                "model": os.path.basename(self.model_path),
                "model_path": self.model_path,
                "vllm_version": getattr(self.llm, "vllm_version", "unknown"),
                "tensor_parallel_size": self.llm.llm_engine.tp_size,
                "gpu_count": ray.cluster_resources().get("GPU", 0),
                "node_count": len(ray.nodes()),
                "uptime": f"{uptime:.0f}秒",
                "request_count": self.request_count,
                "token_count": self.token_count,
            }
        
        @app.post("/generate")
        async def generate(request: GenerationRequest):
            """生成文本"""
            try:
                # 更新请求计数
                self.request_count += 1
                
                # 设置采样参数
                sampling_params = SamplingParams(
                    temperature=request.temperature,
                    top_p=request.top_p,
                    top_k=request.top_k if request.top_k > 0 else None,
                    presence_penalty=request.presence_penalty,
                    frequency_penalty=request.frequency_penalty,
                    max_tokens=request.max_tokens,
                    stop=request.stop,
                )
                
                # 流式响应处理
                if request.stream:
                    return StreamingResponse(
                        self._stream_response(request.prompt, sampling_params),
                        media_type="text/event-stream"
                    )
                
                # 非流式响应
                start_time = time.time()
                outputs = self.llm.generate(request.prompt, sampling_params)
                infer_time = time.time() - start_time
                
                output = outputs[0]
                generated_tokens = len(output.outputs[0].token_ids)
                self.token_count += generated_tokens
                
                return JSONResponse({
                    "text": output.outputs[0].text,
                    "finish_reason": output.outputs[0].finish_reason,
                    "generated_tokens": generated_tokens,
                    "prompt": output.prompt,
                    "inference_time": infer_time,
                })
                
            except Exception as e:
                logger.error(f"生成过程中出错: {e}")
                raise HTTPException(status_code=500, detail=str(e))
        
        @app.post("/batch_generate")
        async def batch_generate(request: BatchGenerationRequest):
            """批量生成文本"""
            try:
                # 更新请求计数
                self.request_count += 1
                
                # 设置采样参数
                sampling_params = SamplingParams(
                    temperature=request.temperature,
                    top_p=request.top_p,
                    top_k=request.top_k if request.top_k > 0 else None,
                    presence_penalty=request.presence_penalty,
                    frequency_penalty=request.frequency_penalty,
                    max_tokens=request.max_tokens,
                    stop=request.stop,
                )
                
                # 批量推理
                start_time = time.time()
                outputs = self.llm.generate(request.prompts, sampling_params)
                infer_time = time.time() - start_time
                
                # 处理返回结果
                results = []
                total_tokens = 0
                for output in outputs:
                    tokens = len(output.outputs[0].token_ids)
                    total_tokens += tokens
                    results.append({
                        "text": output.outputs[0].text,
                        "finish_reason": output.outputs[0].finish_reason,
                        "generated_tokens": tokens,
                        "prompt": output.prompt,
                    })
                
                self.token_count += total_tokens
                
                return JSONResponse({
                    "results": results,
                    "inference_time": infer_time,
                    "batch_size": len(request.prompts),
                    "total_tokens": total_tokens,
                })
                
            except Exception as e:
                logger.error(f"批量生成过程中出错: {e}")
                raise HTTPException(status_code=500, detail=str(e))
        
        @app.get("/metrics")
        async def metrics():
            """系统指标信息"""
            uptime = time.time() - self.start_time
            metrics = {
                "model_info": {
                    "name": os.path.basename(self.model_path),
                    "path": self.model_path,
                    "tensor_parallel_size": self.llm.llm_engine.tp_size,
                },
                "cluster_info": {
                    "node_count": len(ray.nodes()),
                    "gpu_count": ray.cluster_resources().get("GPU", 0),
                    "resources": ray.cluster_resources(),
                },
                "runtime_info": {
                    "python_version": os.sys.version,
                    "vllm_version": getattr(self.llm, "vllm_version", "unknown"),
                    "ray_version": ray.__version__,
                    "uptime": f"{uptime:.0f}秒",
                },
                "performance": {
                    "request_count": self.request_count,
                    "token_count": self.token_count,
                    "tokens_per_second": self.token_count / uptime if uptime > 0 else 0,
                }
            }
            return JSONResponse(metrics)
        
        @app.get("/health")
        async def health():
            """健康检查"""
            return {"status": "healthy"}
        
        self.app = app
    
    async def _stream_response(self, prompt, sampling_params):
        """流式响应生成器"""
        request_id = f"req-{time.time()}-{hash(prompt) % 10000}"
        
        # 发送开始事件
        yield f"event: start\ndata: {json.dumps({'request_id': request_id})}\n\n"
        
        # 使用vllm的流式接口
        gen_stream = self.llm.generate_stream(prompt, sampling_params)
        
        tokens_generated = 0
        start_time = time.time()
        
        for output in gen_stream:
            if not output.finished:
                # 发送生成的tokens
                new_text = output.outputs[0].text[tokens_generated:]
                tokens_generated = len(output.outputs[0].text)
                
                yield f"event: token\ndata: {json.dumps({'text': new_text, 'request_id': request_id})}\n\n"
            else:
                # 发送完成事件
                final_text = output.outputs[0].text
                finish_reason = output.outputs[0].finish_reason
                infer_time = time.time() - start_time
                
                self.token_count += len(output.outputs[0].token_ids)
                
                yield f"event: finish\ndata: {json.dumps({'text': final_text, 'finish_reason': finish_reason, 'inference_time': infer_time, 'request_id': request_id})}\n\n"
    
    def start(self, host: str = "0.0.0.0", port: int = 8000):
        """启动服务"""
        logger.info(f"启动推理服务 - 监听地址: {host}:{port}")
        uvicorn.run(self.app, host=host, port=port)

def parse_args():
    parser = argparse.ArgumentParser(description="vllm+Ray推理服务")
    parser.add_argument("--model-path", type=str, default=None, help="模型路径")
    parser.add_argument("--tensor-parallel-size", type=int, default=0, 
                        help="Tensor并行大小，0表示自动使用所有可用GPU")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="服务主机地址")
    parser.add_argument("--port", type=int, default=None, help="服务端口")
    return parser.parse_args()

def main():
    args = parse_args()
    
    # 读取配置
    model_path = args.model_path
    if not model_path:
        model_name = CONFIG.get("DEFAULT_MODEL")
        if not model_name:
            print("错误: 未指定模型路径，请使用--model-path参数或在配置中设置DEFAULT_MODEL")
            sys.exit(1)
        model_path = os.path.join("/models", model_name)
    
    # 检查模型路径
    if not os.path.exists(model_path):
        print(f"错误: 模型路径不存在: {model_path}")
        print("请确认模型已下载，或使用model_manager.py下载模型")
        sys.exit(1)
    
    # 获取端口
    port = args.port or int(CONFIG.get("API_PORT", "8000"))
    
    # 获取TP大小
    tp_size = args.tensor_parallel_size
    if tp_size <= 0:
        tp_size = int(CONFIG.get("DEFAULT_TP_SIZE", "0"))
    
    try:
        # 创建服务
        service = VLLMService(model_path, tp_size)
        
        # 启动服务
        service.start(args.host, port)
    except Exception as e:
        print(f"启动服务失败: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()
EOF

    chmod +x service.py
}

# 功能：创建模型管理脚本
create_model_script() {
    cat > model_manager.py << 'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
模型管理脚本 - 用于下载、同步和管理模型
"""

import argparse
import os
import sys
import logging
import json
import shutil
import subprocess
import time
from typing import Dict, List, Optional

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("model-manager")

# 加载配置
def load_config():
    config_file = os.environ.get("CONFIG_FILE", "/config.env")
    config = {}
    
    if os.path.exists(config_file):
        with open(config_file, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    try:
                        key, value = line.split("=", 1)
                        config[key.strip()] = value.strip().strip('"')
                    except ValueError:
                        pass
    
    return config

CONFIG = load_config()

def check_dependencies():
    """检查并安装依赖"""
    try:
        import huggingface_hub
    except ImportError:
        logger.info("安装huggingface_hub...")
        os.system("pip install huggingface_hub")
    
    try:
        from tqdm import tqdm
    except ImportError:
        logger.info("安装tqdm...")
        os.system("pip install tqdm")

def download_from_huggingface(repo_id: str, output_dir: str, use_auth: bool = False, token: str = None):
    """从Hugging Face下载模型"""
    from huggingface_hub import snapshot_download
    from tqdm import tqdm
    
    logger.info(f"开始从Hugging Face下载模型: {repo_id}")
    
    # 创建进度条回调
    def progress_callback(progress):
        if not hasattr(progress_callback, "pbar"):
            progress_callback.pbar = tqdm(total=100, desc="下载进度")
        if progress.total.downloaded == 0:
            return
        percentage = min(int(100 * progress.current / progress.total.total), 100)
        old_val = progress_callback.pbar.n
        progress_callback.pbar.update(percentage - old_val)
    
    # 确保输出目录存在
    os.makedirs(output_dir, exist_ok=True)
    
    try:
        model_dir = snapshot_download(
            repo_id=repo_id,
            local_dir=os.path.join(output_dir, os.path.basename(repo_id)),
            local_dir_use_symlinks=False,
            token=token if use_auth else None,
            progressbar=True,
            max_workers=8
        )
        logger.info(f"模型下载完成，保存在: {model_dir}")
        return model_dir
    except Exception as e:
        logger.error(f"下载过程中出错: {e}")
        raise

def download_from_modelscope(repo_id: str, output_dir: str):
    """从ModelScope下载模型"""
    try:
        from modelscope.hub.snapshot_download import snapshot_download
    except ImportError:
        logger.info("安装ModelScope...")
        os.system("pip install modelscope")
        from modelscope.hub.snapshot_download import snapshot_download
    
    logger.info(f"开始从ModelScope下载模型: {repo_id}")
    
    # 确保输出目录存在
    os.makedirs(output_dir, exist_ok=True)
    
    try:
        model_dir = snapshot_download(
            model_id=repo_id,
            cache_dir=os.path.join(output_dir, "modelscope_cache"),
        )
        target_dir = os.path.join(output_dir, os.path.basename(repo_id))
        
        # 如果目标目录不同于下载目录，创建符号链接或复制文件
        if model_dir != target_dir:
            if os.path.exists(target_dir):
                logger.warning(f"目标目录已存在: {target_dir}")
            else:
                os.makedirs(os.path.dirname(target_dir), exist_ok=True)
                os.symlink(model_dir, target_dir)
                logger.info(f"创建符号链接: {model_dir} -> {target_dir}")
        
        logger.info(f"模型下载完成，保存在: {model_dir}")
        return model_dir
    except Exception as e:
        logger.error(f"下载过程中出错: {e}")
        raise

def verify_model(model_dir: str) -> bool:
    """验证模型完整性"""
    logger.info(f"验证模型: {model_dir}")
    
    # 检查模型文件
    expected_files = ["config.json", "tokenizer.json", "tokenizer_config.json"]
    model_files = ["pytorch_model.bin", "model.safetensors"]
    
    for file in expected_files:
        path = os.path.join(model_dir, file)
        if not os.path.exists(path):
            logger.warning(f"缺少文件: {file}")
    
    # 检查是否有任何模型文件
    has_model_file = False
    for file in model_files:
        path = os.path.join(model_dir, file)
        if os.path.exists(path):
            has_model_file = True
            logger.info(f"发现模型文件: {file}")
            break
    
    # 检查是否有分片文件
    if not has_model_file:
        shard_files = [f for f in os.listdir(model_dir) if f.startswith("pytorch_model") and f.endswith(".bin")]
        if shard_files:
            logger.info(f"发现分片模型文件: {len(shard_files)}个分片")
            has_model_file = True
    
    if not has_model_file:
        logger.warning("未找到任何模型文件!")
    
    # 检查配置文件
    try:
        with open(os.path.join(model_dir, "config.json"), "r") as f:
            config = json.load(f)
        logger.info(f"模型类型: {config.get('model_type', 'unknown')}")
        logger.info(f"模型尺寸: {config.get('hidden_size', 'unknown')} hidden size, "
                  f"{config.get('num_hidden_layers', 'unknown')} layers, "
                  f"{config.get('num_attention_heads', 'unknown')} attention heads")
    except Exception as e:
        logger.warning(f"读取配置文件时出错: {e}")
    
    return has_model_file

def list_models(model_dir: str) -> List[Dict]:
    """列出已下载的模型"""
    if not os.path.exists(model_dir):
        logger.warning(f"模型目录不存在: {model_dir}")
        return []
    
    models = []
    for item in os.listdir(model_dir):
        item_path = os.path.join(model_dir, item)
        if os.path.isdir(item_path):
            # 检查是否是有效的模型目录
            if os.path.exists(os.path.join(item_path, "config.json")):
                size = sum(os.path.getsize(os.path.join(dirpath, filename))
                          for dirpath, _, filenames in os.walk(item_path)
                          for filename in filenames)
                
                # 尝试读取模型信息
                model_info = {
                    "name": item,
                    "path": item_path,
                    "size": size,
                    "size_gb": size / (1024 ** 3),
                }
                
                # 读取模型类型
                try:
                    with open(os.path.join(item_path, "config.json"), "r") as f:
                        config = json.load(f)
                    model_info["model_type"] = config.get("model_type", "unknown")
                    model_info["hidden_size"] = config.get("hidden_size", "?")
                    model_info["num_layers"] = config.get("num_hidden_layers", "?")
                except Exception:
                    model_info["model_type"] = "unknown"
                
                models.append(model_info)
    
    return models

def sync_model_to_nodes(model_name: str, nodes: List[str], model_dir: str):
    """同步模型到所有工作节点"""
    if not nodes:
        logger.warning("未提供任何节点，无法同步模型")
        return False
    
    source_path = os.path.join(model_dir, model_name)
    if not os.path.exists(source_path):
        logger.error(f"源模型路径不存在: {source_path}")
        return False
    
    logger.info(f"正在同步模型 {model_name} 到 {len(nodes)} 个节点")
    
    for node in nodes:
        logger.info(f"同步到节点: {node}")
        try:
            # 确保目标目录存在
            ssh_cmd = f"ssh {node} 'mkdir -p {model_dir}'"
            subprocess.run(ssh_cmd, shell=True, check=True)
            
            # 使用rsync同步
            rsync_cmd = f"rsync -avz --progress {source_path}/ {node}:{source_path}/"
            process = subprocess.run(rsync_cmd, shell=True, check=True)
            
            if process.returncode == 0:
                logger.info(f"节点 {node} 同步成功")
            else:
                logger.error(f"节点 {node} 同步失败，返回码: {process.returncode}")
                return False
        except Exception as e:
            logger.error(f"同步到节点 {node} 时出错: {e}")
            return False
    
    logger.info(f"模型 {model_name} 已成功同步到所有节点")
    return True

def download_model(repo_id: str, source: str = "huggingface", output_dir: str = None):
    """下载模型的主函数"""
    # 检查依赖
    check_dependencies()
    
    # 确定输出目录
    if not output_dir:
        output_dir = "/models"
    
    # 从指定源下载模型
    try:
        if source.lower() == "huggingface":
            token = CONFIG.get("HF_TOKEN", "")
            use_auth = token != ""
            model_dir = download_from_huggingface(repo_id, output_dir, use_auth, token)
        elif source.lower() == "modelscope":
            model_dir = download_from_modelscope(repo_id, output_dir)
        else:
            logger.error(f"不支持的模型源: {source}")
            return None
        
        # 验证模型
        if verify_model(model_dir):
            logger.info("模型验证通过")
        else:
            logger.warning("模型验证未通过，可能缺少必要文件")
        
        return model_dir
    except Exception as e:
        logger.error(f"下载模型时出错: {e}")
        return None

def parse_args():
    parser = argparse.ArgumentParser(description="模型管理工具")
    subparsers = parser.add_subparsers(dest="command", help="子命令")
    
    # 下载命令
    download_parser = subparsers.add_parser("download", help="下载模型")
    download_parser.add_argument("repo_id", type=str, help="模型仓库ID")
    download_parser.add_argument("--source", type=str, default="huggingface", 
                              choices=["huggingface", "modelscope"],
                              help="模型来源")
    download_parser.add_argument("--output-dir", type=str, default=None,
                              help="模型输出目录")
    
    # 列表命令
    list_parser = subparsers.add_parser("list", help="列出已下载的模型")
    list_parser.add_argument("--output-dir", type=str, default=None,
                          help="模型目录")
    
    # 同步命令
    sync_parser = subparsers.add_parser("sync", help="同步模型到工作节点")
    sync_parser.add_argument("model_name", type=str, help="模型名称")
    sync_parser.add_argument("--nodes", type=str, required=True,
                          help="工作节点列表文件")
    sync_parser.add_argument("--model-dir", type=str, default=None,
                          help="模型目录")
    
    # 验证命令
    verify_parser = subparsers.add_parser("verify", help="验证模型完整性")
    verify_parser.add_argument("model_name", type=str, help="模型名称")
    verify_parser.add_argument("--model-dir", type=str, default=None,
                            help="模型目录")
    
    return parser.parse_args()

def main():
    args = parse_args()
    
    if not args.command:
        print("错误: 未指定命令")
        return
    
    # 处理命令
    if args.command == "download":
        output_dir = args.output_dir or CONFIG.get("MODEL_PATH", "/models")
        download_model(args.repo_id, args.source, output_dir)
    
    elif args.command == "list":
        model_dir = args.output_dir or CONFIG.get("MODEL_PATH", "/models")
        models = list_models(model_dir)
        
        if not models:
            print(f"未在 {model_dir} 中找到任何模型")
            return
        
        print(f"\n在 {model_dir} 中找到 {len(models)} 个模型:")
        print("-" * 80)
        print(f"{'模型名称':<30} {'类型':<10} {'大小':<10} {'隐藏层':<8} {'层数':<8}")
        print("-" * 80)
        for model in models:
            print(f"{model['name']:<30} {model['model_type']:<10} {model['size_gb']:.2f} GB {model['hidden_size']:<8} {model['num_layers']:<8}")
    
    elif args.command == "sync":
        model_dir = args.model_dir or CONFIG.get("MODEL_PATH", "/models")
        
        # 读取节点列表
        if not os.path.exists(args.nodes):
            print(f"错误: 节点列表文件不存在: {args.nodes}")
            return
        
        with open(args.nodes, "r") as f:
            nodes = [line.strip() for line in f if line.strip()]
        
        sync_model_to_nodes(args.model_name, nodes, model_dir)
    
    elif args.command == "verify":
        model_dir = args.model_dir or CONFIG.get("MODEL_PATH", "/models")
        model_path = os.path.join(model_dir, args.model_name)
        
        if not os.path.exists(model_path):
            print(f"错误: 模型路径不存在: {model_path}")
            return
        
        if verify_model(model_path):
            print(f"模型 {args.model_name} 验证通过")
        else:
            print(f"模型 {args.model_name} 验证未通过，可能缺少必要文件")

if __name__ == "__main__":
    main()
EOF

    chmod +x model_manager.py
}

# 功能：创建便捷脚本
create_helper_scripts() {
    local HEAD_IP=$1
    
    # 创建模型下载脚本
    cat > download_model.sh << EOF
#!/bin/bash
# 模型下载便捷脚本

# 检查参数
if [ \$# -lt 1 ]; then
    echo "用法: \$0 <模型ID> [来源]"
    echo "示例: \$0 meta-llama/Llama-3-8B-instruct huggingface"
    exit 1
fi

MODEL_ID=\$1
SOURCE=\${2:-huggingface}

# 在容器中执行下载
echo "开始下载模型: \$MODEL_ID 从 \$SOURCE"
docker exec ${CONTAINER_PREFIX}-head python /model_manager.py download \$MODEL_ID --source \$SOURCE

echo "下载完成后，可以使用以下命令启动服务:"
echo "./start_service.sh \$(basename \$MODEL_ID)"
EOF

    chmod +x download_model.sh
    
    # 创建服务启动脚本
    cat > start_service.sh << EOF
#!/bin/bash
# 推理服务启动便捷脚本

# 检查参数
if [ \$# -lt 1 ]; then
    echo "用法: \$0 <模型名称> [TP大小]"
    echo "示例: \$0 Llama-3-8B-instruct 8"
    exit 1
fi

MODEL_NAME=\$1
TP_SIZE=\${2:-0}

# 在容器中启动服务
echo "开始启动模型服务: \$MODEL_NAME (TP_SIZE=\$TP_SIZE)"
docker exec -d ${CONTAINER_PREFIX}-head python /service.py --model-path /models/\$MODEL_NAME --tensor-parallel-size \$TP_SIZE

echo "服务正在启动中..."
echo "API地址: http://${HEAD_IP}:${API_PORT}"
echo "使用以下命令检查服务状态:"
echo "curl http://${HEAD_IP}:${API_PORT}"
EOF

    chmod +x start_service.sh
    
    # 创建状态检查脚本
    cat > check_status.sh << EOF
#!/bin/bash
# 状态检查便捷脚本

echo "检查vllm+Ray集群状态..."

# 检查容器状态
echo -e "\n容器状态:"
docker ps --filter "name=${CONTAINER_PREFIX}"

# 检查Ray集群状态
echo -e "\nRay集群状态:"
docker exec ${CONTAINER_PREFIX}-head ray status

# 检查API服务状态
echo -e "\nAPI服务状态:"
curl -s http://${HEAD_IP}:${API_PORT} || echo "API服务未启动或无法访问"

# 列出已下载模型
echo -e "\n已下载模型:"
docker exec ${CONTAINER_PREFIX}-head python /model_manager.py list
EOF

    chmod +x check_status.sh
    
    # 创建工作节点列表文件
    cat > worker_nodes.txt << EOF
# 工作节点列表文件
# 每行一个节点IP地址
# 例如:
# 192.168.1.101
# 192.168.1.102
EOF

    echo "已创建便捷脚本:"
    echo "  - download_model.sh: 下载模型"
    echo "  - start_service.sh: 启动推理服务"
    echo "  - check_status.sh: 检查集群状态"
    echo "  - worker_nodes.txt: 工作节点列表 (请编辑添加工作节点IP)"
}

# 功能：下载模型
download_model() {
    local MODEL_ID=$1
    local SOURCE=$2
    
    if [ -z "$MODEL_ID" ]; then
        echo "错误: 未提供模型ID"
        echo "用法: $0 model-download <模型ID> [来源]"
        return 1
    fi
    
    # 默认来源
    SOURCE=${SOURCE:-huggingface}
    
    # 检查头节点容器
    CONTAINER_ID=$(docker ps -qf "name=${CONTAINER_PREFIX}-head")
    if [ -z "$CONTAINER_ID" ]; then
        echo "错误: 未找到头节点容器，请先部署头节点"
        return 1
    fi
    
    echo "在头节点容器中下载模型: $MODEL_ID 从 $SOURCE"
    docker exec $CONTAINER_ID python /model_manager.py download $MODEL_ID --source $SOURCE
    
    # 检查是否需要同步到工作节点
    if [ -f "worker_nodes.txt" ]; then
        WORKER_COUNT=$(grep -v "^#" worker_nodes.txt | grep -v "^$" | wc -l)
        if [ $WORKER_COUNT -gt 0 ]; then
            echo "检测到 $WORKER_COUNT 个工作节点，是否同步模型到所有工作节点?"
            read -p "同步模型? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                docker exec $CONTAINER_ID python /model_manager.py sync $(basename $MODEL_ID) --nodes /home/worker_nodes.txt
            fi
        fi
    fi
}

# 功能：启动推理服务
start_service() {
    local MODEL_NAME=$1
    local TP_SIZE=$2
    
    if [ -z "$MODEL_NAME" ]; then
        echo "错误: 未提供模型名称"
        echo "用法: $0 start-service <模型名称> [TP大小]"
        return 1
    fi
    
    # 默认TP大小
    TP_SIZE=${TP_SIZE:-0}
    
    # 检查头节点容器
    CONTAINER_ID=$(docker ps -qf "name=${CONTAINER_PREFIX}-head")
    if [ -z "$CONTAINER_ID" ]; then
        echo "错误: 未找到头节点容器，请先部署头节点"
        return 1
    fi
    
    # 检查模型是否存在
    MODEL_PATH="/models/$MODEL_NAME"
    if ! docker exec $CONTAINER_ID test -d $MODEL_PATH; then
        echo "错误: 模型目录不存在: $MODEL_PATH"
        echo "请先下载模型: $0 model-download <模型ID>"
        return 1
    fi
    
    echo "在头节点容器中启动推理服务: 模型=$MODEL_NAME, TP_SIZE=$TP_SIZE"
    docker exec -d $CONTAINER_ID python /service.py --model-path $MODEL_PATH --tensor-parallel-size $TP_SIZE --port ${API_PORT:-8000}
    
    # 等待服务启动
    echo "服务启动中，请稍候..."
    sleep 5
    
    # 检查服务状态
    HEAD_IP=$(hostname -I | awk '{print $1}')
    curl -s http://$HEAD_IP:${API_PORT:-8000} || {
        echo "警告: 服务可能未成功启动，请检查日志:"
        echo "docker logs $CONTAINER_ID"
    }
    
    echo "API服务地址: http://$HEAD_IP:${API_PORT:-8000}"
}

# 功能：检查集群状态
check_status() {
    # 检查Docker容器
    echo "检查Docker容器状态..."
    docker ps --filter "name=${CONTAINER_PREFIX}"
    
    # 检查头节点容器
    CONTAINER_ID=$(docker ps -qf "name=${CONTAINER_PREFIX}-head")
    if [ -z "$CONTAINER_ID" ]; then
        echo "错误: 未找到头节点容器，请先部署头节点"
        return 1
    fi
    
    # 检查Ray集群
    echo -e "\n检查Ray集群状态..."
    docker exec $CONTAINER_ID ray status
    
    # 检查API服务
    echo -e "\n检查API服务状态..."
    HEAD_IP=$(hostname -I | awk '{print $1}')
    curl -s http://$HEAD_IP:${API_PORT:-8000} || echo "API服务未启动或无法访问"
    
    # 列出已下载模型
    echo -e "\n列出已下载模型..."
    docker exec $CONTAINER_ID python /model_manager.py list
}

# 主函数
main() {
    # 检查配置
    check_config
    
    # 处理命令
    case "$COMMAND" in
        head)
            deploy_head "$1"
            ;;
        worker)
            deploy_worker "$1" "$2"
            ;;
        model-download)
            download_model "$1" "$2"
            ;;
        start-service)
            start_service "$1" "$2"
            ;;
        status)
            check_status
            ;;
        *)
            echo "未知命令: $COMMAND"
            echo "可用命令:"
            echo "  head <头节点IP>             - 部署头节点"
            echo "  worker <头节点IP> <工作节点IP> - 部署工作节点"
            echo "  model-download <模型ID> [来源] - 下载模型"
            echo "  start-service <模型名称> [TP大小] - 启动推理服务"
            echo "  status                     - 检查集群状态"
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"