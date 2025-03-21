#!/bin/bash

# DeepSeek r1 671B Deployment Script with Ray (16 GPUs)
# ====================================================
# This shell script configures and starts a Ray cluster for deploying
# the DeepSeek r1 671B model across 16 GPUs.

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

# Check if script is run with sudo/root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_warning "Running without root privileges. Some operations might fail."
        print_warning "Consider running with sudo if you encounter permission issues."
    fi
}

# Check dependencies
check_dependencies() {
    print_info "Checking dependencies..."
    
    # Check Python
    if ! command -v python3 &>/dev/null; then
        print_error "Python 3 is not installed. Please install Python 3.8 or newer."
        exit 1
    fi
    
    # Check pip
    if ! command -v pip3 &>/dev/null; then
        print_error "pip3 is not installed. Please install pip for Python 3."
        exit 1
    fi
    
    # Check CUDA
    if ! command -v nvidia-smi &>/dev/null; then
        print_error "NVIDIA driver or CUDA is not installed properly."
        exit 1
    fi
    
    # Check number of GPUs
    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
    if [ "$GPU_COUNT" -lt 16 ]; then
        print_error "Insufficient GPUs: Required 16, found $GPU_COUNT."
        print_warning "This deployment requires 16 GPUs with sufficient VRAM (80GB+ per GPU recommended)."
        read -p "Do you want to continue anyway? (y/n): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_success "Found $GPU_COUNT GPUs."
    fi
    
    # Display GPU info
    print_info "GPU Information:"
    nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv
}

# Install required packages
install_requirements() {
    print_info "Installing required Python packages..."
    
    # Create virtual environment
    if [ ! -d "venv" ]; then
        print_info "Creating virtual environment..."
        python3 -m venv venv
    fi
    
    # Activate virtual environment
    source venv/bin/activate
    
    # Install packages
    pip install --upgrade pip
    
    print_info "Installing Ray and other dependencies..."
    pip install "ray[default,serve]>=2.9.0" torch numpy tqdm
    
    # Install DeepSeek specific requirements
    # Note: The exact package name may need to be adjusted based on DeepSeek's official package
    print_info "Installing DeepSeek dependencies..."
    pip install deepseek-llm || print_warning "Unable to install deepseek-llm. You may need to install it manually."
    
    print_success "Dependencies installed successfully."
}

# Start Ray cluster - head node
start_ray_head() {
    print_info "Starting Ray head node..."
    
    # Get the IP address
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    if [ -z "$IP_ADDRESS" ]; then
        IP_ADDRESS="127.0.0.1"
        print_warning "Could not determine IP address, using localhost ($IP_ADDRESS)."
    fi
    
    # Start Ray head node
    ray start --head \
        --port=6379 \
        --dashboard-host=0.0.0.0 \
        --dashboard-port=8265 \
        --num-cpus=$(nproc) \
        --num-gpus=$GPU_COUNT
    
    print_success "Ray head node started at $IP_ADDRESS:6379"
    print_info "Ray dashboard available at http://$IP_ADDRESS:8265"
    
    # Create head node info file
    echo "$IP_ADDRESS:6379" > ray_head_address.txt
    
    return 0
}

# Configure model deployment
configure_deployment() {
    print_info "Configuring model deployment..."
    
    # Get model path
    read -p "Enter the path to DeepSeek r1 671B model: " MODEL_PATH
    if [ -z "$MODEL_PATH" ]; then
        print_error "Model path cannot be empty."
        return 1
    fi
    
    if [ ! -d "$MODEL_PATH" ]; then
        print_warning "Model directory '$MODEL_PATH' does not exist."
        read -p "Do you want to create it? (y/n): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            mkdir -p "$MODEL_PATH"
        fi
    fi
    
    # Get other parameters with defaults
    read -p "Enter tensor parallel size [16]: " TENSOR_PARALLEL_SIZE
    TENSOR_PARALLEL_SIZE=${TENSOR_PARALLEL_SIZE:-16}
    
    read -p "Enter server host [0.0.0.0]: " HOST
    HOST=${HOST:-0.0.0.0}
    
    read -p "Enter server port [8000]: " PORT
    PORT=${PORT:-8000}
    
    read -p "Enter cache directory (optional): " CACHE_DIR
    
    # Create deployment configuration file
    cat > deployment_config.env <<EOF
MODEL_PATH="$MODEL_PATH"
TENSOR_PARALLEL_SIZE=$TENSOR_PARALLEL_SIZE
HOST="$HOST"
PORT=$PORT
CACHE_DIR="$CACHE_DIR"
EOF
    
    print_success "Deployment configuration saved to deployment_config.env"
    
    return 0
}

# Deploy the model using the Python script
deploy_model() {
    print_info "Deploying DeepSeek r1 671B model..."
    
    # Load configuration
    if [ -f "deployment_config.env" ]; then
        source deployment_config.env
    else
        print_error "Deployment configuration not found."
        return 1
    fi
    
    # Activate virtual environment if it exists
    if [ -d "venv" ]; then
        source venv/bin/activate
    fi
    
    # Build command
    CMD="python3 deploy_deepseek_r1_671b.py --model_path \"$MODEL_PATH\" --tensor_parallel_size $TENSOR_PARALLEL_SIZE --host \"$HOST\" --port $PORT"
    
    if [ ! -z "$CACHE_DIR" ]; then
        CMD="$CMD --cache_dir \"$CACHE_DIR\""
    fi
    
    # Run deployment
    print_info "Running command: $CMD"
    eval $CMD
    
    if [ $? -eq 0 ]; then
        print_success "DeepSeek r1 671B model deployed successfully."
        print_info "API is available at: http://$HOST:$PORT"
        print_info "Test with: curl -X POST http://$HOST:$PORT -H \"Content-Type: application/json\" -d '{\"prompt\":\"Hello, world\",\"max_new_tokens\":512}'"
    else
        print_error "Failed to deploy the model."
        return 1
    fi
    
    return 0
}

# Test the deployed model
test_model() {
    if [ -f "deployment_config.env" ]; then
        source deployment_config.env
    else
        HOST="0.0.0.0"
        PORT=8000
    fi
    
    print_info "Testing model API..."
    
    # Simple test with curl
    curl -X POST http://$HOST:$PORT \
         -H "Content-Type: application/json" \
         -d '{"prompt":"DeepSeek r1 671B is a large language model that can","max_new_tokens":50,"temperature":0.7}'
    
    echo ""
    print_info "If you see generated text, the API is working correctly."
}

# Stop the Ray cluster
stop_ray() {
    print_info "Stopping Ray cluster..."
    ray stop
    print_success "Ray cluster stopped."
}

# Main menu
show_menu() {
    echo ""
    echo "===== DeepSeek r1 671B Deployment with Ray (16 GPUs) ====="
    echo "1. Check dependencies"
    echo "2. Install requirements"
    echo "3. Start Ray head node"
    echo "4. Configure model deployment"
    echo "5. Deploy model"
    echo "6. Test deployed model"
    echo "7. Stop Ray cluster"
    echo "8. Exit"
    echo "========================================================"
    echo ""
    read -p "Enter your choice [1-8]: " choice
    
    case $choice in
        1) check_dependencies ;;
        2) install_requirements ;;
        3) start_ray_head ;;
        4) configure_deployment ;;
        5) deploy_model ;;
        6) test_model ;;
        7) stop_ray ;;
        8) exit 0 ;;
        *) print_error "Invalid choice. Please try again." ;;
    esac
    
    # Return to menu
    show_menu
}

# Script entry point
main() {
    # Print banner
    echo "====================================================="
    echo "  DeepSeek r1 671B Deployment Script with Ray (16 GPUs)"
    echo "====================================================="
    echo ""
    
    # Check if running as root/sudo
    check_root
    
    # Process command line arguments
    if [ "$1" = "all" ]; then
        check_dependencies
        install_requirements
        start_ray_head
        configure_deployment
        deploy_model
    elif [ "$1" = "deploy" ]; then
        deploy_model
    elif [ "$1" = "stop" ]; then
        stop_ray
    elif [ "$1" = "test" ]; then
        test_model
    else
        # Show interactive menu
        show_menu
    fi
}

# Run main function
main "$@" 