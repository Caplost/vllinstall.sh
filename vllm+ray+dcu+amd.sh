#!/bin/bash

# VLLM + Ray Docker 安装脚本
# 此脚本用于安装vllm+ray推理框架，采用Docker方式部署，不影响本机系统配置

# 设置颜色输出
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 打印信息函数
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 安装Docker (Ubuntu)
install_docker() {
    print_info "开始安装Docker..."
    
    # 更新包索引
    print_info "更新包索引..."
    sudo apt-get update
    
    # 安装必要的包以允许apt通过HTTPS使用存储库
    print_info "安装必要的依赖..."
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    
    # 添加阿里云Docker的GPG密钥
    print_info "添加阿里云Docker的GPG密钥..."
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo apt-key add -
    
    # 验证密钥
    print_info "验证密钥..."
    sudo apt-key fingerprint 0EBFCD88
    
    # 设置阿里云的Docker存储库
    print_info "设置阿里云的Docker存储库..."
    sudo add-apt-repository "deb [arch=amd64] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable"
    
    # 更新apt包索引
    print_info "再次更新apt包索引..."
    sudo apt-get update
    
    # 安装Docker CE
    print_info "安装Docker CE..."
    sudo apt-get install -y docker-ce
    
    # 启动Docker服务
    print_info "启动Docker服务..."
    sudo systemctl start docker
    
    # 设置Docker开机自启
    print_info "设置Docker开机自启..."
    sudo systemctl enable docker
    
    # 将当前用户添加到docker组，避免每次都需要sudo
    print_info "将当前用户添加到docker组..."
    sudo usermod -aG docker $USER
    
    print_info "Docker安装完成 ✓"
    print_warn "您需要注销并重新登录，或者重启系统以使docker组权限生效"
    print_warn "如果您想要立即使用Docker而不注销，请运行: 'newgrp docker'"
    
    # 提示用户立即使用Docker
    print_info "您想要立即使用Docker吗？(y/n)"
    read use_docker_now
    if [ "$use_docker_now" = "y" ] || [ "$use_docker_now" = "Y" ]; then
        newgrp docker
    else
        print_warn "请在安装完成后注销并重新登录，或者重启系统以使docker组权限生效"
        print_warn "脚本将继续执行，但可能需要使用sudo权限来运行docker命令"
    fi
}

# 检查Docker是否已安装
check_docker() {
    print_info "检查Docker是否已安装..."
    if ! command -v docker &> /dev/null; then
        print_warn "Docker未安装，是否现在安装? (y/n)"
        read install_docker_now
        if [ "$install_docker_now" = "y" ] || [ "$install_docker_now" = "Y" ]; then
            install_docker
        else
            print_error "Docker未安装，请先安装Docker后再运行此脚本"
            exit 1
        fi
    else
        print_info "Docker已安装 ✓"
    fi
}

# 获取项目绝对路径
get_project_path() {
    read -p "请输入项目挂载的绝对路径: " PROJECT_PATH
    
    if [ -z "$PROJECT_PATH" ]; then
        print_error "项目路径不能为空"
        get_project_path
    fi

    if [ ! -d "$PROJECT_PATH" ]; then
        print_warn "目录 $PROJECT_PATH 不存在，是否创建? (y/n)"
        read confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            mkdir -p "$PROJECT_PATH"
            print_info "已创建目录 $PROJECT_PATH"
        else
            print_error "请提供有效的项目路径"
            get_project_path
        fi
    fi

    echo "$PROJECT_PATH"
}

# 主函数
main() {
    print_info "开始安装VLLM+Ray推理框架 (Docker方式)..."
    
    # 检查Docker
    check_docker
    
    # 获取项目路径
    PROJECT_PATH=$(get_project_path)
    
    # 拉取指定的基础镜像
    print_info "拉取基础镜像..."
    docker pull image.sourcefind.cn:5000/dcu/admin/base/pytorch:2.3.0-ubuntu22.04-dtk24.04.3-py3.10
    
    # 获取镜像ID
    IMAGE_ID=$(docker images --format "{{.ID}}" image.sourcefind.cn:5000/dcu/admin/base/pytorch:2.3.0-ubuntu22.04-dtk24.04.3-py3.10)
    
    if [ -z "$IMAGE_ID" ]; then
        print_error "无法获取镜像ID，请检查镜像是否正确拉取"
        exit 1
    fi
    
    print_info "镜像ID: $IMAGE_ID"
    
    # 创建启动容器的脚本
    CONTAINER_SCRIPT="$PROJECT_PATH/start_vllm_container.sh"
    
    cat > "$CONTAINER_SCRIPT" << EOF
#!/bin/bash

# 启动VLLM+Ray容器
docker run --shm-size 500g \\
    --network=host \\
    --name=dpskv3 \\
    --privileged \\
    --device=/dev/kfd \\
    --device=/dev/dri \\
    --group-add video \\
    --cap-add=SYS_PTRACE \\
    --security-opt seccomp=unconfined \\
    -v ${PROJECT_PATH}:/home/ \\
    -v /opt/hyhal:/opt/hyhal:ro \\
    -it ${IMAGE_ID} bash
EOF
    
    chmod +x "$CONTAINER_SCRIPT"
    
    # 创建安装vllm和ray的脚本
    INSTALL_SCRIPT="$PROJECT_PATH/install_vllm_ray.sh"
    
    cat > "$INSTALL_SCRIPT" << EOF
#!/bin/bash

# 安装VLLM和Ray
echo "开始安装VLLM和Ray..."

# 安装lmslim
echo "安装lmslim..."
pip install https://download.sourcefind.cn:65024/directlink/4/lmslim/DAS1.3/lmslim-0.1.2+das.dtk24043-cp310-cp310-manylinux_2_28_x86_64.whl

# 安装vllm
echo "安装vllm..."
pip install https://download.sourcefind.cn:65024/directlink/4/vllm/DAS1.3/vllm-0.6.2+das.opt1.dtk24043-cp310-cp310-manylinux_2_28_x86_64.whl

# 安装ray
echo "安装ray..."
pip install ray[default]

echo "安装完成 ✓"
echo "可以通过以下命令启动ray:"
echo "ray start --head"
echo "可以通过以下命令验证vllm安装:"
echo "python -c 'import vllm; print(vllm.__version__)'"
EOF
    
    chmod +x "$INSTALL_SCRIPT"
    
    # 创建一个简单的README文件
    README_FILE="$PROJECT_PATH/README.md"
    
    cat > "$README_FILE" << EOF
# VLLM + Ray 推理框架

## 使用说明

1. 启动Docker容器:
   \`\`\`
   ./start_vllm_container.sh
   \`\`\`

2. 在Docker容器内安装VLLM和Ray:
   \`\`\`
   ./install_vllm_ray.sh
   \`\`\`

3. 启动Ray:
   \`\`\`
   ray start --head
   \`\`\`

4. 使用VLLM进行推理 (示例):
   \`\`\`python
   from vllm import LLM, SamplingParams
   
   # 初始化模型
   llm = LLM(model="your_model_path")
   
   # 设置采样参数
   sampling_params = SamplingParams(temperature=0.8, top_p=0.95)
   
   # 运行推理
   prompts = ["Hello, I am a language model,"]
   outputs = llm.generate(prompts, sampling_params)
   
   # 打印结果
   for output in outputs:
       print(output.outputs[0].text)
   \`\`\`
EOF
    
    print_info "安装脚本已准备完成"
    print_info "脚本位置:"
    print_info "  - 启动容器: $CONTAINER_SCRIPT"
    print_info "  - 安装VLLM和Ray: $INSTALL_SCRIPT"
    print_info "  - 使用说明: $README_FILE"
    print_info ""
    print_info "使用步骤:"
    print_info "1. 执行 $CONTAINER_SCRIPT 启动Docker容器"
    print_info "2. 在容器内执行 /home/install_vllm_ray.sh 安装VLLM和Ray"
    print_info "3. 按照README.md中的说明使用VLLM进行推理"
}

# 执行主函数
main