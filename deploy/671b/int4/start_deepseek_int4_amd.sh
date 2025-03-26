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
APP_NAME="deepseek_r1_int4_amd"
NO_SHUTDOWN=false
DEBUG=false
NUM_GPUS=1
PORT=8000

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
    --help)
      echo "使用方法: $0 [选项]"
      echo "选项:"
      echo "  --model-path <路径>    模型路径 (默认: /home/models/DeepSeek-R1-Int4-AWQ)"
      echo "  --app-name <名称>      应用名称 (默认: deepseek_r1_int4_amd)"
      echo "  --no-shutdown          不关闭已有部署"
      echo "  --debug                启用调试模式"
      echo "  --num-gpus <数量>      使用的GPU数量 (默认: 1)"
      echo "  --port <端口>          服务端口 (默认: 8000)"
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
  rocm-smi || echo -e "${YELLOW}警告: rocm-smi命令执行失败${NC}"
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

# 设置AMD GPU环境变量
export HIP_VISIBLE_DEVICES=0,1,2,3
export HSA_OVERRIDE_GFX_VERSION=11.0.0

# 执行Python脚本
echo -e "${BLUE}执行命令: python $(dirname "$0")/ray-deepseek-r1-int4-amd.py --model-path ${MODEL_PATH} --app-name ${APP_NAME} --port ${PORT} --num-gpus ${NUM_GPUS} ${PYTHON_ARGS}${NC}"
python $(dirname "$0")/ray-deepseek-r1-int4-amd.py --model-path "${MODEL_PATH}" --app-name "${APP_NAME}" --port "${PORT}" --num-gpus "${NUM_GPUS}" ${PYTHON_ARGS}

echo -e "${GREEN}启动命令已执行${NC}"
echo -e "${BLUE}============================================${NC}"

# 如果成功启动，打印测试命令
echo -e "${GREEN}服务已启动，您可以使用以下命令进行测试:${NC}"
echo -e "${BLUE}python $(dirname "$0")/test_deepseek_int4.py --url http://localhost:${PORT}/${NC}"
echo -e "${BLUE}============================================${NC}" 