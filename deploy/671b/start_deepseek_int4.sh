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
echo -e "${GREEN}启动 DeepSeek-R1-Int4-AWQ 模型服务${NC}"
echo -e "${BLUE}============================================${NC}"

# 默认参数
MODEL_PATH="/home/models/DeepSeek-R1-Int4-AWQ"
TOKENIZER_PATH="/home/models/DeepSeek-R1-Int4-AWQ"
DTYPE="int4"
QUANTIZATION="awq" 
APP_NAME="deepseek_r1_int4"
ROUTE_PREFIX="/"
SHUTDOWN=true
CPU_ONLY=false
DEBUG=false

# 解析命令行参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --model-path)
      MODEL_PATH="$2"
      shift 2
      ;;
    --tokenizer-path)
      TOKENIZER_PATH="$2"
      shift 2
      ;;
    --dtype)
      DTYPE="$2"
      shift 2
      ;;
    --quantization)
      QUANTIZATION="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --route-prefix)
      ROUTE_PREFIX="$2"
      shift 2
      ;;
    --no-shutdown)
      SHUTDOWN=false
      shift
      ;;
    --cpu-only)
      CPU_ONLY=true
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    *)
      echo -e "${RED}未知参数: $1${NC}"
      exit 1
      ;;
  esac
done

# 显示配置信息
echo -e "${GREEN}配置信息:${NC}"
echo -e "  应用名称: ${BLUE}${APP_NAME}${NC}"
echo -e "  路由前缀: ${BLUE}${ROUTE_PREFIX}${NC}"
echo -e "  模型路径: ${BLUE}${MODEL_PATH}${NC}"
echo -e "  Tokenizer路径: ${BLUE}${TOKENIZER_PATH}${NC}"
echo -e "  数据类型: ${BLUE}${DTYPE}${NC}"
echo -e "  量化方法: ${BLUE}${QUANTIZATION}${NC}"
echo -e "  关闭现有部署: ${BLUE}${SHUTDOWN}${NC}"
echo -e "  仅CPU模式: ${BLUE}${CPU_ONLY}${NC}"
echo -e "  调试模式: ${BLUE}${DEBUG}${NC}"

# 检查 NVIDIA 驱动和 GPU
if [ "$CPU_ONLY" = false ]; then
  echo -e "\n${BLUE}检查 NVIDIA 驱动和 GPU...${NC}"
  if ! command -v nvidia-smi &> /dev/null; then
    echo -e "${RED}未找到 nvidia-smi 命令。请确保已安装 NVIDIA 驱动。${NC}"
    echo -e "${YELLOW}如果要在无 GPU 环境下运行，请使用 --cpu-only 参数（不推荐生产环境使用）${NC}"
    exit 1
  fi
  
  # 运行 nvidia-smi 检查 GPU 状态
  if ! nvidia-smi &> /dev/null; then
    echo -e "${RED}执行 nvidia-smi 失败。请检查 NVIDIA 驱动是否正常工作。${NC}"
    echo -e "${YELLOW}如果要在无 GPU 环境下运行，请使用 --cpu-only 参数（不推荐生产环境使用）${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}NVIDIA 驱动正常，GPU 可用。${NC}"
fi

# 检查模型路径是否存在
echo -e "\n${BLUE}检查模型路径...${NC}"
if [ ! -d "$MODEL_PATH" ]; then
  echo -e "${RED}模型路径不存在: ${MODEL_PATH}${NC}"
  echo -e "${RED}请确保模型已下载并指定正确的路径${NC}"
  exit 1
fi
echo -e "${GREEN}模型路径存在。${NC}"

# 构建命令
CMD="python $(dirname "$0")/ray-deepseek-r1-int4-improved.py"
CMD="${CMD} --model-path ${MODEL_PATH}"
CMD="${CMD} --tokenizer-path ${TOKENIZER_PATH}"
CMD="${CMD} --dtype ${DTYPE}"
CMD="${CMD} --quantization ${QUANTIZATION}"
CMD="${CMD} --app-name ${APP_NAME}"
CMD="${CMD} --route-prefix ${ROUTE_PREFIX}"

if [ "$SHUTDOWN" = true ]; then
  CMD="${CMD} --shutdown"
fi

if [ "$CPU_ONLY" = true ]; then
  CMD="${CMD} --cpu-only"
fi

if [ "$DEBUG" = true ]; then
  CMD="${CMD} --debug"
fi

echo -e "\n${GREEN}执行命令:${NC}"
echo -e "${BLUE}${CMD}${NC}"
echo -e "${BLUE}============================================${NC}"

# 执行命令
eval "${CMD}" 