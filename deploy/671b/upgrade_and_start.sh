#!/bin/bash
set -e

# 定义颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 输出带颜色的信息
echo -e "${BLUE}============================================${NC}"
echo -e "${GREEN}升级 vLLM 和 Ray 并启动 DeepSeek-R1-Channel-INT8 模型服务${NC}"
echo -e "${BLUE}============================================${NC}"

# 升级部分
echo -e "${YELLOW}1. 升级 vLLM 和 Ray 库${NC}"
echo -e "${BLUE}执行: pip install --upgrade vllm ray${NC}"

pip install --upgrade vllm ray

echo -e "\n${GREEN}升级完成！${NC}"

# 默认部署参数
MODEL_PATH="/home/models/DeepSeek-R1-Channel-INT8"
TOKENIZER_PATH="/home/models/DeepSeek-R1"
DTYPE="int8"
QUANTIZATION="awq" # 或者 "gptq"，取决于模型的量化方式
APP_NAME="deepseek_r1_int8"
ROUTE_PREFIX="/"
SHUTDOWN=true

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
    *)
      echo -e "${RED}未知参数: $1${NC}"
      exit 1
      ;;
  esac
done

# 显示配置信息
echo -e "\n${YELLOW}2. 启动模型服务${NC}"
echo -e "${GREEN}配置信息:${NC}"
echo -e "  应用名称: ${BLUE}${APP_NAME}${NC}"
echo -e "  路由前缀: ${BLUE}${ROUTE_PREFIX}${NC}"
echo -e "  模型路径: ${BLUE}${MODEL_PATH}${NC}"
echo -e "  Tokenizer路径: ${BLUE}${TOKENIZER_PATH}${NC}"
echo -e "  数据类型: ${BLUE}${DTYPE}${NC}"
echo -e "  量化方法: ${BLUE}${QUANTIZATION}${NC}"
echo -e "  关闭现有部署: ${BLUE}${SHUTDOWN}${NC}"

# 构建命令
CMD="python $(dirname "$0")/ray-deepseek-int8.py"
CMD="${CMD} --model-path ${MODEL_PATH}"
CMD="${CMD} --tokenizer-path ${TOKENIZER_PATH}"
CMD="${CMD} --dtype ${DTYPE}"
CMD="${CMD} --quantization ${QUANTIZATION}"
CMD="${CMD} --app-name ${APP_NAME}"
CMD="${CMD} --route-prefix ${ROUTE_PREFIX}"

if [ "$SHUTDOWN" = true ]; then
  CMD="${CMD} --shutdown"
fi

echo -e "\n${GREEN}执行命令:${NC}"
echo -e "${BLUE}${CMD}${NC}"
echo -e "${BLUE}============================================${NC}"

# 执行命令
eval "${CMD}" 