#!/bin/bash
set -e

# 定义颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 输出带颜色的信息
echo -e "${BLUE}============================================${NC}"
echo -e "${GREEN}启动 DeepSeek-R1-Int4-AWQ 模型服务 (分布式部署)${NC}"
echo -e "${BLUE}============================================${NC}"

# 默认参数
MODEL_PATH="/home/models/DeepSeek-R1-Int4-AWQ"
APP_NAME="deepseek_r1_int4_amd"
NO_SHUTDOWN=false
DEBUG=false
NUM_GPUS="auto"  # 自动获取所有可用GPU
PORT=8000
DISTRIBUTED=true
HEAD_ADDRESS=""
MEMORY_PER_WORKER="60g"  # 给每个工作进程60GB内存以留出一些余量

# 解析命令行参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --model-path)
      MODEL_PATH="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --no-shutdown)
      NO_SHUTDOWN=true
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --num-gpus)
      NUM_GPUS="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --head-address)
      HEAD_ADDRESS="$2"
      shift 2
      ;;
    --memory-per-worker)
      MEMORY_PER_WORKER="$2"
      shift 2
      ;;
    --no-distributed)
      DISTRIBUTED=false
      shift
      ;;
    --help)
      echo "使用方法: $0 [选项]"
      echo "选项:"
      echo "  --model-path <路径>         模型路径 (默认: /home/models/DeepSeek-R1-Int4-AWQ)"
      echo "  --app-name <名称>           应用名称 (默认: deepseek_r1_int4_amd)"
      echo "  --no-shutdown               不关闭已有部署"
      echo "  --debug                     启用调试模式"
      echo "  --num-gpus <数量|auto>      每个副本使用的GPU数量 (默认: auto，自动获取所有可用GPU)"
      echo "  --port <端口>               服务端口 (默认: 8000)"
      echo "  --head-address <地址:端口>  Ray集群头节点地址 (用于工作节点连接)"
      echo "  --memory-per-worker <内存>  每个工作进程的内存限制 (默认: 60g)"
      echo "  --no-distributed            禁用分布式模式"
      echo "  --help                      显示此帮助信息"
      exit 0
      ;;
    *)
      echo -e "${RED}未知参数: $1${NC}"
      exit 1
      ;;
  esac
done

# 显示配置信息
echo -e "${BLUE}配置信息:${NC}"
echo -e "${BLUE}- 模型路径: ${MODEL_PATH}${NC}"
echo -e "${BLUE}- 应用名称: ${APP_NAME}${NC}"
echo -e "${BLUE}- 端口: ${PORT}${NC}"
echo -e "${BLUE}- GPU配置: ${NUM_GPUS}${NC}"
echo -e "${BLUE}- 每个工作进程内存: ${MEMORY_PER_WORKER}${NC}"
if [ "$DISTRIBUTED" = true ]; then
  echo -e "${BLUE}- 分布式模式: 已启用${NC}"
  if [ -n "$HEAD_ADDRESS" ]; then
    echo -e "${BLUE}- 集群头节点: ${HEAD_ADDRESS}${NC}"
  else
    echo -e "${GREEN}- 运行为头节点${NC}"
  fi
else
  echo -e "${BLUE}- 分布式模式: 已禁用${NC}"
fi
if [ "$DEBUG" = true ]; then
  echo -e "${BLUE}- 调试模式: 已启用${NC}"
fi
if [ "$NO_SHUTDOWN" = true ]; then
  echo -e "${BLUE}- 保留已有部署: 是${NC}"
else
  echo -e "${BLUE}- 保留已有部署: 否${NC}"
fi

# 检查AMD环境变量
if [ -z "${ROCM_PATH}" ]; then
  echo -e "${YELLOW}警告: ROCM_PATH环境变量未设置，可能影响ROCm环境的正常工作${NC}"
  echo -e "${YELLOW}提示: 建议设置 export ROCM_PATH=/opt/rocm${NC}"
fi

# 检查是否有AMD GPU
if ! command -v rocm-smi &> /dev/null; then
  echo -e "${YELLOW}警告: 未找到rocm-smi命令，无法验证AMD GPU状态${NC}"
  echo -e "${YELLOW}提示: 请确保ROCm环境正确安装${NC}"
else
  echo -e "${BLUE}检查AMD GPU状态...${NC}"
  GPU_COUNT=$(rocm-smi --showallgpus | grep -c "GPU\[")
  echo -e "${GREEN}检测到 ${GPU_COUNT} 个GPU${NC}"
  rocm-smi --showmeminfo || echo -e "${YELLOW}警告: 无法显示GPU内存信息${NC}"
fi

# 构建Python命令行参数
PYTHON_ARGS=""
if [ "$NO_SHUTDOWN" = true ]; then
  PYTHON_ARGS="${PYTHON_ARGS} --no-shutdown"
fi
if [ "$DEBUG" = true ]; then
  PYTHON_ARGS="${PYTHON_ARGS} --debug"
fi

# 检查模型目录
if [ ! -d "${MODEL_PATH}" ]; then
  echo -e "${RED}错误: 模型目录不存在: ${MODEL_PATH}${NC}"
  echo -e "${YELLOW}提示: 请确认模型路径或使用 --model-path 参数指定正确的路径${NC}"
  exit 1
fi

# 确保有权限访问模型文件
if [ ! -r "${MODEL_PATH}" ]; then
  echo -e "${RED}错误: 无法读取模型目录: ${MODEL_PATH}${NC}"
  echo -e "${YELLOW}提示: 请检查文件权限${NC}"
  exit 1
fi

echo -e "${BLUE}============================================${NC}"
echo -e "${GREEN}启动中...${NC}"

# 构建Ray启动命令
if [ "$DISTRIBUTED" = true ]; then
  if [ -z "$HEAD_ADDRESS" ]; then
    # 作为头节点启动
    echo -e "${GREEN}启动Ray集群头节点...${NC}"
    RAY_ARGS="--head --dashboard-host=0.0.0.0 --dashboard-port=8265 --include-dashboard=true"
    if [ "$NUM_GPUS" = "auto" ]; then
      # 自动获取所有可用GPU
      RAY_ARGS="${RAY_ARGS} --num-gpus=$(rocm-smi --showallgpus | grep -c 'GPU\[')"
    else
      RAY_ARGS="${RAY_ARGS} --num-gpus=${NUM_GPUS}"
    fi
    
    # 启动Ray集群头节点
    echo -e "${BLUE}执行: ray start ${RAY_ARGS} --memory ${MEMORY_PER_WORKER}${NC}"
    ray start ${RAY_ARGS} --memory ${MEMORY_PER_WORKER}
    
    # 获取当前节点地址用于其他节点连接
    NODE_IP=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}Ray集群头节点已启动: ${NODE_IP}:6379${NC}"
    echo -e "${GREEN}工作节点可以使用以下命令连接:${NC}"
    echo -e "${BLUE}ray start --address=${NODE_IP}:6379 --num-gpus=<GPU数量>${NC}"
  else
    # 作为工作节点连接到头节点
    echo -e "${GREEN}连接到Ray集群: ${HEAD_ADDRESS}${NC}"
    if [ "$NUM_GPUS" = "auto" ]; then
      # 自动获取所有可用GPU
      RAY_ARGS="--address=${HEAD_ADDRESS} --num-gpus=$(rocm-smi --showallgpus | grep -c 'GPU\[')"
    else
      RAY_ARGS="--address=${HEAD_ADDRESS} --num-gpus=${NUM_GPUS}"
    fi
    
    # 连接到Ray集群
    echo -e "${BLUE}执行: ray start ${RAY_ARGS} --memory ${MEMORY_PER_WORKER}${NC}"
    ray start ${RAY_ARGS} --memory ${MEMORY_PER_WORKER}
  fi
fi

# 执行Python脚本
echo -e "${BLUE}执行命令: python $(dirname "$0")/ray-deepseek-r1-int4-amd.py --model-path ${MODEL_PATH} --app-name ${APP_NAME} --port ${PORT} --num-gpus ${NUM_GPUS} ${PYTHON_ARGS}${NC}"
python $(dirname "$0")/ray-deepseek-r1-int4-amd.py --model-path "${MODEL_PATH}" --app-name "${APP_NAME}" --port "${PORT}" --num-gpus "${NUM_GPUS}" ${PYTHON_ARGS}

echo -e "${GREEN}启动命令已执行${NC}"
echo -e "${BLUE}============================================${NC}"

# 如果成功启动，打印测试命令
echo -e "${GREEN}服务已启动，您可以使用以下命令进行测试:${NC}"
echo -e "${BLUE}python $(dirname "$0")/test_deepseek_int4.py --url http://localhost:${PORT}/${NC}"
echo -e "${BLUE}============================================${NC}" 