#!/bin/bash

# DeepSeek r1 671B Multi-Node Deployment Script with Ray
# =====================================================
# This script helps set up a Ray cluster across multiple nodes
# for deploying the DeepSeek r1 671B model with 16 GPUs distributed
# across different machines.

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
    echo "DeepSeek r1 671B Multi-Node Deployment with Ray"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --head                Start the head node (run this first on one machine)"
    echo "  --worker              Start a worker node (run this on other machines)"
    echo "  --head-address <addr> Address of the head node (required for worker nodes)"
    echo "  --gpus <num>          Number of GPUs to use on this node (default: all)"
    echo "  --cpus <num>          Number of CPUs to use on this node (default: all)"
    echo "  --stop                Stop the Ray cluster on this node"
    echo "  --deploy              Deploy the model after cluster setup"
    echo "  --help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  # On the head node:"
    echo "  $0 --head"
    echo ""
    echo "  # On worker nodes:"
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

# Start Ray head node
start_head() {
    print_info "Starting Ray head node..."
    
    # Get number of GPUs and CPUs
    if [ -z "$NUM_GPUS" ]; then
        NUM_GPUS=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
    fi
    
    if [ -z "$NUM_CPUS" ]; then
        NUM_CPUS=$(nproc)
    fi
    
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
        print_info "Use this address when connecting worker nodes:"
        print_info "  $0 --worker --head-address $IP_ADDRESS:6379"
    else
        print_error "Failed to start Ray head node."
        exit 1
    fi
}

# Start Ray worker node
start_worker() {
    if [ -z "$HEAD_ADDRESS" ]; then
        print_error "Head node address is required for worker nodes."
        print_info "Use: $0 --worker --head-address <head_ip>:6379"
        exit 1
    fi
    
    print_info "Starting Ray worker node connecting to $HEAD_ADDRESS..."
    
    # Get number of GPUs and CPUs
    if [ -z "$NUM_GPUS" ]; then
        NUM_GPUS=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
    fi
    
    if [ -z "$NUM_CPUS" ]; then
        NUM_CPUS=$(nproc)
    fi
    
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

# Deploy model on the cluster
deploy_model() {
    print_info "Deploying DeepSeek r1 671B model on the Ray cluster..."
    
    # Check if config file exists
    if [ ! -f "deployment_config.env" ]; then
        print_info "Creating new deployment configuration..."
        
        # Get model path
        read -p "Enter the path to DeepSeek r1 671B model: " MODEL_PATH
        if [ -z "$MODEL_PATH" ]; then
            print_error "Model path cannot be empty."
            return 1
        fi
        
        # Set default values
        TENSOR_PARALLEL_SIZE=16
        HOST="0.0.0.0"
        PORT=8000
        
        # Create config file
        cat > deployment_config.env <<EOF
MODEL_PATH="$MODEL_PATH"
TENSOR_PARALLEL_SIZE=$TENSOR_PARALLEL_SIZE
HOST="$HOST"
PORT=$PORT
EOF
        print_success "Created deployment configuration"
    else
        print_info "Using existing deployment configuration from deployment_config.env"
        source deployment_config.env
    fi
    
    # Check if deployment script exists
    if [ ! -f "deploy_deepseek_r1_671b.py" ]; then
        print_error "Deployment script deploy_deepseek_r1_671b.py not found"
        exit 1
    fi
    
    # Run deployment
    print_info "Executing deployment script..."
    python3 deploy_deepseek_r1_671b.py \
        --model_path "$MODEL_PATH" \
        --tensor_parallel_size "$TENSOR_PARALLEL_SIZE" \
        --host "$HOST" \
        --port "$PORT" \
        --ray_address "auto"
    
    if [ $? -eq 0 ]; then
        print_success "DeepSeek r1 671B model deployed successfully on the cluster"
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
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --help)
                show_help
                exit 0
                ;;
            --head)
                MODE="head"
                shift
                ;;
            --worker)
                MODE="worker"
                shift
                ;;
            --stop)
                MODE="stop"
                shift
                ;;
            --deploy)
                MODE="deploy"
                shift
                ;;
            --head-address)
                HEAD_ADDRESS="$2"
                shift 2
                ;;
            --gpus)
                NUM_GPUS="$2"
                shift 2
                ;;
            --cpus)
                NUM_CPUS="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Check Ray installation
    check_ray
    
    # Execute requested mode
    case "$MODE" in
        head)
            start_head
            ;;
        worker)
            start_worker
            ;;
        stop)
            stop_ray
            ;;
        deploy)
            deploy_model
            ;;
        check)
            check_cluster
            ;;
        *)
            print_error "No valid mode specified."
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@" 