#!/bin/bash
# Ubuntu系统vLLM+Ray环境配置和检测脚本
# 适用于Ubuntu系统安装和检测vLLM运行环境
# 增强版：支持检测和选择额外挂载磁盘用于存储大型模型数据
# 多机版：支持Ray分布式部署，可配置为head节点或worker节点
#
# 使用方法:
#   1. 赋予脚本执行权限: chmod +x 此脚本.sh
#   2. 运行脚本: ./此脚本.sh  或  sudo ./此脚本.sh
#   3. 按照交互提示操作
#
# 脚本执行完成后:
#   - 单机模式: 使用 ./start_vllm_server.sh 启动vLLM服务器
#   - 多机模式: 
#      - 在head节点上运行: ./start_vllm_ray_head.sh
#      - 在worker节点上运行: ./start_vllm_ray_worker.sh
#   - 使用 python3 test_model.py --model 模型路径 测试模型
#
# 如果脚本中途退出，请检查错误信息并解决问题后重新运行

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 恢复默认颜色

# 配置文件路径
CONFIG_FILE="$HOME/.vllm_config.conf"

# 打印带有颜色的信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_section() {
    echo -e "\n${BLUE}======================= $1 =======================${NC}"
}

# 添加诊断函数来捕获和显示错误
handle_error() {
    print_error "脚本执行过程中遇到错误，退出码: $?"
    print_error "请检查上面的错误信息，解决问题后重新运行脚本"
    echo ""
    echo "如果您已经完成了部分配置，可以尝试:"
    echo "1. 如果已安装vLLM: 直接运行 ./start_vllm_server.sh (如果已生成)"
    echo "2. 如果已下载模型: 使用 python3 test_model.py --model 模型路径 测试模型"
    echo "3. 对于多机部署: 检查Ray集群状态 ray status"
    echo ""
    exit 1
}

# 设置错误处理
trap 'handle_error' ERR

# 添加调试功能
DEBUG=1  # 设置为1启用调试输出

debug_log() {
    if [ "$DEBUG" -eq 1 ]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1" >&2
    fi
}

# 读取配置
read_config() {
    local key=$1
    local default_value=$2
    
    if [ -f "$CONFIG_FILE" ]; then
        local value=$(grep "^$key=" "$CONFIG_FILE" | cut -d '=' -f 2)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    echo "$default_value"
    return 1
}

# 保存配置
save_config() {
    local key=$1
    local value=$2
    
    # 创建目录（如果不存在）
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null
    
    # 如果配置文件不存在，创建它
    if [ ! -f "$CONFIG_FILE" ]; then
        touch "$CONFIG_FILE"
    fi
    
    # 检查键是否已存在
    if grep -q "^$key=" "$CONFIG_FILE"; then
        # 更新现有键
        sed -i "s|^$key=.*|$key=$value|" "$CONFIG_FILE"
    else
        # 添加新键
        echo "$key=$value" >> "$CONFIG_FILE"
    fi
}

# 显示所有配置
show_config() {
    print_section "当前配置"
    
    if [ -f "$CONFIG_FILE" ]; then
        echo "配置文件: $CONFIG_FILE"
        echo "------------------------"
        cat "$CONFIG_FILE"
        echo "------------------------"
    else
        print_info "配置文件不存在，将使用默认值"
    fi
}

# 重置特定配置项
reset_config() {
    local key=$1
    
    if [ -f "$CONFIG_FILE" ] && grep -q "^$key=" "$CONFIG_FILE"; then
        sed -i "/^$key=/d" "$CONFIG_FILE"
        print_info "已重置配置: $key"
    fi
}

# 重置所有配置
reset_all_config() {
    if [ -f "$CONFIG_FILE" ]; then
        rm "$CONFIG_FILE"
        print_success "已重置所有配置"
    else
        print_info "配置文件不存在"
    fi
}

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_warning "此脚本需要root权限运行某些操作"
        print_warning "建议使用sudo运行: sudo $0"
        read -p "是否继续以非root用户运行? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "请使用 sudo ./$0 重新运行此脚本"
            exit 1
        fi
    fi
    
    # 检查必要的命令是否存在
    for cmd in python3 pip3 df grep awk; do
        if ! command -v $cmd &> /dev/null; then
            print_error "未找到必要的命令: $cmd"
            print_info "尝试安装必要的依赖..."
            if [ "$EUID" -ne 0 ]; then
                print_error "安装依赖需要root权限，请使用sudo运行此脚本"
                exit 1
            fi
            apt update && apt install -y python3 python3-pip python3-venv curl wget
            if ! command -v $cmd &> /dev/null; then
                print_error "安装依赖后仍未找到命令: $cmd"
                print_info "请手动安装所需的依赖后重试"
                exit 1
            fi
        fi
    done
}

# 检查系统信息
check_system() {
    print_section "系统信息检查"
    
    # 检查Ubuntu版本
    if [ -f /etc/lsb-release ]; then
        source /etc/lsb-release
        print_info "Ubuntu版本: $DISTRIB_RELEASE ($DISTRIB_DESCRIPTION)"
    else
        print_warning "无法确定Ubuntu版本"
    fi
    
    # 检查CPU信息
    cpu_model=$(grep "model name" /proc/cpuinfo | head -n 1 | cut -d ":" -f 2 | sed 's/^[ \t]*//')
    cpu_cores=$(grep -c "processor" /proc/cpuinfo)
    print_info "CPU型号: $cpu_model"
    print_info "CPU核心数: $cpu_cores"
    
    # 检查内存
    mem_total=$(free -h | grep "Mem" | awk '{print $2}')
    mem_available=$(free -h | grep "Mem" | awk '{print $7}')
    print_info "内存总量: $mem_total"
    print_info "可用内存: $mem_available"
    
    # 检查根分区磁盘空间
    disk_info=$(df -h / | grep -v "Filesystem")
    disk_total=$(echo "$disk_info" | awk '{print $2}')
    disk_used=$(echo "$disk_info" | awk '{print $3}')
    disk_avail=$(echo "$disk_info" | awk '{print $4}')
    print_info "根分区总量: $disk_total"
    print_info "根分区已用空间: $disk_used"
    print_info "根分区可用空间: $disk_avail"
    
    # 获取主机名和IP地址（多机部署需要）
    HOSTNAME=$(hostname)
    # 获取非本地回环的第一个IPv4地址
    PRIMARY_IP=$(hostname -I | awk '{print $1}')
    
    print_info "主机名: $HOSTNAME"
    print_info "IP地址: $PRIMARY_IP"
    
    # 保存到配置
    save_config "HOSTNAME" "$HOSTNAME"
    save_config "PRIMARY_IP" "$PRIMARY_IP"
}

# 检测所有挂载的磁盘并让用户选择
detect_storage_disks() {
    print_section "额外挂载磁盘检测"
    
    # 检查配置中是否已有选定的磁盘路径
    local saved_disk_path=$(read_config "SELECTED_DISK_PATH" "")
    
    if [ -n "$saved_disk_path" ] && [ -d "$saved_disk_path" ]; then
        print_info "使用已保存的磁盘路径: $saved_disk_path"
        SELECTED_DISK_PATH="$saved_disk_path"
        
        # 设置模型目录
        MODELS_DIR="$SELECTED_DISK_PATH/models"
        if [ ! -d "$MODELS_DIR" ]; then
            mkdir -p "$MODELS_DIR" 2>/dev/null || true
            print_info "创建模型目录: $MODELS_DIR"
        else
            print_info "使用已存在的模型目录: $MODELS_DIR"
        fi
        
        return 0
    fi
    
    # 获取挂载点、大小、可用空间等信息，排除根分区、临时分区、系统分区等
    print_info "检测额外挂载的磁盘..."
    
    debug_log "执行df命令获取磁盘列表"
    df_output=$(df -h)
    debug_log "df输出：\n$df_output"
    
    # 生成挂载磁盘列表，排除一些常见的系统目录
    mounted_disks=$(echo "$df_output" | grep -v "^Filesystem" | grep -v "tmpfs" | grep -v "udev" | grep -v "loop" | grep -v "overlay" | sort)
    debug_log "过滤后的磁盘列表：\n$mounted_disks"
    
    # 首先检查是否有额外磁盘
    disk_count=$(echo "$mounted_disks" | wc -l)
    
    if [ "$disk_count" -le 1 ] && [ -z "$mounted_disks" ]; then
        print_warning "未检测到额外挂载的磁盘，将使用默认存储位置"
        SELECTED_DISK_PATH="$(pwd)"
        return 0
    fi
    
    # 确保有磁盘列表时继续执行
    if [ -z "$mounted_disks" ]; then
        print_warning "未能获取磁盘列表，将使用当前目录"
        SELECTED_DISK_PATH="$(pwd)"
        return 0
    fi
    
    # 显示所有可用的磁盘
    echo -e "\n可用的存储磁盘："
    echo "------------------------------------------------------------"
    echo "  序号  |  挂载点  |  总容量  |  可用空间  |  使用率"
    echo "------------------------------------------------------------"
    
    # 构建磁盘列表数组
    declare -a disk_mountpoints
    declare -a disk_avail
    
    index=0
    if [ -n "$mounted_disks" ]; then
        while read -r line; do
            # 跳过空行
            [ -z "$line" ] && continue
            
            debug_log "处理磁盘行: $line"
            
            # 提取挂载点、容量信息
            mountpoint=$(echo "$line" | awk '{print $6}')
            size=$(echo "$line" | awk '{print $2}')
            avail=$(echo "$line" | awk '{print $4}')
            usage=$(echo "$line" | awk '{print $5}')
            
            debug_log "提取信息 - 挂载点: $mountpoint, 大小: $size, 可用: $avail, 使用率: $usage"
            
            # 跳过根分区
            if [ "$mountpoint" = "/" ]; then
                debug_log "跳过根分区"
                continue
            fi
            
            # 记录挂载点和可用空间
            disk_mountpoints[$index]="$mountpoint"
            disk_avail[$index]="$avail"
            
            # 显示磁盘信息
            echo "   $index    |  $mountpoint  |  $size  |  $avail  |  $usage"
            
            ((index++))
        done <<< "$mounted_disks"
    else
        debug_log "没有可用的磁盘列表"
    fi
    
    # 返回当前目录作为默认选项
    echo "   $index    |  当前目录  |  N/A  |  N/A  |  N/A"
    disk_mountpoints[$index]="$(pwd)"
    
    echo "------------------------------------------------------------"
    
    if [ $index -eq 0 ]; then
        print_warning "未找到额外的可用磁盘，将使用当前目录"
        SELECTED_DISK_PATH="$(pwd)"
        return 0
    fi
    
    # 让用户选择磁盘
    read -p "请选择用于存储vLLM数据的磁盘 [0-$index] (直接按Enter选择默认值): " disk_choice
    
    # 默认选择第一个磁盘
    if [ -z "$disk_choice" ]; then
        debug_log "用户未输入选择，使用默认值0"
        disk_choice=0
    fi
    
    debug_log "用户选择了磁盘: $disk_choice"
    
    # 验证输入
    if ! [[ "$disk_choice" =~ ^[0-9]+$ ]] || [ "$disk_choice" -gt "$index" ]; then
        print_error "无效的选择，将使用当前目录"
        SELECTED_DISK_PATH="$(pwd)"
    else
        SELECTED_DISK_PATH="${disk_mountpoints[$disk_choice]}"
        print_success "已选择磁盘: $SELECTED_DISK_PATH"
        
        # 检查目录权限
        if [ ! -w "$SELECTED_DISK_PATH" ]; then
            print_warning "当前用户可能没有该目录的写入权限"
            read -p "是否尝试创建一个新的子目录? (y/n) [y]: " create_subdir
            create_subdir=${create_subdir:-y}
            
            if [[ $create_subdir =~ ^[Yy]$ ]]; then
                read -p "请输入子目录名称 [vllm-data]: " subdir_name
                subdir_name=${subdir_name:-vllm-data}
                
                if mkdir -p "$SELECTED_DISK_PATH/$subdir_name" 2>/dev/null; then
                    SELECTED_DISK_PATH="$SELECTED_DISK_PATH/$subdir_name"
                    print_success "成功创建目录: $SELECTED_DISK_PATH"
                else
                    print_error "无法创建目录，将使用当前目录"
                    SELECTED_DISK_PATH="$(pwd)"
                fi
            else
                print_warning "将使用当前目录"
                SELECTED_DISK_PATH="$(pwd)"
            fi
        fi
    fi
    
    # 创建vLLM数据目录
    if [ "$SELECTED_DISK_PATH" != "$(pwd)" ]; then
        # 在选定的磁盘上创建vLLM数据目录
        vllm_data_dir="$SELECTED_DISK_PATH/vllm-data"
        
        if [ ! -d "$vllm_data_dir" ]; then
            print_info "在选定磁盘上创建vLLM数据目录: $vllm_data_dir"
            mkdir -p "$vllm_data_dir" 2>/dev/null || true
            
            if [ -d "$vllm_data_dir" ]; then
                SELECTED_DISK_PATH="$vllm_data_dir"
                print_success "已创建vLLM数据目录: $SELECTED_DISK_PATH"
            fi
        else
            SELECTED_DISK_PATH="$vllm_data_dir"
            print_info "使用已存在的vLLM数据目录: $SELECTED_DISK_PATH"
        fi
    fi
    
    # 验证最终选择的路径
    print_info "vLLM数据将存储在: $SELECTED_DISK_PATH"
    
    # 保存选择到配置文件
    save_config "SELECTED_DISK_PATH" "$SELECTED_DISK_PATH"
    
    # 查看磁盘可用空间
    if [ -d "$SELECTED_DISK_PATH" ]; then
        avail_space=$(df -h "$SELECTED_DISK_PATH" | grep -v "Filesystem" | awk '{print $4}')
        print_info "可用空间: $avail_space"
    fi
    
    # 创建模型目录
    MODELS_DIR="$SELECTED_DISK_PATH/models"
    if [ ! -d "$MODELS_DIR" ]; then
        print_info "创建模型目录: $MODELS_DIR"
        mkdir -p "$MODELS_DIR" 2>/dev/null || true
    else
        print_info "使用已存在的模型目录: $MODELS_DIR"
    fi
    
    return 0
}

# 检查GPU和CUDA
check_gpu() {
    print_section "GPU和CUDA检查"
    
    # 检查是否安装nvidia-smi
    if command -v nvidia-smi &> /dev/null; then
        # 获取GPU信息
        print_info "GPU信息:"
        nvidia-smi -L
        
        # 获取CUDA版本
        cuda_version=$(nvidia-smi | grep "CUDA Version" | awk '{print $9}')
        if [ -n "$cuda_version" ]; then
            print_info "CUDA版本: $cuda_version"
        else
            print_warning "无法检测CUDA版本"
        fi
        
        # 获取GPU显存信息
        print_info "GPU显存信息:"
        nvidia-smi --query-gpu=index,name,memory.total,memory.used --format=csv,noheader
        
        # 检查驱动版本
        driver_version=$(nvidia-smi | grep "Driver Version" | awk '{print $3}')
        print_info "NVIDIA驱动版本: $driver_version"
        
        # 保存GPU数量到配置
        gpu_count=$(nvidia-smi -L | wc -l)
        save_config "GPU_COUNT" "$gpu_count"
        print_info "检测到GPU数量: $gpu_count"
    else
        print_error "未安装nvidia-smi，无法检测GPU信息"
        print_info "您可以尝试安装NVIDIA驱动:"
        print_info "  sudo apt update"
        print_info "  sudo apt install -y nvidia-driver-535 nvidia-utils-535"
        print_info "安装后需要重启系统"
        return 1
    fi
    
    # 检查CUDA_HOME环境变量
    if [ -n "$CUDA_HOME" ]; then
        print_info "CUDA_HOME: $CUDA_HOME"
    else
        print_warning "CUDA_HOME环境变量未设置"
    fi
    
    # 检查nvcc
    if command -v nvcc &> /dev/null; then
        nvcc_version=$(nvcc --version | grep "release" | awk '{print $5}' | cut -d ',' -f 1)
        print_info "NVCC版本: $nvcc_version"
    else
        print_warning "未找到nvcc，可能未安装CUDA工具包"
        print_info "您可以尝试安装CUDA工具包:"
        print_info "  sudo apt install -y cuda-toolkit-11-8"
    fi
}

# 检查并安装Python环境
check_python() {
    print_section "Python环境检查"
    
    # 检查Python版本
    if command -v python3 &> /dev/null; then
        python_version=$(python3 --version)
        print_info "Python版本: $python_version"
        
        # 检查Python版本是否满足要求
        py_major=$(python3 -c "import sys; print(sys.version_info.major)")
        py_minor=$(python3 -c "import sys; print(sys.version_info.minor)")
        
        if [ "$py_major" -eq 3 ] && [ "$py_minor" -ge 8 ]; then
            print_success "Python版本满足要求 (3.8+)"
        else
            print_warning "Python版本较低，建议升级到3.8+"
            print_info "正在尝试安装Python 3.8..."
            
            # 如果是root用户，尝试安装Python 3.8
            if [ "$EUID" -eq 0 ]; then
                apt update && apt install -y python3.8 python3.8-dev python3.8-venv python3-pip
                print_info "请重新运行脚本使用新安装的Python 3.8"
            else
                print_info "需要root权限安装Python 3.8:"
                print_info "  sudo apt install -y python3.8 python3.8-dev python3.8-venv python3-pip"
            fi
        fi
    else
        print_error "未安装Python 3"
        print_info "尝试安装Python 3..."
        
        # 如果是root用户，尝试安装Python 3
        if [ "$EUID" -eq 0 ]; then
            apt update && apt install -y python3 python3-dev python3-pip python3-venv
        else
            print_info "需要root权限安装Python 3:"
            print_info "  sudo apt install -y python3 python3-dev python3-pip python3-venv"
            exit 1
        fi
    fi
    
    # 确保pip已安装
    if ! command -v pip3 &> /dev/null; then
        print_warning "未安装pip3，正在尝试安装..."
        
        # 如果是root用户，尝试安装pip
        if [ "$EUID" -eq 0 ]; then
            apt update && apt install -y python3-pip
        else
            print_info "需要root权限安装pip3:"
            print_info "  sudo apt install -y python3-pip"
            exit 1
        fi
    fi
    
    # 再次检查pip
    if command -v pip3 &> /dev/null; then
        pip_version=$(pip3 --version)
        print_info "pip版本: $pip_version"
    else
        print_error "pip3安装失败，请手动安装后重试"
        exit 1
    fi
}

# 设置Python虚拟环境
setup_virtualenv() {
    print_section "Python虚拟环境设置"
    
    # 检查配置中是否已有虚拟环境设置
    local saved_venv_path=$(read_config "VENV_PATH" "")
    
    if [ -n "$saved_venv_path" ] && [ -d "$saved_venv_path" ]; then
        print_info "使用已保存的虚拟环境: $saved_venv_path"
        
        # 询问是否激活环境
        read -p "激活此环境? (y/n) [y]: " activate_saved
        activate_saved=${activate_saved:-y}
        
        if [[ $activate_saved =~ ^[Yy]$ ]]; then
            source "$saved_venv_path/bin/activate"
            
            if [ $? -eq 0 ]; then
                print_success "虚拟环境激活成功"
                VENV_ACTIVE=1
                VENV_PATH="$saved_venv_path"
                return 0
            else
                print_error "激活已保存的虚拟环境失败"
                # 从配置中删除无效的虚拟环境设置
                reset_config "VENV_PATH"
                # 继续创建新环境
            fi
        else
            print_info "跳过环境激活"
            return 0
        fi
    fi
    
    # 询问是否使用虚拟环境
    print_info "虚拟环境可以隔离项目依赖，防止与系统Python冲突"
    read -p "是否使用Python虚拟环境? (y/n) [y]: " use_venv
    use_venv=${use_venv:-y}  # 默认为y
    
    if [[ ! $use_venv =~ ^[Yy]$ ]]; then
        print_info "跳过虚拟环境设置，将使用系统Python"
        return 0
    fi
    
    # 检查venv模块
    if ! python3 -c "import venv" &> /dev/null; then
        print_warning "未安装Python venv模块"
        print_info "正在安装venv模块..."
        
        # 如果是root用户，直接安装venv
        if [ "$EUID" -eq 0 ]; then
            apt update && apt install -y python3-venv
        else
            print_info "需要root权限安装venv模块:"
            print_info "  sudo apt install -y python3-venv"
            # 尝试使用sudo安装
            sudo apt update && sudo apt install -y python3-venv || {
                print_error "安装venv模块失败，请手动安装后重试"
                exit 1
            }
        fi
    fi
    
    # 再次检查venv模块
    if ! python3 -c "import venv" &> /dev/null; then
        print_error "venv模块安装失败，请手动安装后重试"
        exit 1
    fi
    
    # 询问虚拟环境名称和位置
    read -p "请输入虚拟环境名称 [vllm-env]: " venv_name
    venv_name=${venv_name:-vllm-env}  # 默认为vllm-env
    
    # 使用选定的磁盘路径作为虚拟环境的基础路径
    if [ -n "$SELECTED_DISK_PATH" ] && [ "$SELECTED_DISK_PATH" != "$(pwd)" ]; then
        default_venv_path="$SELECTED_DISK_PATH/$venv_name"
        read -p "虚拟环境路径 [$default_venv_path]: " venv_path
        venv_path=${venv_path:-$default_venv_path}
    else
        read -p "虚拟环境路径 [./$venv_name]: " venv_path
        venv_path=${venv_path:-./$venv_name}
    fi
    
    # 检查环境是否存在
    if [ -d "$venv_path" ]; then
        print_info "虚拟环境'$venv_path'已存在"
        read -p "激活此环境? (y/n) [y]: " activate_existing
        activate_existing=${activate_existing:-y}  # 默认为y
        
        if [[ $activate_existing =~ ^[Yy]$ ]]; then
            print_info "激活环境: $venv_path"
            source "$venv_path/bin/activate"
            
            if [ $? -eq 0 ]; then
                print_success "虚拟环境'$venv_path'激活成功"
                # 设置全局变量表示当前在虚拟环境中
                VENV_ACTIVE=1
                VENV_PATH="$venv_path"
                
                # 保存到配置文件
                save_config "VENV_PATH" "$venv_path"
            else
                print_error "激活环境失败"
                return 1
            fi
        else
            print_info "跳过环境激活"
            return 0
        fi
    else
        # 创建虚拟环境目录
        parent_dir=$(dirname "$venv_path")
        if [ ! -d "$parent_dir" ]; then
            mkdir -p "$parent_dir"
        fi
        
        print_info "创建新的虚拟环境: $venv_path"
        python3 -m venv "$venv_path"
        
        if [ $? -eq 0 ]; then
            print_success "虚拟环境创建成功"
            print_info "激活环境..."
            source "$venv_path/bin/activate"
            
            if [ $? -eq 0 ]; then
                print_success "虚拟环境激活成功"
                print_info "当前Python路径: $(which python3)"
                # 设置全局变量表示当前在虚拟环境中
                VENV_ACTIVE=1
                VENV_PATH="$venv_path"
                
                # 保存到配置文件
                save_config "VENV_PATH" "$venv_path"
            else
                print_error "激活环境失败"
                return 1
            fi
        else
            print_error "创建虚拟环境失败"
            return 1
        fi
    fi
    
    # 检查pip并更新
    print_info "更新pip..."
    pip install --upgrade pip
    
    return 0
}

# 检查Python依赖包
check_pip_packages() {
    print_section "Python依赖包检查"
    
    required_packages=("torch" "transformers" "vllm" "accelerate" "ray")
    missing_packages=()
    
    # 检查各个包的安装状态
    for pkg in "${required_packages[@]}"; do
        if pip list 2>/dev/null | grep -q "^$pkg "; then
            version=$(pip list 2>/dev/null | grep "^$pkg " | awk '{print $2}')
            print_info "$pkg 已安装，版本: $version"
        else
            print_warning "$pkg 未安装"
            missing_packages+=("$pkg")
        fi
    done
    
    # 设置缺失包标志
    if [ ${#missing_packages[@]} -gt 0 ]; then
        MISSING_PACKAGES=1
        print_warning "检测到有 ${#missing_packages[@]} 个必要包未安装: ${missing_packages[*]}"
    else
        MISSING_PACKAGES=0
    fi
    
    # 检查PyTorch是否支持CUDA
    if pip list 2>/dev/null | grep -q "^torch "; then
        print_info "检查PyTorch CUDA支持..."
        if python3 -c "import torch; print(f'CUDA可用: {torch.cuda.is_available()}'); print(f'CUDA版本: {torch.version.cuda if torch.cuda.is_available() else \"N/A\"}'); print(f'GPU数量: {torch.cuda.device_count() if torch.cuda.is_available() else 0}')" 2>/dev/null; then
            print_success "PyTorch CUDA支持检查完成"
        else
            print_error "PyTorch无法正确检测CUDA"
            TORCH_CUDA_ERROR=1
        fi
    fi
    
    # 检查Ray是否安装
    if pip list 2>/dev/null | grep -q "^ray "; then
        print_info "检查Ray分布式支持..."
        if python3 -c "import ray; print(f'Ray版本: {ray.__version__}'); print('Ray分布式框架可用')" 2>/dev/null; then
            print_success "Ray分布式框架检查完成"
        else
            print_error "Ray框架检查失败"
            RAY_ERROR=1
        fi
    fi
}

# 选择镜像站点
select_mirror() {
    print_section "选择镜像站点"
    
    # 检查配置中是否已有镜像设置
    local saved_mirror=$(read_config "HF_MIRROR" "")
    
    if [ -n "$saved_mirror" ]; then
        print_info "使用已保存的镜像: $saved_mirror"
        HF_MIRROR="$saved_mirror"
        # 设置环境变量
        export HF_ENDPOINT=$HF_MIRROR
        print_success "已设置HF_ENDPOINT=$HF_MIRROR"
        return 0
    fi
    
    # 检查是否在中国区域，默认建议使用镜像
    if ping -c 1 baidu.com &> /dev/null 2>&1; then
        print_info "检测到可能在中国区域，建议使用镜像加速下载"
    fi
    
    echo "请选择模型下载镜像站点以加速下载:"
    echo "1) 官方地址 (huggingface.co)"
    echo "2) HF Mirror (hf-mirror.com) - 推荐"
    echo "3) 百度飞桨镜像 (mirror.baidu.com)"
    echo "4) 清华大学TUNA镜像 (mirrors.tuna.tsinghua.edu.cn)"
    echo "5) 上海交通大学镜像 (mirror.sjtu.edu.cn)"
    
    read -p "选择镜像 [2]: " mirror_choice
    mirror_choice=${mirror_choice:-2}  # 默认选择2 (hf-mirror.com)
    
    case $mirror_choice in
        1) 
            HF_MIRROR=""
            print_info "使用官方地址下载"
            ;;
        2) 
            HF_MIRROR="https://hf-mirror.com"
            print_info "使用HF Mirror (hf-mirror.com)"
            ;;
        3) 
            HF_MIRROR="https://mirror.baidu.com/huggingface/"
            print_info "使用百度飞桨镜像"
            ;;
        4) 
            HF_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/huggingface-model-hub"
            print_info "使用清华大学TUNA镜像"
            ;;
        5) 
            HF_MIRROR="https://mirror.sjtu.edu.cn/huggingface-model-hub"
            print_info "使用上海交通大学镜像"
            ;;
        *) 
            HF_MIRROR="https://hf-mirror.com"
            print_warning "无效选择，使用HF Mirror作为默认镜像"
            ;;
    esac
    
    # 设置环境变量
    if [ -n "$HF_MIRROR" ]; then
        export HF_ENDPOINT=$HF_MIRROR
        print_success "已设置HF_ENDPOINT=$HF_MIRROR"
        
        # 保存到配置文件
        save_config "HF_MIRROR" "$HF_MIRROR"
    fi
}

# 安装vLLM和Ray
install_vllm_ray() {
    print_section "vLLM和Ray安装"
    
    # 确保虚拟环境已激活（如果有）
    if [ -n "$VENV_PATH" ] && [ -z "$VENV_ACTIVE" ]; then
        print_info "激活虚拟环境: $VENV_PATH"
        source "$VENV_PATH/bin/activate"
        if [ $? -eq 0 ]; then
            VENV_ACTIVE=1
        else
            print_error "激活虚拟环境失败，继续安装但可能会影响系统Python环境"
        fi
    fi
    
    print_info "安装PyTorch (带CUDA支持)..."
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
    
    if [ $? -ne 0 ]; then
        print_error "PyTorch安装失败，尝试使用国内镜像..."
        # 尝试使用国内镜像
        pip install torch torchvision torchaudio -i https://pypi.tuna.tsinghua.edu.cn/simple
        
        if [ $? -ne 0 ]; then
            print_error "PyTorch安装失败，请手动安装后继续"
            return 1
        fi
    fi
    
    print_info "安装vLLM及依赖..."
    pip install vllm transformers accelerate
    
    if [ $? -ne 0 ]; then
        print_error "vLLM安装失败，尝试使用国内镜像..."
        # 尝试使用国内镜像
        pip install vllm transformers accelerate -i https://pypi.tuna.tsinghua.edu.cn/simple
        
        if [ $? -ne 0 ]; then
            print_error "vLLM安装失败，请检查错误信息"
            return 1
        fi
    fi
    
    print_info "安装Ray分布式框架..."
    pip install ray[default]
    
    if [ $? -ne 0 ]; then
        print_error "Ray安装失败，尝试使用国内镜像..."
        # 尝试使用国内镜像
        pip install ray[default] -i https://pypi.tuna.tsinghua.edu.cn/simple
        
        if [ $? -ne 0 ]; then
            print_error "Ray安装失败，请检查错误信息"
            return 1
        fi
    fi
    
    # 验证安装
    if pip list 2>/dev/null | grep -q "^vllm "; then
        vllm_version=$(pip list 2>/dev/null | grep "^vllm " | awk '{print $2}')
        print_success "vLLM已安装，版本: $vllm_version"
    else
        print_error "vLLM安装验证失败"
        return 1
    fi
    
    if pip list 2>/dev/null | grep -q "^ray "; then
        ray_version=$(pip list 2>/dev/null | grep "^ray " | awk '{print $2}')
        print_success "Ray已安装，版本: $ray_version"
    else
        print_error "Ray安装验证失败"
        return 1
    fi
}

# 下载模型
download_model() {
    print_section "下载模型"
    
    # 选择镜像站点
    select_mirror
    
    print_info "可用的模型选项:"
    echo "1) TinyLlama-1.1B (约2.5GB，适合测试验证)" 
    echo "2) deepseek-ai/deepseek-llm-7b-base (约14GB)"
    echo "3) deepseek-ai/deepseek-llm-7b-chat (约14GB)"
    echo "4) deepseek-ai/deepseek-coder-7b-instruct (约14GB)"
    echo "5) deepseek-ai/deepseek-llm-67b-base (约130GB)"
    echo "6) Qwen/Qwen1.5-7B (约14GB)"
    echo "7) Qwen/Qwen1.5-7B-Chat (约14GB)"
    echo "8) THUDM/chatglm3-6b (约12GB)"
    echo "9) 01-ai/Yi-6B-Chat (约12GB)"
    echo "10) 输入自定义模型ID"
    echo "0) 跳过下载"
    
    read -p "选择模型 (输入数字) [1]: " model_choice
    model_choice=${model_choice:-1}  # 默认选择1 (TinyLlama-1.1B)
    
    case $model_choice in
        1) model_id="TinyLlama/TinyLlama-1.1B-Chat-v1.0" ;;
        2) model_id="deepseek-ai/deepseek-llm-7b-base" ;;
        3) model_id="deepseek-ai/deepseek-llm-7b-chat" ;;
        4) model_id="deepseek-ai/deepseek-coder-7b-instruct" ;;
        5) model_id="deepseek-ai/deepseek-llm-67b-base" ;;
        6) model_id="Qwen/Qwen1.5-7B" ;;
        7) model_id="Qwen/Qwen1.5-7B-Chat" ;;
        8) model_id="THUDM/chatglm3-6b" ;;
        9) model_id="01-ai/Yi-6B-Chat" ;;
        10) 
            read -p "请输入Hugging Face模型ID (例如 'facebook/opt-350m'): " custom_model_id
            if [ -z "$custom_model_id" ]; then
                print_error "模型ID不能为空"
                return 1
            fi
            model_id="$custom_model_id"
            ;;
        0) print_info "跳过模型下载"; return 0 ;;
        *) 
            if [ "$model_choice" -gt 10 ] || [ "$model_choice" -lt 0 ]; then
                print_error "无效选择"
                return 1
            fi
            ;;
    esac
    
    # 使用选定的磁盘路径作为下载目录
    if [ -n "$MODELS_DIR" ]; then
        default_download_dir="$MODELS_DIR"
    else
        default_download_dir="./models"
    fi
    
    read -p "输入下载目录 [$default_download_dir]: " download_dir
    download_dir=${download_dir:-$default_download_dir}
    
    # 确保目录存在
    if [ ! -d "$download_dir" ]; then
        print_info "创建目录: $download_dir"
        mkdir -p $download_dir
    fi
    
    print_info "安装huggingface_hub..."
    pip install huggingface_hub
    
    # 检查目录权限
    if [ ! -w "$download_dir" ]; then
        print_error "没有写入权限: $download_dir"
        return 1
    fi
    
    # 估算模型大小和所需空间
    # 从模型ID尝试判断大小
    required_space=3
    if [[ "$model_id" == *"1.1B"* || "$model_id" == *"1B"* || "$model_id" == *"1-B"* ]]; then
        required_space=3
    elif [[ "$model_id" == *"3b"* || "$model_id" == *"3B"* ]]; then
        required_space=7
    elif [[ "$model_id" == *"6b"* || "$model_id" == *"6B"* || "$model_id" == *"7b"* || "$model_id" == *"7B"* ]]; then
        required_space=15
    elif [[ "$model_id" == *"13b"* || "$model_id" == *"13B"* ]]; then
        required_space=30
    elif [[ "$model_id" == *"30b"* || "$model_id" == *"30B"* || "$model_id" == *"33b"* || "$model_id" == *"33B"* ]]; then
        required_space=70
    elif [[ "$model_id" == *"65b"* || "$model_id" == *"65B"* || "$model_id" == *"67b"* || "$model_id" == *"67B"* || "$model_id" == *"70b"* || "$model_id" == *"70B"* ]]; then
        required_space=130
    else
        # 对于未知大小的模型，假设为7B大小
        required_space=15
        print_warning "无法估计模型大小，默认假设需要约15GB空间"
    fi
    
    # 检查磁盘空间
    avail_space=$(df -h "$download_dir" | grep -v "Filesystem" | awk '{print $4}')
    print_info "目标目录可用空间: $avail_space"
    print_info "估计所需空间: ${required_space}GB"
    
    # 警告如果空间可能不足
    avail_space_num=$(df "$download_dir" | grep -v "Filesystem" | awk '{print $4}')
    avail_space_gb=$(echo "scale=2; $avail_space_num/1024/1024" | bc)
    if (( $(echo "$avail_space_gb < $required_space" | bc -l) )); then
        print_warning "警告: 可用空间可能不足以下载此模型 (需要约${required_space}GB)"
        read -p "是否继续? (y/n) [n]: " continue_download
        continue_download=${continue_download:-n}
        
        if [[ ! $continue_download =~ ^[Yy]$ ]]; then
            print_info "取消下载"
            return 0
        fi
    fi
    
    print_info "正在下载 $model_id 到 $download_dir..."
    
    # 如果设置了镜像，使用镜像下载
    if [ -n "$HF_MIRROR" ]; then
        print_info "使用镜像: $HF_MIRROR"
        python3 -c "import os; from huggingface_hub import snapshot_download; os.environ['HF_ENDPOINT'] = os.environ.get('HF_ENDPOINT', ''); print(f'使用镜像: {os.environ[\"HF_ENDPOINT\"]}' if os.environ[\"HF_ENDPOINT\"] else '使用官方地址'); snapshot_download(repo_id='$model_id', local_dir='$download_dir/$model_id', local_dir_use_symlinks=False)"
    else
        python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='$model_id', local_dir='$download_dir/$model_id', local_dir_use_symlinks=False)"
    fi
    
    download_status=$?
    if [ $download_status -eq 0 ]; then
        print_success "模型下载完成: $download_dir/$model_id"
        DOWNLOADED_MODEL="$download_dir/$model_id"
    else
        print_error "模型下载失败 (错误码: $download_status)"
        print_info "尝试使用以下命令手动下载:"
        print_info "HF_ENDPOINT=$HF_MIRROR python -c \"from huggingface_hub import snapshot_download; snapshot_download(repo_id='$model_id', local_dir='$download_dir/$model_id')\""
        return 1
    fi
}

# 配置分布式模式
configure_distributed_mode() {
    print_section "分布式模式配置"
    
    # 检查配置中是否已有分布式设置
    local saved_mode=$(read_config "DISTRIBUTED_MODE" "")
    local saved_role=$(read_config "NODE_ROLE" "")
    local saved_head_ip=$(read_config "HEAD_NODE_IP" "")
    local saved_port=$(read_config "RAY_PORT" "")
    
    # 询问是否使用分布式模式
    local use_dist
    if [ -n "$saved_mode" ]; then
        print_info "已保存的部署模式: $saved_mode"
        read -p "是否使用已保存的部署模式? (y/n) [y]: " use_saved_mode
        use_saved_mode=${use_saved_mode:-y}
        
        if [[ $use_saved_mode =~ ^[Yy]$ ]]; then
            DISTRIBUTED_MODE="$saved_mode"
            
            if [ "$DISTRIBUTED_MODE" = "single" ]; then
                print_info "使用单机模式"
                save_config "DISTRIBUTED_MODE" "single"
                return 0
            fi
            
            NODE_ROLE="$saved_role"
            HEAD_NODE_IP="$saved_head_ip"
            RAY_PORT="$saved_port"
            
            print_info "节点角色: $NODE_ROLE"
            print_info "Head节点IP: $HEAD_NODE_IP"
            print_info "Ray端口: $RAY_PORT"
            return 0
        fi
    fi
    
    echo "请选择部署模式:"
    echo "1) 单机模式 - 仅在当前机器上运行vLLM"
    echo "2) 分布式模式 - 使用Ray在多台机器上运行vLLM"
    
    read -p "选择部署模式 [1]: " deployment_choice
    deployment_choice=${deployment_choice:-1}  # 默认单机模式
    
    if [ "$deployment_choice" = "1" ]; then
        print_info "使用单机模式"
        DISTRIBUTED_MODE="single"
        save_config "DISTRIBUTED_MODE" "single"
        return 0
    fi
    
    DISTRIBUTED_MODE="distributed"
    save_config "DISTRIBUTED_MODE" "distributed"
    
    echo "在分布式模式中，需要一个head节点和多个worker节点:"
    echo "1) Head节点 - 负责协调整个集群 (每个集群只设置一个)"
    echo "2) Worker节点 - 执行计算任务 (可以有多个)"
    
    read -p "此机器的角色 [1]: " role_choice
    role_choice=${role_choice:-1}  # 默认为head节点
    
    if [ "$role_choice" = "1" ]; then
        NODE_ROLE="head"
        
        # 获取本机IP地址
        local default_ip=$PRIMARY_IP
        
        read -p "输入Head节点IP地址（其他节点将连接到此地址）[$default_ip]: " head_node_ip
        head_node_ip=${head_node_ip:-$default_ip}
        
        HEAD_NODE_IP="$head_node_ip"
    else
        NODE_ROLE="worker"
        
        # 询问head节点的IP地址
        read -p "输入Head节点的IP地址: " head_node_ip
        
        if [ -z "$head_node_ip" ]; then
            print_error "Head节点IP地址不能为空"
            return 1
        fi
        
        HEAD_NODE_IP="$head_node_ip"
    fi
    
    # 配置Ray端口
    read -p "输入Ray服务端口 [6379]: " ray_port
    ray_port=${ray_port:-6379}
    RAY_PORT="$ray_port"
    
    # 如果是worker节点，测试与head节点的连接
    if [ "$NODE_ROLE" = "worker" ]; then
        print_info "测试与Head节点 ($HEAD_NODE_IP:$RAY_PORT) 的连接..."
        
        if ping -c 1 -W 2 "$HEAD_NODE_IP" &> /dev/null; then
            print_success "可以ping通Head节点"
        else
            print_warning "无法ping通Head节点，请确保网络连接正常且IP地址正确"
        fi
        
        if nc -z -w 2 "$HEAD_NODE_IP" "$RAY_PORT" &> /dev/null; then
            print_success "可以连接到Head节点的Ray端口"
        else
            print_warning "无法连接到Head节点的Ray端口，请确保Head节点已启动Ray服务"
            print_info "如果Head节点尚未启动，可以忽略此警告"
        fi
    fi
    
    # 保存配置
    save_config "NODE_ROLE" "$NODE_ROLE"
    save_config "HEAD_NODE_IP" "$HEAD_NODE_IP"
    save_config "RAY_PORT" "$RAY_PORT"
    
    print_success "分布式模式配置完成"
    print_info "节点角色: $NODE_ROLE"
    print_info "Head节点IP: $HEAD_NODE_IP"
    print_info "Ray端口: $RAY_PORT"
}

# 生成vLLM启动脚本
generate_startup_script() {
    print_section "生成启动脚本"
    
    # 检测GPU数量
    if command -v nvidia-smi &> /dev/null; then
        gpu_count=$(nvidia-smi -L | wc -l)
        print_info "检测到 $gpu_count 个GPU"
    else
        gpu_count=1
        print_warning "无法检测GPU数量，默认设置为1"
    fi
    
    # 检测是否存在已下载的模型
    if [ -n "$DOWNLOADED_MODEL" ]; then
        print_info "使用已下载的模型: $DOWNLOADED_MODEL"
        model_path="$DOWNLOADED_MODEL"
    else
        # 检测是否已下载模型
        local_models_dir="${MODELS_DIR:-./models}"
        
        if [ -d "$local_models_dir" ]; then
            available_models=$(find "$local_models_dir" -mindepth 1 -maxdepth 2 -type d -printf "%f\n" 2>/dev/null || ls -1 "$local_models_dir" 2>/dev/null)
            if [ -n "$available_models" ]; then
                print_info "本地可用模型:"
                echo "$available_models" | cat -n
                read -p "选择模型 (输入数字，0表示手动输入) [1]: " model_num
                model_num=${model_num:-1}  # 默认选择1
                
                if [ "$model_num" -eq 0 ]; then
                    read -p "输入模型路径或Hugging Face模型ID: " model_path
                else
                    selected_model=$(echo "$available_models" | sed -n "${model_num}p")
                    if [ -z "$selected_model" ]; then
                        print_warning "无效的选择，使用默认模型"
                        model_path="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
                    else
                        model_path="$local_models_dir/$selected_model"
                    fi
                fi
            else
                read -p "输入模型路径或Hugging Face模型ID [TinyLlama/TinyLlama-1.1B-Chat-v1.0]: " model_path
                model_path=${model_path:-"TinyLlama/TinyLlama-1.1B-Chat-v1.0"}
            fi
        else
            read -p "输入模型路径或Hugging Face模型ID [TinyLlama/TinyLlama-1.1B-Chat-v1.0]: " model_path
            model_path=${model_path:-"TinyLlama/TinyLlama-1.1B-Chat-v1.0"}
        fi
    fi
    
    # 保存模型路径到配置
    save_config "MODEL_PATH" "$model_path"
    
    # 量化选项
    read -p "是否使用量化以减少内存使用? (y/n) [n]: " use_quant
    use_quant=${use_quant:-n}
    
    if [[ $use_quant =~ ^[Yy]$ ]]; then
        quant_option="--quantization awq"
        save_config "QUANT_OPTION" "--quantization awq"
    else
        quant_option=""
        save_config "QUANT_OPTION" ""
    fi
    
    # 选择输出目录
    if [ -n "$SELECTED_DISK_PATH" ]; then
        script_dir="$SELECTED_DISK_PATH"
    else
        script_dir="$(pwd)"
    fi
    
    # 根据部署模式生成不同的启动脚本
    if [ "$DISTRIBUTED_MODE" = "distributed" ]; then
        if [ "$NODE_ROLE" = "head" ]; then
            generate_ray_head_script "$script_dir" "$model_path" "$quant_option" "$gpu_count"
        else
            generate_ray_worker_script "$script_dir"
        fi
    else
        # 单机模式
        generate_single_node_script "$script_dir" "$model_path" "$quant_option" "$gpu_count"
    fi
}

# 生成单机模式启动脚本
generate_single_node_script() {
    local script_dir=$1
    local model_path=$2
    local quant_option=$3
    local gpu_count=$4
    
    local script_name="$script_dir/start_vllm_server.sh"
    
    # 生成启动脚本内容
    cat > "$script_name" << EOF
#!/bin/bash
# vLLM启动脚本 - 由自动配置工具生成（单机模式）

# 设置环境变量
export CUDA_VISIBLE_DEVICES=0,1,2,3  # 根据实际GPU数量调整

EOF
    
    # 如果使用虚拟环境，添加激活代码
    if [ -n "$VENV_ACTIVE" ] && [ -n "$VENV_PATH" ]; then
        cat >> "$script_name" << EOF
# 激活Python虚拟环境
echo "激活虚拟环境: $VENV_PATH"
source "$VENV_PATH/bin/activate"

EOF
    fi
    
    # 添加主要启动命令
    cat >> "$script_name" << EOF
# 启动vLLM服务器
echo "启动vLLM服务器..."
python -m vllm.entrypoints.openai.api_server \\
    --model $model_path \\
    --tensor-parallel-size $gpu_count \\
    $quant_option \\
    --trust-remote-code \\
    --host 0.0.0.0 \\
    --port 8000

# 如果遇到内存不足问题，可以尝试添加以下参数:
# --max-model-len 2048 \\
# --gpu-memory-utilization 0.8 \\

# 打印使用说明
cat << "USAGE"
vLLM服务器已启动!

可以通过以下方式测试:
curl http://localhost:8000/v1/completions \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "$(basename $model_path)",
    "prompt": "今天天气真不错",
    "max_tokens": 100,
    "temperature": 0.7
  }'
USAGE
EOF
    
    chmod +x "$script_name"
    print_success "单机启动脚本已生成: $script_name"
    print_info "使用以下命令启动vLLM服务器:"
    print_info "  $script_name"
    
    # 创建快捷方式
    if [ "$script_dir" != "$(pwd)" ]; then
        ln -sf "$script_name" "./start_vllm_server.sh" 2>/dev/null || true
        print_info "在当前目录创建了启动脚本的快捷方式"
    fi
}

# 生成Ray head节点启动脚本
generate_ray_head_script() {
    local script_dir=$1
    local model_path=$2
    local quant_option=$3
    local gpu_count=$4
    
    local script_name="$script_dir/start_vllm_ray_head.sh"
    
    # 生成启动脚本内容
    cat > "$script_name" << EOF
#!/bin/bash
# vLLM+Ray Head节点启动脚本 - 由自动配置工具生成

# 设置环境变量
export RAY_HEAD_IP="${HEAD_NODE_IP}"
export RAY_PORT="${RAY_PORT}"

EOF
    
    # 如果使用虚拟环境，添加激活代码
    if [ -n "$VENV_ACTIVE" ] && [ -n "$VENV_PATH" ]; then
        cat >> "$script_name" << EOF
# 激活Python虚拟环境
echo "激活虚拟环境: $VENV_PATH"
source "$VENV_PATH/bin/activate"

EOF
    fi
    
    # 添加主要启动命令
    cat >> "$script_name" << EOF
# 停止已存在的Ray进程
echo "停止已存在的Ray进程..."
ray stop

# 启动Ray head节点
echo "启动Ray head节点..."
ray start --head --port=\$RAY_PORT --include-dashboard=true --dashboard-host=0.0.0.0 --num-gpus=$gpu_count

# 检查Ray状态
echo "Ray集群状态:"
ray status

# 启动vLLM OpenAI API服务器
echo "启动vLLM服务器..."
python -m vllm.entrypoints.openai.api_server \\
    --model $model_path \\
    --tensor-parallel-size $gpu_count \\
    $quant_option \\
    --trust-remote-code \\
    --host 0.0.0.0 \\
    --port 8000 \\
    --ray-address="ray://\$RAY_HEAD_IP:\$RAY_PORT"

# 如果遇到内存不足问题，可以尝试添加以下参数:
# --max-model-len 2048 \\
# --gpu-memory-utilization 0.8 \\

# 打印使用说明
cat << "USAGE"
vLLM+Ray服务器已启动! (Head节点)

Ray dashboard: http://${HEAD_NODE_IP}:8265
vLLM API endpoint: http://${HEAD_NODE_IP}:8000

可以通过以下方式测试:
curl http://${HEAD_NODE_IP}:8000/v1/completions \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "$(basename $model_path)",
    "prompt": "今天天气真不错",
    "max_tokens": 100,
    "temperature": 0.7
  }'
USAGE
EOF
    
    chmod +x "$script_name"
    print_success "Ray Head节点启动脚本已生成: $script_name"
    print_info "使用以下命令启动Ray Head节点和vLLM服务器:"
    print_info "  $script_name"
    
    # 创建快捷方式
    if [ "$script_dir" != "$(pwd)" ]; then
        ln -sf "$script_name" "./start_vllm_ray_head.sh" 2>/dev/null || true
        print_info "在当前目录创建了启动脚本的快捷方式"
    fi
}

# 生成Ray worker节点启动脚本
generate_ray_worker_script() {
    local script_dir=$1
    local script_name="$script_dir/start_vllm_ray_worker.sh"
    
    # 检测GPU数量
    if command -v nvidia-smi &> /dev/null; then
        gpu_count=$(nvidia-smi -L | wc -l)
    else
        gpu_count=1
    fi
    
    # 生成启动脚本内容
    cat > "$script_name" << EOF
#!/bin/bash
# vLLM+Ray Worker节点启动脚本 - 由自动配置工具生成

# 设置环境变量
export RAY_HEAD_IP="${HEAD_NODE_IP}"
export RAY_PORT="${RAY_PORT}"

EOF
    
    # 如果使用虚拟环境，添加激活代码
    if [ -n "$VENV_ACTIVE" ] && [ -n "$VENV_PATH" ]; then
        cat >> "$script_name" << EOF
# 激活Python虚拟环境
echo "激活虚拟环境: $VENV_PATH"
source "$VENV_PATH/bin/activate"

EOF
    fi
    
    # 添加主要启动命令
    cat >> "$script_name" << EOF
# 停止已存在的Ray进程
echo "停止已存在的Ray进程..."
ray stop

# 启动Ray worker节点
echo "启动Ray worker节点，连接到 \$RAY_HEAD_IP:\$RAY_PORT..."
ray start --address="\$RAY_HEAD_IP:\$RAY_PORT" --num-gpus=$gpu_count

# 检查Ray状态
echo "Ray连接状态:"
ray status

# 打印使用说明
cat << "USAGE"
Ray worker节点已启动!

这个节点现在是Ray集群的一部分，并将参与分布式模型推理。
Ray dashboard 可在以下地址访问: http://${HEAD_NODE_IP}:8265

注意:
1. 确保Head节点已经运行
2. Worker节点仅提供计算资源，不直接提供API服务
3. 要停止worker节点，运行: ray stop
USAGE
EOF
    
    chmod +x "$script_name"
    print_success "Ray Worker节点启动脚本已生成: $script_name"
    print_info "使用以下命令启动Ray Worker节点:"
    print_info "  $script_name"
    
    # 创建快捷方式
    if [ "$script_dir" != "$(pwd)" ]; then
        ln -sf "$script_name" "./start_vllm_ray_worker.sh" 2>/dev/null || true
        print_info "在当前目录创建了启动脚本的快捷方式"
    fi
}

# 生成模型测试脚本
generate_test_script() {
    print_section "生成测试脚本"
    
    # 选择输出目录
    if [ -n "$SELECTED_DISK_PATH" ]; then
        script_dir="$SELECTED_DISK_PATH"
    else
        script_dir="$(pwd)"
    fi
    
    script_name="$script_dir/test_model.py"
    
    cat > "$script_name" << EOF
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
模型测试脚本
此脚本用于测试已安装的大语言模型 (支持单机和Ray分布式模式)
"""

import argparse
import os
from vllm import LLM, SamplingParams

def test_model(model_path, prompt=None, use_ray=False, ray_address=None):
    """测试模型推理"""
    print(f"正在加载模型: {model_path}")
    print("这可能需要几分钟时间...")
    
    # 如果使用Ray，需要提供ray_address
    if use_ray and ray_address:
        print(f"使用Ray分布式模式，连接到: {ray_address}")
        
        # 初始化分布式模型
        model = LLM(
            model=model_path,
            trust_remote_code=True,
            tensor_parallel_size=1,  # Ray会自动管理并行
            ray_address=ray_address
        )
    else:
        print("使用单机模式")
        
        # 初始化模型
        model = LLM(
            model=model_path,
            trust_remote_code=True,
            tensor_parallel_size=1  # 使用单GPU测试
        )
    
    if prompt is None:
        prompt = "请简要介绍一下自己。"
    
    print(f"\n输入提示: {prompt}")
    
    # 定义采样参数
    sampling_params = SamplingParams(
        temperature=0.7,
        top_p=0.9,
        max_tokens=100
    )
    
    # 运行推理
    print("\n正在生成回复...")
    outputs = model.generate([prompt], sampling_params)
    
    # 打印结果
    print("\n模型回复:")
    print("-" * 50)
    for output in outputs:
        print(output.text)
    print("-" * 50)
    
    print("\n测试完成！")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="测试语言模型")
    parser.add_argument("--model", type=str, required=True, help="模型路径或Hugging Face模型ID")
    parser.add_argument("--prompt", type=str, help="测试提示 (可选)")
    parser.add_argument("--ray", action="store_true", help="使用Ray分布式模式")
    parser.add_argument("--ray-address", type=str, help="Ray集群地址 (格式: ray://IP:PORT)")
    
    args = parser.parse_args()
    
    # 如果指定了--ray但没有指定--ray-address，尝试从环境变量获取
    if args.ray and not args.ray_address:
        ray_head_ip = os.environ.get("RAY_HEAD_IP")
        ray_port = os.environ.get("RAY_PORT", "6379")
        if ray_head_ip:
            args.ray_address = f"ray://{ray_head_ip}:{ray_port}"
            print(f"从环境变量获取Ray地址: {args.ray_address}")
    
    test_model(args.model, args.prompt, args.ray, args.ray_address)
EOF
    
    chmod +x "$script_name"
    print_success "测试脚本已生成: $script_name"
    print_info "使用以下命令测试模型:"
    print_info "  python3 $script_name --model 模型路径或ID"
    print_info "  对于Ray分布式模式: python3 $script_name --model 模型路径或ID --ray --ray-address ray://IP:PORT"
    
    # 创建快捷方式
    if [ "$script_dir" != "$(pwd)" ]; then
        ln -sf "$script_name" "./test_model.py" 2>/dev/null || true
        print_info "在当前目录创建了测试脚本的快捷方式"
    fi
}

# 生成模型推荐
recommend_models() {
    print_section "模型推荐"
    
    # 获取显存信息
    if command -v nvidia-smi &> /dev/null; then
        # 获取所有GPU的总显存
        total_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{s+=$1} END {print s}')
        total_vram_gb=$(echo "scale=1; $total_vram/1024" | bc)
        gpu_count=$(nvidia-smi -L | wc -l)
        
        print_info "总GPU数量: $gpu_count"
        print_info "总显存容量: ${total_vram_gb}GB"
        
        echo ""
        echo "根据您的硬件，推荐以下模型配置:"
        echo ""
        
        if (( $(echo "$total_vram_gb >= 80" | bc -l) )); then
            echo "✅ 您的系统可以运行大型模型 (如deepseek-llm-67b)"
            echo "   - deepseek-ai/deepseek-llm-67b-base"
            echo "   - deepseek-ai/deepseek-llm-67b-chat"
            echo "   - meta-llama/Llama-2-70b-chat-hf"
        elif (( $(echo "$total_vram_gb >= 40" | bc -l) )); then
            echo "✅ 您的系统可以运行中型模型 (如deepseek-llm-7b/13b)"
            echo "   - deepseek-ai/deepseek-llm-7b-base"
            echo "   - deepseek-ai/deepseek-llm-7b-chat"
            echo "   - deepseek-ai/deepseek-coder-6.7b-instruct"
            echo "   - meta-llama/Llama-2-13b-chat-hf"
            echo "   * 使用量化可能可以运行deepseek-llm-67b"
        elif (( $(echo "$total_vram_gb >= 20" | bc -l) )); then
            echo "✅ 您的系统可以运行小型模型 (如deepseek-llm-7b)"
            echo "   - deepseek-ai/deepseek-llm-7b-base (推荐)"
            echo "   - deepseek-ai/deepseek-llm-7b-chat" 
            echo "   - deepseek-ai/deepseek-coder-6.7b-instruct"
            echo "   * 建议启用量化选项 (--quantization awq)"
        else
            echo "⚠️ 您的显存有限，建议使用小型模型"
            echo "   - TinyLlama/TinyLlama-1.1B-Chat-v1.0 (最小测试选项)"
            echo "   - deepseek-ai/deepseek-llm-7b-base (使用量化)"
            echo "   * 必须启用量化选项 (--quantization awq)"
            echo "   * 考虑减小上下文窗口 (--max-model-len 1024)"
        fi
        
        echo ""
        echo "无论您的硬件配置如何，建议先使用TinyLlama-1.1B验证安装，然后再尝试更大的模型"
        
        # 分布式模式下的模型推荐
        if [ "$DISTRIBUTED_MODE" = "distributed" ]; then
            echo ""
            echo "分布式模式下的模型推荐:"
            echo "   - 在分布式模式下，模型会被分布在多个GPU上，因此可以运行更大的模型"
            echo "   - deepseek-ai/deepseek-llm-67b或更大的模型对于多节点分布式部署是理想选择"
            echo "   - 重要提示: 确保模型在所有节点上的路径相同，或使用Hugging Face模型ID"
        fi
    else
        print_error "无法检测GPU信息，跳过模型推荐"
    fi
}

# 显示安装摘要和详细指南
show_installation_summary() {
    print_section "安装摘要"
    
    echo "✅ 系统检查完成"
    if [ -n "$SELECTED_DISK_PATH" ]; then
        echo "✅ 已选择数据存储位置: $SELECTED_DISK_PATH"
    fi
    
    # GPU状态
    if command -v nvidia-smi &> /dev/null; then
        gpu_count=$(nvidia-smi -L | wc -l)
        echo "✅ 已检测到 $gpu_count 个GPU"
    else
        echo "❌ 未检测到GPU或驱动未正确安装"
    fi
    
    # 虚拟环境状态
    if [ -n "$VENV_ACTIVE" ] && [ -n "$VENV_PATH" ]; then
        echo "✅ Python虚拟环境已创建并激活: $VENV_PATH"
    else
        echo "- 未使用Python虚拟环境"
    fi
    
    # vLLM安装状态
    if pip list 2>/dev/null | grep -q "^vllm "; then
        vllm_version=$(pip list 2>/dev/null | grep "^vllm " | awk '{print $2}')
        echo "✅ vLLM已安装，版本: $vllm_version"
    else
        echo "❌ vLLM未安装或安装未完成"
    fi
    
    # Ray安装状态
    if pip list 2>/dev/null | grep -q "^ray "; then
        ray_version=$(pip list 2>/dev/null | grep "^ray " | awk '{print $2}')
        echo "✅ Ray已安装，版本: $ray_version"
    else
        echo "❌ Ray未安装或安装未完成"
    fi
    
    # 模型下载状态
    if [ -n "$DOWNLOADED_MODEL" ]; then
        echo "✅ 模型已下载: $DOWNLOADED_MODEL"
    else
        echo "- 未下载模型或下载未完成"
    fi
    
    # 部署模式状态
    if [ "$DISTRIBUTED_MODE" = "distributed" ]; then
        echo "✅ 部署模式: 分布式 (Ray)"
        echo "   节点角色: $NODE_ROLE"
        echo "   Head节点IP: $HEAD_NODE_IP"
    else
        echo "✅ 部署模式: 单机"
    fi
    
    # 启动脚本状态
    if [ "$DISTRIBUTED_MODE" = "distributed" ]; then
        if [ "$NODE_ROLE" = "head" ]; then
            if [ -n "$SELECTED_DISK_PATH" ] && [ -f "$SELECTED_DISK_PATH/start_vllm_ray_head.sh" ]; then
                echo "✅ Head节点启动脚本已生成: $SELECTED_DISK_PATH/start_vllm_ray_head.sh"
            elif [ -f "./start_vllm_ray_head.sh" ]; then
                echo "✅ Head节点启动脚本已生成: ./start_vllm_ray_head.sh"
            else
                echo "- 未生成Head节点启动脚本"
            fi
        else
            if [ -n "$SELECTED_DISK_PATH" ] && [ -f "$SELECTED_DISK_PATH/start_vllm_ray_worker.sh" ]; then
                echo "✅ Worker节点启动脚本已生成: $SELECTED_DISK_PATH/start_vllm_ray_worker.sh"
            elif [ -f "./start_vllm_ray_worker.sh" ]; then
                echo "✅ Worker节点启动脚本已生成: ./start_vllm_ray_worker.sh"
            else
                echo "- 未生成Worker节点启动脚本"
            fi
        fi
    else
        if [ -n "$SELECTED_DISK_PATH" ] && [ -f "$SELECTED_DISK_PATH/start_vllm_server.sh" ]; then
            echo "✅ 启动脚本已生成: $SELECTED_DISK_PATH/start_vllm_server.sh"
        elif [ -f "./start_vllm_server.sh" ]; then
            echo "✅ 启动脚本已生成: ./start_vllm_server.sh"
        else
            echo "- 未生成启动脚本"
        fi
    fi
    
    print_section "详细安装指南"
    
    echo "1. 整体安装流程:"
    echo "   - 系统检查: 验证CPU、内存、磁盘空间"
    echo "   - 磁盘选择: 选择适合存储大模型的磁盘"
    echo "   - GPU检查: 验证GPU、驱动和CUDA"
    echo "   - Python环境: 设置虚拟环境隔离依赖"
    echo "   - vLLM安装: 安装核心推理引擎"
    echo "   - Ray安装: 安装分布式框架（分布式模式）"
    echo "   - 模型下载: 获取预训练的大语言模型"
    echo "   - 脚本生成: 创建启动和测试脚本"
    echo ""
    
    echo "2. 环境结构:"
    if [ -n "$SELECTED_DISK_PATH" ]; then
        echo "   数据根目录: $SELECTED_DISK_PATH/"
        echo "   ├── models/          # 存储下载的模型"
        if [ "$DISTRIBUTED_MODE" = "distributed" ]; then
            if [ "$NODE_ROLE" = "head" ]; then
                echo "   ├── start_vllm_ray_head.sh  # Head节点启动脚本"
            else
                echo "   ├── start_vllm_ray_worker.sh  # Worker节点启动脚本"
            fi
        else
            echo "   ├── start_vllm_server.sh  # 服务器启动脚本"
        }
        echo "   └── test_model.py    # 模型测试脚本"
    else
        echo "   当前目录: $(pwd)/"
        echo "   ├── models/          # 存储下载的模型"
        if [ "$DISTRIBUTED_MODE" = "distributed" ]; then
            if [ "$NODE_ROLE" = "head" ]; then
                echo "   ├── start_vllm_ray_head.sh  # Head节点启动脚本"
            else
                echo "   ├── start_vllm_ray_worker.sh  # Worker节点启动脚本"
            fi
        else
            echo "   ├── start_vllm_server.sh  # 服务器启动脚本"
        fi
        echo "   └── test_model.py    # 模型测试脚本"
    fi
    
    if [ -n "$VENV_PATH" ]; then
        echo "   虚拟环境: $VENV_PATH/"
        echo "   ├── bin/             # Python可执行文件和激活脚本"
        echo "   └── lib/             # 安装的Python库"
    fi
    echo ""
    
    echo "3. 使用vLLM服务的方式:"
    if [ "$DISTRIBUTED_MODE" = "distributed" ]; then
        echo "   分布式部署 (Ray):"
        echo "   1. 在Head节点上运行: ./start_vllm_ray_head.sh"
        echo "   2. 在每个Worker节点上运行: ./start_vllm_ray_worker.sh"
        echo "   3. 服务器默认地址: http://$HEAD_NODE_IP:8000"
        echo "   4. Ray仪表盘地址: http://$HEAD_NODE_IP:8265"
    else
        echo "   单机部署:"
        echo "   1. 启动服务器: ./start_vllm_server.sh"
        echo "   2. 服务器默认地址: http://localhost:8000"
    fi
    
    echo ""
    echo "   API格式与OpenAI兼容:"
    echo "   curl http://localhost:8000/v1/completions \\"
    echo "     -H \"Content-Type: application/json\" \\"
    echo "     -d '{\"model\": \"模型名称\", \"prompt\": \"你好\", \"max_tokens\": 100}'"
    echo ""
    echo "   支持的API端点:"
    echo "   - /v1/completions (文本补全)"
    echo "   - /v1/chat/completions (对话补全)"
    echo "   - /v1/models (获取可用模型)"
    echo ""
    
    echo "4. 直接在Python中使用vLLM:"
    echo "   - 激活虚拟环境: source $VENV_PATH/bin/activate (如果使用了虚拟环境)"
    echo "   - 创建Python脚本:"
    echo "     ```python"
    echo "     from vllm import LLM, SamplingParams"
    if [ "$DISTRIBUTED_MODE" = "distributed" ]; then
        echo "     # 分布式模式"
        echo "     model = LLM(model=\"模型路径\", ray_address=\"ray://$HEAD_NODE_IP:$RAY_PORT\")"
    else
        echo "     # 单机模式"
        echo "     model = LLM(model=\"模型路径\")"
    fi
    echo "     outputs = model.generate(\"你的提示\")"
    echo "     print(outputs[0].text)"
    echo "     ```"
    echo ""
    
    echo "5. 常见问题解决方案:"
    echo "   A. 内存不足:"
    echo "      - 启用量化: 在启动脚本中添加 --quantization awq"
    echo "      - 减小模型上下文: 添加 --max-model-len 1024"
    echo "      - 减小GPU使用率: 添加 --gpu-memory-utilization 0.8"
    echo ""
    echo "   B. 启动服务器失败:"
    echo "      - 检查GPU驱动: nvidia-smi"
    echo "      - 检查CUDA版本: nvcc --version"
    echo "      - 检查Python环境: which python; python --version"
    echo "      - 检查vLLM安装: pip list | grep vllm"
    echo ""
    echo "   C. Ray集群问题:"
    echo "      - 确保防火墙允许Ray端口 (默认6379) 和其他相关端口"
    echo "      - 使用 ray status 检查集群连接状态"
    echo "      - 确保所有节点可以通过IP地址互相访问"
    echo "      - 首先启动Head节点，然后再启动Worker节点"
    echo "      - 确保所有节点上的Ray和vLLM版本相同"
    echo ""
    echo "   D. 模型加载缓慢:"
    echo "      - 这是正常现象，特别是大型模型首次加载时需要较长时间"
    echo "      - 在分布式模式下，模型加载可能需要更长时间，因为模型需要在集群间分发"
    echo "      - 建议启用量化以加快加载速度并减少内存使用"
    echo ""
    
    echo "6. 分布式性能调优:"
    echo "   - 确保所有节点的网络连接良好，理想情况下使用高速网络 (如InfiniBand)"
    echo "   - 在Head节点上调整 --worker-use-ray-pipeline 参数可优化性能"
    echo "   - 根据模型大小调整节点间的通信频率: --max-parallel-loading-workers"
    echo "   - 在所有节点上保持相同的模型路径，或使用Hugging Face模型ID"
    echo ""
}

# 主函数
main() {
    clear
    echo "============================================================"
    echo "                Ubuntu vLLM+Ray 环境配置和检测工具             "
    echo "============================================================"
    echo ""
    echo "此脚本将帮助您检查和配置Ubuntu系统上的vLLM+Ray环境，包括:"
    echo "  - 检查系统环境"
    echo "  - 检查额外挂载的磁盘并选择数据存储位置"
    echo "  - 检查GPU和CUDA"
    echo "  - 设置Python虚拟环境"
    echo "  - 安装vLLM及Ray分布式框架"
    echo "  - 配置单机或多机分布式部署模式"
    echo "  - 下载和配置大语言模型"
    echo "  - 生成启动和测试脚本"
    echo ""
    
    # 检查是否有配置文件
    if [ -f "$CONFIG_FILE" ]; then
        show_config
        echo ""
        read -p "是否使用已保存的配置? (y/n) [y]: " use_saved_config
        use_saved_config=${use_saved_config:-y}
        
        if [[ ! $use_saved_config =~ ^[Yy]$ ]]; then
            echo ""
            read -p "是否重置所有配置? (y/n) [n]: " reset_all
            reset_all=${reset_all:-n}
            
            if [[ $reset_all =~ ^[Yy]$ ]]; then
                reset_all_config
            else
                echo "可用的配置项:"
                echo "1) 数据存储位置 (SELECTED_DISK_PATH)"
                echo "2) 虚拟环境路径 (VENV_PATH)"
                echo "3) 下载镜像设置 (HF_MIRROR)"
                echo "4) 分布式设置 (DISTRIBUTED_MODE, NODE_ROLE, HEAD_NODE_IP)"
                echo "5) 取消"
                
                read -p "选择要重置的配置项 [5]: " config_to_reset
                config_to_reset=${config_to_reset:-5}
                
                case $config_to_reset in
                    1) reset_config "SELECTED_DISK_PATH" ;;
                    2) reset_config "VENV_PATH" ;;
                    3) reset_config "HF_MIRROR" ;;
                    4) 
                        reset_config "DISTRIBUTED_MODE"
                        reset_config "NODE_ROLE"
                        reset_config "HEAD_NODE_IP"
                        reset_config "RAY_PORT"
                        ;;
                    5) echo "继续使用现有配置" ;;
                    *) echo "无效选择，继续使用现有配置" ;;
                esac
            fi
        fi
    fi
    
    echo "============================================================"
    
    # 检查root权限
    check_root
    
    # 全局变量
    VENV_ACTIVE=""
    VENV_PATH=""
    DOWNLOADED_MODEL=""
    SELECTED_DISK_PATH=""
    MODELS_DIR=""
    MISSING_PACKAGES=0
    TORCH_CUDA_ERROR=0
    RAY_ERROR=0
    DISTRIBUTED_MODE="single"
    NODE_ROLE=""
    HEAD_NODE_IP=""
    RAY_PORT=""
    
    # 执行各个检查
    check_system
    
    # 检测并选择额外挂载的磁盘
    detect_storage_disks
    
    check_gpu || true
    check_python
    
    # 设置虚拟环境
    setup_virtualenv || true
    
    # 检查依赖包
    check_pip_packages
    
    # 提供模型推荐
    recommend_models
    
    # 如果发现缺失包，强制安装vLLM和Ray
    if [ "$MISSING_PACKAGES" -eq 1 ] || [ "$TORCH_CUDA_ERROR" -eq 1 ] || [ "$RAY_ERROR" -eq 1 ]; then
        print_warning "检测到必要依赖缺失，将自动安装vLLM、Ray及依赖..."
        install_vllm_ray
        
        # 记录安装状态
        save_config "VLLM_INSTALLED" "1"
    else
        # 提供安装选项
        echo ""
        local saved_vllm_installed=$(read_config "VLLM_INSTALLED" "")
        
        if [ "$saved_vllm_installed" = "1" ]; then
            print_info "vLLM和Ray已安装（根据配置记录）"
            read -p "是否重新安装vLLM和Ray? (y/n) [n]: " reinstall_choice
            reinstall_choice=${reinstall_choice:-n}
            
            if [[ $reinstall_choice =~ ^[Yy]$ ]]; then
                install_vllm_ray
                # 更新安装状态
                save_config "VLLM_INSTALLED" "1"
            fi
        else
            print_info "建议安装vLLM、Ray及依赖以确保完整功能"
            read -p "是否安装vLLM、Ray及依赖? (y/n) [y]: " install_choice
            install_choice=${install_choice:-y}  # 默认为y
            
            if [[ $install_choice =~ ^[Yy]$ ]]; then
                install_vllm_ray
                # 记录安装状态
                save_config "VLLM_INSTALLED" "1"
            fi
        fi
    fi
    
    # 配置分布式模式
    configure_distributed_mode
    
    # 提供下载模型选项
    echo ""
    read -p "是否下载模型进行验证? (y/n) [y]: " download_choice
    download_choice=${download_choice:-y}  # 默认为y

    if [[ $download_choice =~ ^[Yy]$ ]]; then
        # 选择镜像站点
        select_mirror
        
        # 询问用户选择验证模型
        echo "请选择要下载的验证模型:"
        echo "1) TinyLlama/TinyLlama-1.1B-Chat-v1.0 (约2.5GB，适合测试验证)" 
        echo "2) facebook/opt-125m (约250MB，极小模型，仅供验证)"
        echo "3) facebook/opt-350m (约700MB，小型模型)"
        echo "4) 输入自定义模型ID"
        read -p "选择模型 (输入数字) [1]: " verify_model_choice
        verify_model_choice=${verify_model_choice:-1}  # 默认选择1
        
        case $verify_model_choice in
            1) model_id="TinyLlama/TinyLlama-1.1B-Chat-v1.0" ;;
            2) model_id="facebook/opt-125m" ;;
            3) model_id="facebook/opt-350m" ;;
            4) 
                read -p "请输入Hugging Face模型ID: " custom_model_id
                if [ -z "$custom_model_id" ]; then
                    print_error "模型ID不能为空，使用默认模型"
                    model_id="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
                else
                    model_id="$custom_model_id"
                fi
                ;;
            *) 
                print_warning "无效选择，使用默认模型"
                model_id="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
                ;;
        esac
        
        print_info "将下载模型以验证安装: $model_id"
        # 设置为选择的模型
        DOWNLOADED_MODEL=""
        
        # 使用设置好的数据目录
        if [ -n "$MODELS_DIR" ]; then
            download_dir="$MODELS_DIR"
        else
            download_dir="./models"
        fi
        
        # 确保目录存在
        if [ ! -d "$download_dir" ]; then
            mkdir -p "$download_dir"
        fi
        
        print_info "安装huggingface_hub..."
        pip install huggingface_hub
        
        print_info "正在下载验证模型 $model_id 到 $download_dir..."
        
        # 如果设置了镜像，使用镜像下载
        if [ -n "$HF_MIRROR" ]; then
            print_info "使用镜像: $HF_MIRROR"
            python3 -c "import os; from huggingface_hub import snapshot_download; os.environ['HF_ENDPOINT'] = os.environ.get('HF_ENDPOINT', ''); print(f'使用镜像: {os.environ[\"HF_ENDPOINT\"]}' if os.environ[\"HF_ENDPOINT\"] else '使用官方地址'); snapshot_download(repo_id='$model_id', local_dir='$download_dir/$model_id', local_dir_use_symlinks=False)"
        else
            python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='$model_id', local_dir='$download_dir/$model_id', local_dir_use_symlinks=False)"
        fi
        
        download_status=$?
        if [ $download_status -eq 0 ]; then
            print_success "验证模型下载完成: $download_dir/$model_id"
            DOWNLOADED_MODEL="$download_dir/$model_id"
        else
            print_error "模型下载失败 (错误码: $download_status)"
            print_info "尝试使用以下命令手动下载:"
            print_info "HF_ENDPOINT=$HF_MIRROR python -c \"from huggingface_hub import snapshot_download; snapshot_download(repo_id='$model_id', local_dir='$download_dir/$model_id')\""
        fi
        
        # 提供下载模型完整选项
        echo ""
        read -p "是否下载其他模型? (y/n) [n]: " full_download_choice
        full_download_choice=${full_download_choice:-n}  # 默认为n
        
        if [[ $full_download_choice =~ ^[Yy]$ ]]; then
            download_model
        fi
    fi
    
    # 生成启动和测试脚本
    echo ""
    read -p "是否生成启动和测试脚本? (y/n) [y]: " script_choice
    script_choice=${script_choice:-y}  # 默认为y
    
    if [[ $script_choice =~ ^[Yy]$ ]]; then
        generate_startup_script
        generate_test_script
    fi
    
    print_section "完成"
    print_success "Ubuntu vLLM+Ray环境配置和检测已完成!"
    
    # 显示数据存储位置信息
    if [ -n "$SELECTED_DISK_PATH" ] && [ "$SELECTED_DISK_PATH" != "$(pwd)" ]; then
        echo ""
        echo "vLLM数据存储位置: $SELECTED_DISK_PATH"
        if [ -d "$MODELS_DIR" ]; then
            echo "模型存储位置: $MODELS_DIR"
        fi
    fi
    
    # 显示安装摘要和详细指南
    show_installation_summary
    
    # 保存安装信息到配置文件
    save_config "LAST_INSTALL_DATE" "$(date '+%Y-%m-%d %H:%M:%S')"
    
    # 显示所有配置信息
    show_config
    
    print_section "后续操作"
    
    if [ "$DISTRIBUTED_MODE" = "distributed" ]; then
        if [ "$NODE_ROLE" = "head" ]; then
            echo "配置完成后，您可以执行以下操作:"
            echo ""
            echo "1. 启动Ray头节点和vLLM服务器:"
            
            if [ -n "$SELECTED_DISK_PATH" ] && [ -f "$SELECTED_DISK_PATH/start_vllm_ray_head.sh" ]; then
                echo "   $SELECTED_DISK_PATH/start_vllm_ray_head.sh"
                echo "   或使用当前目录中的快捷方式: ./start_vllm_ray_head.sh"
            else
                echo "   ./start_vllm_ray_head.sh"
            fi
            
            echo ""
            echo "2. 在其他Worker节点上运行安装脚本，选择'Worker'角色"
            echo ""
            echo "3. 检查Ray集群状态:"
            echo "   ray status"
            echo ""
            echo "4. 使用API调用模型 (服务器启动后):"
            echo "   curl http://$HEAD_NODE_IP:8000/v1/completions \\"
            echo "     -H \"Content-Type: application/json\" \\"
            echo "     -d '{\"model\": \"模型名称\", \"prompt\": \"你好\", \"max_tokens\": 100}'"
        else
            echo "配置完成后，您可以执行以下操作:"
            echo ""
            echo "1. 确保Head节点已启动"
            echo ""
            echo "2. 启动Ray Worker节点:"
            
            if [ -n "$SELECTED_DISK_PATH" ] && [ -f "$SELECTED_DISK_PATH/start_vllm_ray_worker.sh" ]; then
                echo "   $SELECTED_DISK_PATH/start_vllm_ray_worker.sh"
                echo "   或使用当前目录中的快捷方式: ./start_vllm_ray_worker.sh"
            else
                echo "   ./start_vllm_ray_worker.sh"
            fi
            
            echo ""
            echo "3. 检查Ray集群状态:"
            echo "   ray status"
        fi
    else
        echo "配置完成后，您可以执行以下操作:"
        echo ""
        echo "1. 启动vLLM服务器:"
        
        if [ -n "$SELECTED_DISK_PATH" ] && [ -f "$SELECTED_DISK_PATH/start_vllm_server.sh" ]; then
            echo "   $SELECTED_DISK_PATH/start_vllm_server.sh"
            echo "   或使用当前目录中的快捷方式: ./start_vllm_server.sh"
        else
            echo "   ./start_vllm_server.sh"
        fi
        
        echo ""
        echo "2. 测试模型:"
        
        if [ -n "$SELECTED_DISK_PATH" ] && [ -f "$SELECTED_DISK_PATH/test_model.py" ]; then
            echo "   python3 $SELECTED_DISK_PATH/test_model.py --model 模型路径"
            echo "   或使用当前目录中的快捷方式: python3 ./test_model.py --model 模型路径"
        else
            echo "   python3 test_model.py --model 模型路径"
        fi
        
        echo ""
        echo "3. 使用API调用模型 (服务器启动后):"
        echo "   curl http://localhost:8000/v1/completions \\"
        echo "     -H \"Content-Type: application/json\" \\"
        echo "     -d '{\"model\": \"模型名称\", \"prompt\": \"你好\", \"max_tokens\": 100}'"
    fi
    
    # 如果激活了虚拟环境，添加提示
    if [ -n "$VENV_ACTIVE" ] && [ -n "$VENV_PATH" ]; then
        echo ""
        echo "注意: 当前会话使用的是虚拟环境 '$VENV_PATH'"
        echo "      退出环境请输入: deactivate"
        echo "      下次使用前请先激活环境: source $VENV_PATH/bin/activate"
    fi
    
    echo ""
    echo "按 Enter 键结束脚本..."
    read # 等待用户按回车，防止脚本立即退出
}

# 添加一个安全执行的main函数包装器
run_main() {
    debug_log "开始执行main函数"
    
    # 尝试执行main函数
    if ! main; then
        print_error "主程序执行失败"
        echo "请查看上面的错误信息，解决问题后重新运行"
        exit 1
    fi
    
    debug_log "main函数执行完成"
}

# 运行安全包装的main函数
run_main