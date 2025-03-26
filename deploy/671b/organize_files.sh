#!/bin/bash
set -e

# 定义颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}============================================${NC}"
echo -e "${GREEN}组织DeepSeek模型部署文件${NC}"
echo -e "${BLUE}============================================${NC}"

# 当前目录
CURRENT_DIR=$(pwd)
echo -e "${BLUE}当前目录: ${CURRENT_DIR}${NC}"

# 创建目录
mkdir -p int4 int8
echo -e "${BLUE}创建int4和int8目录${NC}"

# 确保权限
chmod +x int4 int8

# 移动INT4相关文件
echo -e "${BLUE}移动INT4相关文件...${NC}"
mv -f ray-deepseek-r1-int4.py int4/ 2>/dev/null || echo -e "${YELLOW}文件不存在: ray-deepseek-r1-int4.py${NC}"
mv -f ray-deepseek-r1-int4-amd.py int4/ 2>/dev/null || echo -e "${YELLOW}文件不存在: ray-deepseek-r1-int4-amd.py${NC}"
mv -f ray-deepseek-r1-int4-improved.py int4/ 2>/dev/null || echo -e "${YELLOW}文件不存在: ray-deepseek-r1-int4-improved.py${NC}"
mv -f ray-deepseek-int4.py int4/ 2>/dev/null || echo -e "${YELLOW}文件不存在: ray-deepseek-int4.py${NC}"
mv -f start_deepseek_int4.sh int4/ 2>/dev/null || echo -e "${YELLOW}文件不存在: start_deepseek_int4.sh${NC}"
mv -f start_deepseek_int4_amd.sh int4/ 2>/dev/null || echo -e "${YELLOW}文件不存在: start_deepseek_int4_amd.sh${NC}"
mv -f stop_deepseek_int4.py int4/ 2>/dev/null || echo -e "${YELLOW}文件不存在: stop_deepseek_int4.py${NC}"
mv -f stop_deepseek_int4_amd.sh int4/ 2>/dev/null || echo -e "${YELLOW}文件不存在: stop_deepseek_int4_amd.sh${NC}"
mv -f test_deepseek_int4.py int4/ 2>/dev/null || echo -e "${YELLOW}文件不存在: test_deepseek_int4.py${NC}"
mv -f README_AMD_GPU.md int4/ 2>/dev/null || echo -e "${YELLOW}文件不存在: README_AMD_GPU.md${NC}"

# 移动INT8相关文件
echo -e "${BLUE}移动INT8相关文件...${NC}"
mv -f ray-deepseek-int8.py int8/ 2>/dev/null || echo -e "${YELLOW}文件不存在: ray-deepseek-int8.py${NC}"
mv -f start_deepseek_int8.sh int8/ 2>/dev/null || echo -e "${YELLOW}文件不存在: start_deepseek_int8.sh${NC}"
mv -f stop_deepseek_int8.py int8/ 2>/dev/null || echo -e "${YELLOW}文件不存在: stop_deepseek_int8.py${NC}"
mv -f test_deepseek_int8.py int8/ 2>/dev/null || echo -e "${YELLOW}文件不存在: test_deepseek_int8.py${NC}"
mv -f upgrade_and_start.sh int8/ 2>/dev/null || echo -e "${YELLOW}文件不存在: upgrade_and_start.sh${NC}"

# 设置执行权限
echo -e "${BLUE}设置执行权限...${NC}"
chmod +x int4/*.sh int4/*.py int8/*.sh int8/*.py 2>/dev/null || echo -e "${YELLOW}部分文件可能不存在${NC}"

echo -e "${GREEN}文件组织完成！${NC}"
echo -e "${GREEN}INT4文件位于 int4/ 目录${NC}"
echo -e "${GREEN}INT8文件位于 int8/ 目录${NC}"
echo -e "${BLUE}============================================${NC}"

# 列出文件结构
echo -e "${BLUE}INT4目录文件:${NC}"
ls -la int4/
echo ""
echo -e "${BLUE}INT8目录文件:${NC}"
ls -la int8/ 