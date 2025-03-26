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
echo -e "${GREEN}停止 DeepSeek-R1-Int4-AWQ 模型服务 (AMD GPU)${NC}"
echo -e "${BLUE}============================================${NC}"

# 默认参数
APP_NAME="deepseek_r1_int4"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    *)
      echo -e "${RED}未知参数: $1${NC}"
      exit 1
      ;;
  esac
done

echo -e "${BLUE}准备停止应用: ${APP_NAME}${NC}"

# 使用Python脚本停止服务
python $(dirname "$0")/stop_deepseek_int4.py --app-name ${APP_NAME}

echo -e "${GREEN}停止服务命令已执行${NC}"
echo -e "${BLUE}============================================${NC}" 