#!/bin/bash

# 目录/挂载点磁盘速度测试脚本 - 适用于 Ubuntu 22.04
# 此脚本用于测试特定目录（如挂载点）的磁盘性能

# 设置颜色输出
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印信息函数
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_title() {
    echo -e "\n${GREEN}========== $1 ==========${NC}"
}

# 检查必要的工具是否已安装
check_prerequisites() {
    print_title "检查必要工具"
    
    local missing_tools=()
    
    # 检查 fio
    if ! command -v fio &> /dev/null; then
        missing_tools+=("fio")
    fi
    
    # 如果有缺失的工具，尝试安装
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_warn "以下工具未安装: ${missing_tools[*]}"
        print_info "正在尝试安装缺失的工具..."
        
        sudo apt update
        for tool in "${missing_tools[@]}"; do
            print_info "安装 $tool..."
            sudo apt install -y "$tool"
            
            # 检查安装是否成功
            if ! command -v "$tool" &> /dev/null; then
                print_error "$tool 安装失败，请手动安装后再运行此脚本"
                exit 1
            fi
        done
        
        print_success "所有必要工具已安装 ✓"
    else
        print_success "所有必要工具已安装 ✓"
    fi
}

# 列出当前挂载的文件系统
list_mounts() {
    print_title "当前挂载的文件系统"
    
    echo -e "挂载点\t\t文件系统\t可用空间\t总空间\t使用率"
    echo "-------------------------------------------------------------"
    
    df -h | grep -v "tmpfs\|udev\|snap" | tail -n +2
    
    echo ""
}

# 选择要测试的目录
select_directory() {
    list_mounts
    
    local dir_selected=false
    local test_dir=""
    
    while [ "$dir_selected" = false ]; do
        read -p "请输入要测试的目录路径 (例如 /mnt/data): " test_dir
        
        # 检查输入是否为空
        if [ -z "$test_dir" ]; then
            print_error "目录路径不能为空"
            continue
        fi
        
        # 检查目录是否存在
        if [ ! -d "$test_dir" ]; then
            print_warn "目录 $test_dir 不存在，是否创建? [y/N]: " 
            read create_dir
            
            if [ "$create_dir" = "y" ] || [ "$create_dir" = "Y" ]; then
                mkdir -p "$test_dir"
                if [ ! -d "$test_dir" ]; then
                    print_error "无法创建目录 $test_dir"
                    continue
                fi
                print_success "已创建目录 $test_dir"
            else
                continue
            fi
        fi
        
        # 检查目录是否可写
        if [ ! -w "$test_dir" ]; then
            print_error "目录 $test_dir 不可写，请选择其他目录或使用sudo运行此脚本"
            continue
        fi
        
        # 确认用户选择
        read -p "您确定要测试 $test_dir 吗? 测试将在该目录创建临时文件 [y/N]: " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            dir_selected=true
        else
            print_info "已取消选择"
        fi
    done
    
    # 标准化路径（移除末尾斜杠）
    test_dir=${test_dir%/}
    
    echo "$test_dir"
}

# 获取目录的文件系统信息
get_directory_info() {
    local dir="$1"
    
    print_title "目录信息: $dir"
    
    # 获取挂载点信息
    echo -e "目录路径:\t$dir"
    
    # 获取文件系统类型
    local fs_type=$(df -T "$dir" | tail -n 1 | awk '{print $2}')
    echo -e "文件系统类型:\t$fs_type"
    
    # 获取挂载点
    local mount_point=$(df "$dir" | tail -n 1 | awk '{print $6}')
    echo -e "挂载点:\t\t$mount_point"
    
    # 获取空间信息
    local space_info=$(df -h "$dir" | tail -n 1)
    local total_space=$(echo "$space_info" | awk '{print $2}')
    local used_space=$(echo "$space_info" | awk '{print $3}')
    local free_space=$(echo "$space_info" | awk '{print $4}')
    local usage_percent=$(echo "$space_info" | awk '{print $5}')
    
    echo -e "总空间:\t\t$total_space"
    echo -e "已使用:\t\t$used_space ($usage_percent)"
    echo -e "可用空间:\t$free_space"
    
    # 获取文件系统详细信息
    echo -e "\n文件系统详细信息:"
    mount | grep " $mount_point " | sed 's/^.*(//' | sed 's/)$//'
    
    # 检查是否为SSD
    if [ -b "$(df --output=source "$dir" | tail -n 1)" ]; then
        local device=$(df --output=source "$dir" | tail -n 1)
        local rotational=$(cat /sys/block/$(basename "$device")/queue/rotational 2>/dev/null)
        
        if [ "$rotational" = "0" ]; then
            echo -e "\n此目录位于SSD上"
        elif [ "$rotational" = "1" ]; then
            echo -e "\n此目录位于传统硬盘上"
        fi
    fi
    
    echo ""
}

# 使用dd测试顺序读写速度
test_dd() {
    local dir="$1"
    
    print_title "使用 dd 测试基本读写速度"
    
    # 测试文件路径
    local test_file="$dir/dd_test_file"
    
    # 测试文件大小 (MB)
    local file_size=1024
    
    # 检查可用空间
    local available_space=$(df -m "$dir" | tail -n 1 | awk '{print $4}')
    
    if [ "$available_space" -lt "$file_size" ]; then
        file_size=$((available_space / 2))
        print_warn "可用空间不足，将测试大小调整为 $file_size MB"
        
        if [ "$file_size" -lt 100 ]; then
            print_error "可用空间太小，无法进行有效测试"
            return 1
        fi
    fi
    
    # 写入测试
    print_info "测试顺序写入速度 (写入 $file_size MB 数据)..."
    echo "- 写入测试:"
    dd if=/dev/zero of="$test_file" bs=1M count="$file_size" conv=fdatasync status=progress
    echo ""
    
    # 清除缓存以获得准确的读取速度
    print_info "清除系统缓存..."
    sudo sh -c "sync && echo 3 > /proc/sys/vm/drop_caches"
    
    # 读取测试
    print_info "测试顺序读取速度..."
    echo "- 读取测试:"
    dd if="$test_file" of=/dev/null bs=1M status=progress
    
    # 清理
    print_info "清理测试文件..."
    rm -f "$test_file"
    
    echo ""
}

# 使用fio进行综合测试
test_fio() {
    local dir="$1"
    
    print_title "使用 fio 进行综合性能测试"
    print_info "此测试将提供详细的磁盘性能数据"
    
    # 测试文件路径
    local test_file="$dir/fio_test_file"
    
    # 确定测试文件大小
    local file_size=1
    local available_space=$(df -BG "$dir" | tail -n 1 | awk '{print $4}' | sed 's/G//')
    
    if [ "$available_space" -lt 4 ]; then
        file_size="$available_space"
        if [ "$file_size" -lt 1 ]; then
            file_size=1
            print_warn "可用空间小于1GB，测试可能不准确"
        else
            file_size=$((file_size / 2))
            print_warn "可用空间有限，调整测试文件大小为 ${file_size}G"
        fi
    fi
    
    # 顺序读测试
    print_info "顺序读测试..."
    fio --name=seq_read --filename="$test_file" --rw=read --direct=1 --ioengine=libaio --bs=4k --numjobs=1 --size="${file_size}G" --runtime=30 --group_reporting
    
    # 顺序写测试
    print_info "顺序写测试..."
    fio --name=seq_write --filename="$test_file" --rw=write --direct=1 --ioengine=libaio --bs=4k --numjobs=1 --size="${file_size}G" --runtime=30 --group_reporting
    
    # 随机读测试
    print_info "随机读测试..."
    fio --name=rand_read --filename="$test_file" --rw=randread --direct=1 --ioengine=libaio --bs=4k --numjobs=4 --size="${file_size}G" --runtime=30 --group_reporting
    
    # 随机写测试
    print_info "随机写测试..."
    fio --name=rand_write --filename="$test_file" --rw=randwrite --direct=1 --ioengine=libaio --bs=4k --numjobs=4 --size="${file_size}G" --runtime=30 --group_reporting
    
    # 混合随机读写测试
    print_info "混合随机读写测试 (70% 读, 30% 写)..."
    fio --name=mixed_rw --filename="$test_file" --rw=randrw --direct=1 --ioengine=libaio --bs=4k --numjobs=4 --size="${file_size}G" --runtime=30 --rwmixread=70 --group_reporting
    
    # 清理
    print_info "清理测试文件..."
    rm -f "$test_file"
}

# 使用简单的Python脚本测试小文件性能
test_small_files() {
    local dir="$1"
    
    print_title "测试小文件性能"
    print_info "此测试将创建和读取多个小文件，模拟实际应用场景"
    
    # 创建测试目录
    local test_dir="$dir/small_files_test"
    mkdir -p "$test_dir"
    
    # 生成并执行Python脚本
    print_info "创建临时Python测试脚本..."
    
    cat > /tmp/small_files_test.py << 'EOF'
#!/usr/bin/env python3
import os
import time
import random
import string
import sys

def generate_random_data(size):
    return ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(size))

def test_small_files(directory, file_count=1000, file_size=4096):
    # 确保目录存在
    if not os.path.exists(directory):
        os.makedirs(directory)
    
    print(f"测试目录: {directory}")
    print(f"文件数量: {file_count}")
    print(f"每个文件大小: {file_size} 字节")
    
    # 创建小文件测试
    print("\n1. 创建小文件测试")
    start_time = time.time()
    
    for i in range(file_count):
        data = generate_random_data(file_size)
        with open(os.path.join(directory, f"file_{i}.txt"), 'w') as f:
            f.write(data)
        
        # 显示进度
        if (i + 1) % 100 == 0 or i == file_count - 1:
            sys.stdout.write(f"\r已创建: {i + 1}/{file_count} 文件")
            sys.stdout.flush()
    
    create_time = time.time() - start_time
    print(f"\n创建 {file_count} 个文件用时: {create_time:.2f} 秒")
    print(f"每秒创建文件数: {file_count / create_time:.2f}")
    
    # 读取小文件测试
    print("\n2. 读取小文件测试")
    start_time = time.time()
    
    for i in range(file_count):
        with open(os.path.join(directory, f"file_{i}.txt"), 'r') as f:
            data = f.read()
        
        # 显示进度
        if (i + 1) % 100 == 0 or i == file_count - 1:
            sys.stdout.write(f"\r已读取: {i + 1}/{file_count} 文件")
            sys.stdout.flush()
    
    read_time = time.time() - start_time
    print(f"\n读取 {file_count} 个文件用时: {read_time:.2f} 秒")
    print(f"每秒读取文件数: {file_count / read_time:.2f}")
    
    # 随机访问测试
    print("\n3. 随机访问文件测试")
    start_time = time.time()
    
    file_indices = list(range(file_count))
    random.shuffle(file_indices)
    
    for i, idx in enumerate(file_indices[:min(1000, file_count)]):
        with open(os.path.join(directory, f"file_{idx}.txt"), 'r') as f:
            data = f.read()
        
        # 显示进度
        if (i + 1) % 100 == 0 or i == min(1000, file_count) - 1:
            sys.stdout.write(f"\r已随机访问: {i + 1}/{min(1000, file_count)} 文件")
            sys.stdout.flush()
    
    random_time = time.time() - start_time
    print(f"\n随机访问 {min(1000, file_count)} 个文件用时: {random_time:.2f} 秒")
    print(f"每秒随机访问文件数: {min(1000, file_count) / random_time:.2f}")
    
    # 删除测试
    print("\n4. 删除小文件测试")
    start_time = time.time()
    
    for i in range(file_count):
        os.remove(os.path.join(directory, f"file_{i}.txt"))
        
        # 显示进度
        if (i + 1) % 100 == 0 or i == file_count - 1:
            sys.stdout.write(f"\r已删除: {i + 1}/{file_count} 文件")
            sys.stdout.flush()
    
    delete_time = time.time() - start_time
    print(f"\n删除 {file_count} 个文件用时: {delete_time:.2f} 秒")
    print(f"每秒删除文件数: {file_count / delete_time:.2f}")
    
    # 返回结果摘要
    return {
        "create_time": create_time,
        "create_rate": file_count / create_time,
        "read_time": read_time,
        "read_rate": file_count / read_time,
        "random_time": random_time,
        "random_rate": min(1000, file_count) / random_time,
        "delete_time": delete_time,
        "delete_rate": file_count / delete_time
    }

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python small_files_test.py <目录> [文件数量]")
        sys.exit(1)
    
    directory = sys.argv[1]
    file_count = 1000
    
    if len(sys.argv) > 2:
        try:
            file_count = int(sys.argv[2])
        except ValueError:
            print(f"无效的文件数量: {sys.argv[2]}")
            sys.exit(1)
    
    test_small_files(directory, file_count)
EOF
    
    chmod +x /tmp/small_files_test.py
    
    # 决定要测试的文件数量
    local file_count=1000
    local available_space=$(df -BM "$dir" | tail -n 1 | awk '{print $4}' | sed 's/M//')
    
    # 每个文件约4KB，加上一些开销
    local required_space=$((file_count * 5 / 1024))  # MB
    
    if [ "$available_space" -lt $((required_space * 2)) ]; then
        file_count=$((available_space * 100))
        if [ "$file_count" -lt 100 ]; then
            file_count=100
            print_warn "可用空间有限，减少测试文件数量至 $file_count"
        else
            print_warn "可用空间有限，调整测试文件数量至 $file_count"
        fi
    fi
    
    # 执行测试
    print_info "开始小文件性能测试..."
    python3 /tmp/small_files_test.py "$test_dir" "$file_count"
    
    # 清理
    print_info "清理测试目录..."
    rm -rf "$test_dir"
    rm -f /tmp/small_files_test.py
}

# 生成测试报告
generate_report() {
    local dir="$1"
    
    print_title "目录磁盘性能测试报告摘要"
    print_info "完整的测试结果已显示在上方"
    
    echo ""
    echo "测试于: $(date)"
    echo "测试目录: $dir"
    echo "文件系统: $(df -T "$dir" | tail -n 1 | awk '{print $2}')"
    echo "挂载点: $(df "$dir" | tail -n 1 | awk '{print $6}')"
    echo "操作系统: $(lsb_release -ds)"
    echo "内核版本: $(uname -r)"
    
    echo -e "\n完整的测试已完成。针对不同操作类型的性能结果，请查看上面的测试输出。"
    echo "推荐的性能基准:"
    echo "- 顺序读/写: SSD > 400MB/s, HDD > 80MB/s"
    echo "- 随机4K读/写: SSD > 20MB/s, HDD > 1MB/s"
    echo "- 小文件操作: SSD > 1000files/s, HDD > 100files/s"
}

# 主函数
main() {
    # 欢迎信息
    clear
    echo -e "${GREEN}====================================${NC}"
    echo -e "${GREEN}    Ubuntu 22.04 目录磁盘性能测试    ${NC}"
    echo -e "${GREEN}====================================${NC}"
    echo ""
    
    # 检查必要工具
    check_prerequisites
    
    # 检查Python是否可用
    if ! command -v python3 &> /dev/null; then
        print_warn "Python3未安装，将跳过小文件测试"
        HAS_PYTHON=false
    else
        HAS_PYTHON=true
    fi
    
    # 选择目录
    local dir_to_test=$(select_directory)
    
    # 获取目录信息
    get_directory_info "$dir_to_test"
    
    # 提示用户测试可能需要时间
    print_warn "完整的磁盘测试可能需要几分钟时间，请耐心等待"
    read -p "按回车键开始测试..." -s
    echo ""
    
    # 运行基本测试
    test_dd "$dir_to_test"
    
    # 询问是否运行更详细的fio测试
    echo ""
    read -p "是否运行详细的fio性能测试? (可能需要3-5分钟) [y/N]: " run_fio
    if [ "$run_fio" = "y" ] || [ "$run_fio" = "Y" ]; then
        test_fio "$dir_to_test"
    else
        print_info "已跳过fio测试"
    fi
    
    # 如果Python可用，询问是否运行小文件测试
    if [ "$HAS_PYTHON" = true ]; then
        echo ""
        read -p "是否运行小文件性能测试? (测试创建/读取/删除多个小文件) [y/N]: " run_small_files
        if [ "$run_small_files" = "y" ] || [ "$run_small_files" = "Y" ]; then
            test_small_files "$dir_to_test"
        else
            print_info "已跳过小文件测试"
        fi
    fi
    
    # 生成报告
    generate_report "$dir_to_test"
}

# 执行主函数
main "$@"