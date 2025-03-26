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
echo -e "${GREEN}升级依赖并启动 DeepSeek-R1-Channel-INT8 模型服务${NC}"
echo -e "${BLUE}============================================${NC}"

# 默认参数
MODEL_PATH="/data/models/DeepSeek-Coder-R1-v1.5-Channel-INT8"
UPGRADE=true
APP_NAME="deepseek_r1_int8"
PORT=8000
NUM_GPUS=1

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
    --no-upgrade)
      UPGRADE=false
      shift
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --num-gpus)
      NUM_GPUS="$2"
      shift 2
      ;;
    --help)
      echo "使用方法: $0 [选项]"
      echo "选项:"
      echo "  --model-path <路径>    模型路径 (默认: /data/models/DeepSeek-Coder-R1-v1.5-Channel-INT8)"
      echo "  --app-name <名称>      应用名称 (默认: deepseek_r1_int8)"
      echo "  --no-upgrade           跳过依赖升级步骤"
      echo "  --port <端口>          服务端口 (默认: 8000)"
      echo "  --num-gpus <数量>      使用的GPU数量 (默认: 1)"
      echo "  --help                 显示此帮助信息"
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
echo -e "${BLUE}- GPU数量: ${NUM_GPUS}${NC}"
if [ "$UPGRADE" = true ]; then
  echo -e "${BLUE}- 升级依赖: 是${NC}"
else
  echo -e "${BLUE}- 升级依赖: 否${NC}"
fi

# 升级依赖
if [ "$UPGRADE" = true ]; then
  echo -e "${BLUE}============================================${NC}"
  echo -e "${GREEN}升级依赖库...${NC}"
  
  # 检查pip是否存在
  if ! command -v pip &> /dev/null; then
    echo -e "${RED}错误: 找不到pip命令${NC}"
    echo -e "${YELLOW}提示: 请确保pip已安装${NC}"
    exit 1
  fi
  
  # 升级pip
  echo -e "${BLUE}升级pip...${NC}"
  python -m pip install --upgrade pip
  
  # 升级vLLM和Ray
  echo -e "${BLUE}升级vLLM和Ray...${NC}"
  pip install --upgrade vllm 'ray[serve]'
  
  # 安装其他依赖
  echo -e "${BLUE}安装其他依赖...${NC}"
  pip install --upgrade numpy torch accelerate transformers
  
  echo -e "${GREEN}依赖升级完成！${NC}"
fi

# 检查模型目录
if [ ! -d "${MODEL_PATH}" ]; then
  echo -e "${RED}错误: 模型目录不存在: ${MODEL_PATH}${NC}"
  echo -e "${YELLOW}提示: 请确认模型路径或使用 --model-path 参数指定正确的路径${NC}"
  exit 1
fi

# 启动服务
echo -e "${BLUE}============================================${NC}"
echo -e "${GREEN}启动模型服务...${NC}"

# 构建启动命令并执行
STARTUP_SCRIPT="$(dirname "$0")/start_deepseek_int8.sh"
STARTUP_CMD="${STARTUP_SCRIPT} --model-path ${MODEL_PATH} --app-name ${APP_NAME} --port ${PORT} --num-gpus ${NUM_GPUS}"

echo -e "${BLUE}执行命令: ${STARTUP_CMD}${NC}"
bash "${STARTUP_CMD}"

echo -e "${GREEN}启动脚本已执行${NC}"
echo -e "${BLUE}============================================${NC}" 