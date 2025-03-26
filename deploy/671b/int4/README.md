# DeepSeek-R1-Int4-AWQ 模型部署

本目录包含部署和管理 DeepSeek-R1-Int4-AWQ 模型的所有脚本和工具。

## 文件说明

| 文件名 | 说明 |
|-------|------|
| ray-deepseek-r1-int4.py | INT4模型部署主脚本 |
| ray-deepseek-r1-int4-amd.py | 适用于AMD/海光GPU的INT4部署脚本 |
| ray-deepseek-r1-int4-improved.py | 改进版INT4部署脚本(增强错误处理) |
| start_deepseek_int4.sh | 启动INT4模型服务的脚本 |
| start_deepseek_int4_amd.sh | 在AMD/海光GPU上启动INT4模型服务的脚本 |
| stop_deepseek_int4.py | 停止INT4模型服务的Python脚本 |
| stop_deepseek_int4_amd.sh | 停止AMD环境下INT4模型服务的Shell脚本 |
| test_deepseek_int4.py | 测试INT4模型服务的Python脚本 |
| README_AMD_GPU.md | AMD/海光GPU环境配置和部署指南 |

## 快速使用

### NVIDIA环境

```bash
# 启动服务
bash start_deepseek_int4.sh

# 测试服务
python test_deepseek_int4.py

# 停止服务
python stop_deepseek_int4.py
```

### AMD/海光环境

```bash
# 启动服务
bash start_deepseek_int4_amd.sh

# 测试服务
python test_deepseek_int4.py

# 停止服务
bash stop_deepseek_int4_amd.sh
```

## 配置选项

启动脚本支持多种配置选项，可使用`--help`查看详细参数：

```bash
bash start_deepseek_int4.sh --help
bash start_deepseek_int4_amd.sh --help
```

常用选项包括：
- `--model-path`: 指定模型路径
- `--debug`: 启用调试模式
- `--cpu-only`: 仅使用CPU (不推荐生产环境)

更多AMD特有选项请参考`README_AMD_GPU.md` 