#!/bin/bash

# DeepSeek r1 INT8 Multi-Node Deployment Script with Ray
# =====================================================
# This script helps set up a Ray cluster across two servers (16 GPUs)
# for deploying the DeepSeek r1 INT8 model.

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
    echo "DeepSeek r1 INT8 Multi-Node Deployment with Ray"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --head                Start the head node (run this first on one server)"
    echo "  --worker              Start a worker node (run this on the second server)"
    echo "  --head-address <addr> Address of the head node (required for worker nodes)"
    echo "  --stop                Stop the Ray cluster on this node"
    echo "  --deploy              Deploy the model after cluster setup"
    echo "  --help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  # On the head node (first server):"
    echo "  $0 --head"
    echo ""
    echo "  # On worker node (second server):"
    echo "  $0 --worker --head-address 192.168.1.100:6379"
    echo ""
    echo "  # Deploy model after cluster setup (run on head node):"
    echo "  $0 --deploy"
    echo ""
}

# Check if Ray is installed
check_ray() {
    if ! command -v ray &>/dev/null; then
        print_error "Ray is not installed or not in PATH."
        print_info "Installing Ray..."
        pip install "ray[default,serve]>=2.9.0"
        
        if ! command -v ray &>/dev/null; then
            print_error "Failed to install Ray. Please install it manually:"
            print_info "pip install 'ray[default,serve]>=2.9.0'"
            exit 1
        fi
    fi
    
    print_success "Ray is installed."
}

# Check and install required dependencies
install_dependencies() {
    print_info "Checking and installing required dependencies..."
    
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
    
    # Install Ray if needed
    if ! command -v ray &>/dev/null; then
        print_info "Installing Ray..."
        pip3 install "ray[default,serve]>=2.9.0"
    fi
    
    # Install PyTorch and other base dependencies
    print_info "Installing PyTorch and base dependencies..."
    pip3 install torch>=2.0.0 numpy tqdm transformers>=4.31.0 accelerate>=0.20.3
    
    # Install the DeepSeek-specific packages
    print_info "Installing DeepSeek dependencies..."
    
    # Try installing deepseek-llm
    print_info "Trying to install deepseek-llm package..."
    pip3 install deepseek-llm
    
    # Check if installation succeeded
    if ! python3 -c "import deepseek_llm" &>/dev/null && ! python3 -c "import deepseek" &>/dev/null; then
        print_warning "Failed to import DeepSeek modules after installation. Trying alternative approaches."
        
        # Try specific version or fork
        print_info "Trying to install from git repository..."
        pip3 install git+https://github.com/deepseek-ai/DeepSeek-LLM.git
        
        # Check again
        if ! python3 -c "import deepseek_llm" &>/dev/null && ! python3 -c "import deepseek" &>/dev/null; then
            print_warning "Still unable to import DeepSeek modules."
            print_info "This might be expected if the DeepSeek modules are part of the model directory."
            print_info "The deployment will attempt to use the modules provided with the model."
        else
            print_success "DeepSeek modules installed successfully!"
        fi
    else
        print_success "DeepSeek modules installed successfully!"
    fi
    
    # Install any INT8-specific dependencies that might be needed
    print_info "Installing INT8-specific dependencies..."
    pip3 install bitsandbytes>=0.40.0
    
    print_success "All dependencies installed successfully."
}

# Start Ray head node on the first server
start_head() {
    print_info "Starting Ray head node..."
    
    # Each server has 8 GPUs
    NUM_GPUS=8
    NUM_CPUS=$(nproc)
    
    # Get IP address
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
        --num-cpus="$NUM_CPUS" \
        --num-gpus="$NUM_GPUS"
    
    # Check if Ray started successfully
    if [ $? -eq 0 ]; then
        print_success "Ray head node started at $IP_ADDRESS:6379"
        print_info "Ray dashboard is available at http://$IP_ADDRESS:8265"
        
        # Save head node address to file
        echo "$IP_ADDRESS:6379" > ray_head_address.txt
        print_info "Head node address saved to ray_head_address.txt"
        print_info "Use this address when connecting worker node:"
        print_info "  $0 --worker --head-address $IP_ADDRESS:6379"
    else
        print_error "Failed to start Ray head node."
        exit 1
    fi
}

# Start Ray worker node on the second server
start_worker() {
    if [ -z "$HEAD_ADDRESS" ]; then
        print_error "Head node address is required for worker nodes."
        print_info "Use: $0 --worker --head-address <head_ip>:6379"
        exit 1
    fi
    
    print_info "Starting Ray worker node connecting to $HEAD_ADDRESS..."
    
    # Each server has 8 GPUs
    NUM_GPUS=8
    NUM_CPUS=$(nproc)
    
    # Start Ray worker node
    ray start --address="$HEAD_ADDRESS" \
        --num-cpus="$NUM_CPUS" \
        --num-gpus="$NUM_GPUS"
    
    # Check if worker started successfully
    if [ $? -eq 0 ]; then
        print_success "Ray worker node started and connected to $HEAD_ADDRESS"
    else
        print_error "Failed to start Ray worker node."
        exit 1
    fi
}

# Stop Ray on this node
stop_ray() {
    print_info "Stopping Ray on this node..."
    ray stop
    print_success "Ray stopped."
}

# Deploy INT8 model on the cluster
deploy_model() {
    print_info "Deploying DeepSeek r1 INT8 model on the Ray cluster..."
    
    # Install dependencies first
    install_dependencies
    
    # Model path is fixed to the INT8 model location
    MODEL_PATH="/home/models/DeepSeek-R1-Channel-INT8"
    TENSOR_PARALLEL_SIZE=16
    HOST="0.0.0.0"
    PORT=8000
    
    # Check if model path exists
    if [ ! -d "$MODEL_PATH" ]; then
        print_error "Model directory $MODEL_PATH does not exist!"
        print_error "Please make sure the model is properly downloaded and placed in the specified location."
        exit 1
    fi
    
    # Check if deployment script exists
    if [ ! -f "deploy_deepseek_r1_671b.py" ]; then
        print_error "Deployment script deploy_deepseek_r1_671b.py not found"
        exit 1
    fi
    
    # Run deployment
    print_info "Executing deployment script..."
    PYTHONPATH=$PYTHONPATH:$MODEL_PATH python3 deploy_deepseek_r1_671b.py \
        --model_path "$MODEL_PATH" \
        --tensor_parallel_size "$TENSOR_PARALLEL_SIZE" \
        --host "$HOST" \
        --port "$PORT" \
        --ray_address "auto"
    
    if [ $? -eq 0 ]; then
        print_success "DeepSeek r1 INT8 model deployed successfully on the cluster"
        print_info "API endpoint: http://$HOST:$PORT"
    else
        print_error "Failed to deploy the model"
        exit 1
    fi
}

# Check cluster status
check_cluster() {
    print_info "Checking Ray cluster status..."
    
    # First, ensure we're connected to a Ray cluster
    if ! ray status &>/dev/null; then
        print_error "Not connected to a Ray cluster"
        exit 1
    fi
    
    # Get cluster status
    ray status
    
    # Check available GPUs across the cluster
    print_info "Available GPUs across the cluster:"
    python3 -c "import ray; ray.init(); print(ray.cluster_resources())" | grep GPU
    
    print_info "To monitor the cluster, visit the Ray dashboard"
}

# Main function
main() {
    # Check command line arguments
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi
    
    # Default values
    WORKER_MODE=false
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --help)
                show_help
                exit 0
                ;;
            --head)
                check_ray
                install_dependencies
                start_head
                shift
                ;;
            --worker)
                check_ray
                install_dependencies
                WORKER_MODE=true
                shift
                ;;
            --head-address)
                HEAD_ADDRESS="$2"
                shift 2
                ;;
            --stop)
                stop_ray
                shift
                ;;
            --deploy)
                deploy_model
                shift
                ;;
            --status)
                check_cluster
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # If worker mode and head address provided, start worker
    if [ "$WORKER_MODE" = true ] && [ ! -z "$HEAD_ADDRESS" ]; then
        start_worker
    fi
}

# Execute main function with all arguments
main "$@" 