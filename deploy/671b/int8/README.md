# DeepSeek-R1-Channel-INT8 模型部署

本目录包含部署和管理 DeepSeek-R1-Channel-INT8 模型的所有脚本和工具。

## 文件说明

| 文件名 | 说明 |
|-------|------|
| ray-deepseek-int8.py | INT8模型部署主脚本 |
| start_deepseek_int8.sh | 启动INT8模型服务的脚本 |
| stop_deepseek_int8.py | 停止INT8模型服务的Python脚本 |
| stop_deepseek_int8.sh | 停止INT8模型服务的Shell脚本 |
| test_deepseek_int8.py | 测试INT8模型服务的Python脚本 |
| upgrade_and_start.sh | 升级依赖库并启动INT8模型的脚本 |

## 快速使用

```bash
# 启动服务
bash start_deepseek_int8.sh

# 测试服务
python test_deepseek_int8.py

# 停止服务
bash stop_deepseek_int8.sh
```

## 配置选项

启动脚本支持多种配置选项：

```bash
# 指定模型路径
bash start_deepseek_int8.sh --model-path /path/to/model

# 不关闭已有部署
bash start_deepseek_int8.sh --no-shutdown

# 指定应用名称
bash start_deepseek_int8.sh --app-name my_custom_app_name
```

## 升级和部署

如果需要升级依赖库并部署模型，可以使用：

```bash
bash upgrade_and_start.sh
```

这将先升级vLLM和Ray等依赖项，然后部署模型。 