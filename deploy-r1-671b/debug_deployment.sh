#!/bin/bash

# Debug script for DeepSeek r1 INT8 deployment
# =====================================================
# This script helps with debugging deployment issues

# Set colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored messages
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

# Help message
show_help() {
    echo "DeepSeek r1 INT8 Deployment Debug Script"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --check-model      Check if the model files exist and are accessible"
    echo "  --check-imports    Check if DeepSeek modules can be imported"
    echo "  --check-ray        Check Ray cluster status"
    echo "  --check-gpu        Check GPU status and availability"
    echo "  --logs             Show Ray logs"
    echo "  --help             Show this help message"
    echo ""
}

# Check if model exists and is accessible
check_model() {
    print_info "Checking model directory..."
    MODEL_PATH="/home/models/DeepSeek-R1-Channel-INT8"
    
    if [ ! -d "$MODEL_PATH" ]; then
        print_error "Model directory $MODEL_PATH does not exist!"
        return 1
    fi
    
    print_success "Model directory exists"
    
    # Check basic model files
    print_info "Checking model files..."
    
    # List key files in model directory
    ls -la "$MODEL_PATH"
    
    # Check if model configuration exists
    if [ -f "$MODEL_PATH/config.json" ]; then
        print_success "Found config.json"
    else
        print_warning "config.json not found!"
    fi
    
    # Check permissions
    print_info "Checking permissions..."
    if [ -r "$MODEL_PATH" ]; then
        print_success "Model directory is readable"
    else
        print_error "Model directory is not readable!"
    fi
    
    return 0
}

# Check if DeepSeek modules can be imported
check_imports() {
    print_info "Checking if DeepSeek modules can be imported..."
    
    # Try different import patterns
    python3 -c "
import sys
try:
    import deepseek
    print('Successfully imported deepseek package')
except ImportError:
    print('Failed to import deepseek package')

try:
    import deepseek_llm
    print('Successfully imported deepseek_llm package')
except ImportError:
    print('Failed to import deepseek_llm package')

try:
    from transformers import AutoModelForCausalLM, AutoTokenizer
    print('Successfully imported transformers package')
except ImportError:
    print('Failed to import transformers package')

try:
    import torch
    print(f'PyTorch version: {torch.__version__}')
    print(f'CUDA available: {torch.cuda.is_available()}')
    if torch.cuda.is_available():
        print(f'CUDA version: {torch.version.cuda}')
        print(f'Number of GPUs: {torch.cuda.device_count()}')
except ImportError:
    print('Failed to import torch package')

print('\\nPython path:')
for path in sys.path:
    print(f'  {path}')
"

    return 0
}

# Check Ray cluster status
check_ray() {
    print_info "Checking Ray cluster status..."
    
    if ! command -v ray &>/dev/null; then
        print_error "Ray is not installed or not in PATH."
        return 1
    fi
    
    # Check if Ray is running
    if ! ray status 2>/dev/null; then
        print_error "Ray is not running or not accessible."
        return 1
    fi
    
    # Print available resources
    print_info "Ray cluster resources:"
    python3 -c "
import ray
ray.init(ignore_reinit_error=True)
print(ray.cluster_resources())
"
    
    return 0
}

# Check GPU status and availability
check_gpu() {
    print_info "Checking GPU status..."
    
    # Check if nvidia-smi is available
    if ! command -v nvidia-smi &>/dev/null; then
        print_error "nvidia-smi is not installed or not in PATH."
        return 1
    fi
    
    # Run nvidia-smi
    nvidia-smi
    
    # Check CUDA with PyTorch
    print_info "Checking CUDA availability with PyTorch..."
    python3 -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'CUDA version: {torch.version.cuda}')
    print(f'Number of GPUs: {torch.cuda.device_count()}')
    for i in range(torch.cuda.device_count()):
        print(f'GPU {i}: {torch.cuda.get_device_name(i)}')
        print(f'  Memory: {torch.cuda.get_device_properties(i).total_memory / 1024**3:.2f} GB')
"
    
    return 0
}

# Show Ray logs
show_logs() {
    print_info "Showing recent Ray logs..."
    
    if [ -d "/tmp/ray/session_latest/logs" ]; then
        print_info "Ray logs directory: /tmp/ray/session_latest/logs"
        ls -la /tmp/ray/session_latest/logs
        
        # Show latest error logs
        print_info "Latest error logs:"
        grep -r "ERROR\|Exception\|Failed" /tmp/ray/session_latest/logs | tail -n 50
    else
        print_error "Ray logs directory not found."
        
        # Try to find logs in alternative locations
        print_info "Searching for Ray logs in alternative locations..."
        find /tmp -name "ray" -type d | grep "ray"
    fi
    
    return 0
}

# Main function
main() {
    # Check command line arguments
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --help)
                show_help
                exit 0
                ;;
            --check-model)
                check_model
                shift
                ;;
            --check-imports)
                check_imports
                shift
                ;;
            --check-ray)
                check_ray
                shift
                ;;
            --check-gpu)
                check_gpu
                shift
                ;;
            --logs)
                show_logs
                shift
                ;;
            --all)
                check_model
                check_imports
                check_ray
                check_gpu
                show_logs
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Execute main function with all arguments
main "$@" 