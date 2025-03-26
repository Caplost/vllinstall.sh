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
echo -e "${GREEN}启动 DeepSeek-R1-Int4-AWQ 模型服务 (跨机器分布式部署)${NC}"
echo -e "${BLUE}============================================${NC}"

# 默认参数
MODEL_PATH="/home/models/DeepSeek-R1-Int4-AWQ"
APP_NAME="deepseek_r1_int4_amd"
NO_SHUTDOWN=false
DEBUG=false
NUM_GPUS="auto"  # 自动获取所有可用GPU
PORT=8000
RAY_ADDRESS="auto"  # 默认自动连接已有集群
TENSOR_PARALLEL_SIZE=16  # 默认使用16卡张量并行

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
    --ray-address)
      RAY_ADDRESS="$2"
      shift 2
      ;;
    --tensor-parallel-size)
      TENSOR_PARALLEL_SIZE="$2"
      shift 2
      ;;
    --help)
      echo "使用方法: $0 [选项]"
      echo "选项:"
      echo "  --model-path <路径>              模型路径 (默认: /home/models/DeepSeek-R1-Int4-AWQ)"
      echo "  --app-name <名称>                应用名称 (默认: deepseek_r1_int4_amd)"
      echo "  --no-shutdown                    不关闭已有部署"
      echo "  --debug                          启用调试模式"
      echo "  --num-gpus <数量|auto>           每个副本使用的GPU数量 (默认: auto，自动获取所有可用GPU)"
      echo "  --port <端口>                    服务端口 (默认: 8000)"
      echo "  --ray-address <地址:端口>        Ray集群地址 (默认: auto，自动连接)"
      echo "  --tensor-parallel-size <数量>    张量并行度 (默认: 16，用于跨机器推理)"
      echo "  --help                           显示此帮助信息"
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
echo -e "${BLUE}- 张量并行度: ${TENSOR_PARALLEL_SIZE}${NC}"
echo -e "${BLUE}- Ray集群地址: ${RAY_ADDRESS}${NC}"
if [ "$DEBUG" = true ]; then
  echo -e "${BLUE}- 调试模式: 已启用${NC}"
fi
if [ "$NO_SHUTDOWN" = true ]; then
  echo -e "${BLUE}- 保留已有部署: 是${NC}"
else
  echo -e "${BLUE}- 保留已有部署: 否${NC}"
fi

# 检查张量并行度参数
if [ "$TENSOR_PARALLEL_SIZE" -gt 8 ]; then
  echo -e "${YELLOW}注意: 使用高张量并行度 ${TENSOR_PARALLEL_SIZE}，确保Ray集群可以访问至少${TENSOR_PARALLEL_SIZE}张GPU${NC}"
  echo -e "${YELLOW}建议在Ray集群包含两台机器的情况下使用此配置${NC}"
fi

# 暂时禁用立即退出，以便处理命令可能的错误
set +e

# 检查Ray集群状态
echo -e "${BLUE}检查Ray集群状态...${NC}"
ray status 2>/dev/null
RAY_STATUS_CODE=$?

if [ $RAY_STATUS_CODE -ne 0 ]; then
  echo -e "${YELLOW}警告: Ray集群状态检查失败，可能需要启动Ray集群${NC}"
  echo -e "${YELLOW}提示: 如果尚未启动Ray集群，请先运行 'ray start --head'${NC}"
fi

# 恢复立即退出设置
set -e

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
echo -e "${GREEN}连接到Ray集群: ${RAY_ADDRESS}${NC}"
echo -e "${GREEN}使用${TENSOR_PARALLEL_SIZE}张GPU进行分布式推理${NC}"

# 执行Python脚本
echo -e "${BLUE}执行命令: python $(dirname "$0")/ray-deepseek-r1-int4-amd.py --model-path ${MODEL_PATH} --app-name ${APP_NAME} --port ${PORT} --num-gpus ${NUM_GPUS} --ray-address ${RAY_ADDRESS} --tensor-parallel-size ${TENSOR_PARALLEL_SIZE} ${PYTHON_ARGS}${NC}"

# 暂时禁用立即退出，以便处理Python脚本可能的错误
set +e
python $(dirname "$0")/ray-deepseek-r1-int4-amd.py --model-path "${MODEL_PATH}" --app-name "${APP_NAME}" --port "${PORT}" --num-gpus "${NUM_GPUS}" --ray-address "${RAY_ADDRESS}" --tensor-parallel-size "${TENSOR_PARALLEL_SIZE}" ${PYTHON_ARGS}
PYTHON_EXIT_CODE=$?
set -e

if [ $PYTHON_EXIT_CODE -ne 0 ]; then
  echo -e "${RED}错误: Python脚本执行失败，退出代码: ${PYTHON_EXIT_CODE}${NC}"
  echo -e "${YELLOW}请检查Ray集群配置和Python环境${NC}"
  exit $PYTHON_EXIT_CODE
fi

echo -e "${GREEN}启动命令已执行${NC}"
echo -e "${BLUE}============================================${NC}"

# 如果成功启动，打印测试命令
echo -e "${GREEN}服务已启动，您可以使用以下命令进行测试:${NC}"
echo -e "${BLUE}python $(dirname "$0")/test_deepseek_int4.py --url http://localhost:${PORT}/${NC}"
echo -e "${BLUE}============================================${NC}" 