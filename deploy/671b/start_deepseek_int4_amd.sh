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
echo -e "${GREEN}启动 DeepSeek-R1-Int4-AWQ 模型服务 (AMD GPU)${NC}"
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
USE_CUDA_COMPAT=true
HIP_VISIBLE_DEVICES=""
ROCM_DEVICE_MAP="auto"

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
    --no-cuda-compat)
      USE_CUDA_COMPAT=false
      shift
      ;;
    --hip-visible-devices)
      HIP_VISIBLE_DEVICES="$2"
      shift 2
      ;;
    --rocm-device-map)
      ROCM_DEVICE_MAP="$2"
      shift 2
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
echo -e "  使用CUDA兼容层: ${BLUE}${USE_CUDA_COMPAT}${NC}"
if [ -n "$HIP_VISIBLE_DEVICES" ]; then
  echo -e "  HIP可见设备: ${BLUE}${HIP_VISIBLE_DEVICES}${NC}"
fi
echo -e "  ROCm设备映射: ${BLUE}${ROCM_DEVICE_MAP}${NC}"

# 检查是否为ROCm环境
if [ "$CPU_ONLY" = false ]; then
  echo -e "\n${BLUE}检查 ROCm 环境...${NC}"
  if command -v rocm-smi &> /dev/null; then
    echo -e "${GREEN}检测到 rocm-smi 命令，ROCm环境可能正常。${NC}"
    rocm-smi --showproductname 2>/dev/null || echo -e "${YELLOW}无法获取GPU产品名称，但ROCm环境可能仍然可用。${NC}"
  else
    echo -e "${YELLOW}未找到 rocm-smi 命令。如果使用海光GPU，请确保ROCm环境正确安装。${NC}"
    echo -e "${YELLOW}注意: 在某些环境中，即使没有rocm-smi命令，PyTorch也能通过其他方式访问AMD GPU。${NC}"
    
    # 设置AMD/ROCm相关环境变量
    if [ -z "$HSA_OVERRIDE_GFX_VERSION" ]; then
      echo -e "${BLUE}设置 HSA_OVERRIDE_GFX_VERSION=10.3.0 以改善兼容性${NC}"
      export HSA_OVERRIDE_GFX_VERSION=10.3.0
    fi
  fi
fi

# 检查模型路径是否存在
echo -e "\n${BLUE}检查模型路径...${NC}"
if [ ! -d "$MODEL_PATH" ]; then
  echo -e "${RED}模型路径不存在: ${MODEL_PATH}${NC}"
  echo -e "${RED}请确保模型已下载并指定正确的路径${NC}"
  exit 1
fi
echo -e "${GREEN}模型路径存在。${NC}"

# 设置AMD环境变量
if [ -n "$HIP_VISIBLE_DEVICES" ]; then
  echo -e "${BLUE}设置 HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES}${NC}"
  export HIP_VISIBLE_DEVICES="$HIP_VISIBLE_DEVICES"
fi

# 设置ROCm CUDA兼容环境变量
if [ "$USE_CUDA_COMPAT" = true ]; then
  echo -e "${BLUE}启用ROCm CUDA兼容层...${NC}"
  export HSA_OVERRIDE_GFX_VERSION=10.3.0
fi

# 构建命令
CMD="python $(dirname "$0")/ray-deepseek-r1-int4-amd.py"
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

if [ "$USE_CUDA_COMPAT" = true ]; then
  CMD="${CMD} --use-cuda-compat"
else
  CMD="${CMD} --no-use-cuda-compat"
fi

if [ -n "$HIP_VISIBLE_DEVICES" ]; then
  CMD="${CMD} --hip-visible-devices ${HIP_VISIBLE_DEVICES}"
fi

if [ "$ROCM_DEVICE_MAP" != "auto" ]; then
  CMD="${CMD} --rocm-device-map ${ROCM_DEVICE_MAP}"
fi

echo -e "\n${GREEN}执行命令:${NC}"
echo -e "${BLUE}${CMD}${NC}"
echo -e "${BLUE}============================================${NC}"

# 执行命令
eval "${CMD}" 