#!/bin/bash

# Wrapper script for run_deepseek_awq.py that makes it easier to run 
# DeepSeek V3 or R1 with AWQ-INT4 precision on 8 GPUs

# Default values
MODEL_PATH=""
MODE=""
MAX_MODEL_LEN=18000
PORT=8000
TENSOR_PARALLEL_SIZE=8
GPU_MEMORY_UTILIZATION=0.97
ENABLE_REASONING=false
REASONING_PARSER=""
MAX_NUM_SEQS=""

# Benchmark defaults
NUM_PROMPTS=1
INPUT_LEN=2
OUTPUT_LEN=128

# Function to display usage
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -m, --model PATH        Path to the DeepSeek model (required)"
    echo "  -b, --benchmark         Run in benchmark mode"
    echo "  -s, --server            Run in server mode"
    echo "  -l, --max-len LENGTH    Max model context length (default: 18000)"
    echo "  -p, --port PORT         Server port (default: 8000, server mode only)"
    echo "  -np, --num-prompts NUM  Number of prompts for benchmark (default: 1)"
    echo "  -il, --input-len LEN    Input length for benchmark (default: 2)"
    echo "  -ol, --output-len LEN   Output length for benchmark (default: 128)"
    echo "  -tp, --tp-size SIZE     Tensor parallel size (default: 8)"
    echo "  -g, --gpu-util FACTOR   GPU memory utilization (default: 0.97)"
    echo "  --enable-reasoning      Enable reasoning capabilities (server mode only)"
    echo "  --reasoning-parser TYPE Specify reasoning parser type (requires --enable-reasoning)"
    echo "  --max-num-seqs NUM      Maximum number of sequences (server mode only)"
    echo "  -h, --help              Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --model /path/to/DeepSeek-V3-AWQ --benchmark"
    echo "  $0 --model /path/to/DeepSeek-R1-AWQ --server --port 9000"
    echo "  $0 --model /path/to/DeepSeek-R1-AWQ --server --enable-reasoning --reasoning-parser default"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)
            MODEL_PATH="$2"
            shift 2
            ;;
        -b|--benchmark)
            MODE="benchmark"
            shift
            ;;
        -s|--server)
            MODE="server"
            shift
            ;;
        -l|--max-len)
            MAX_MODEL_LEN="$2"
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -np|--num-prompts)
            NUM_PROMPTS="$2"
            shift 2
            ;;
        -il|--input-len)
            INPUT_LEN="$2"
            shift 2
            ;;
        -ol|--output-len)
            OUTPUT_LEN="$2"
            shift 2
            ;;
        -tp|--tp-size)
            TENSOR_PARALLEL_SIZE="$2"
            shift 2
            ;;
        -g|--gpu-util)
            GPU_MEMORY_UTILIZATION="$2"
            shift 2
            ;;
        --enable-reasoning)
            ENABLE_REASONING=true
            shift
            ;;
        --reasoning-parser)
            REASONING_PARSER="$2"
            shift 2
            ;;
        --max-num-seqs)
            MAX_NUM_SEQS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check required arguments
if [ -z "$MODEL_PATH" ]; then
    echo "Error: Model path is required"
    usage
fi

if [ -z "$MODE" ]; then
    echo "Error: Mode (--benchmark or --server) is required"
    usage
fi

# Check if reasoning-parser is provided without enable-reasoning
if [ -n "$REASONING_PARSER" ] && [ "$ENABLE_REASONING" = false ]; then
    echo "Error: --reasoning-parser requires --enable-reasoning flag"
    usage
fi

# Build the command
CMD="./run_deepseek_awq.py --model-path \"$MODEL_PATH\" --mode $MODE --max-model-len $MAX_MODEL_LEN --tensor-parallel-size $TENSOR_PARALLEL_SIZE --gpu-memory-utilization $GPU_MEMORY_UTILIZATION"

# Add mode-specific parameters
if [ "$MODE" == "benchmark" ]; then
    CMD="$CMD --num-prompts $NUM_PROMPTS --input-len $INPUT_LEN --output-len $OUTPUT_LEN"
elif [ "$MODE" == "server" ]; then
    CMD="$CMD --port $PORT"
    
    # Add reasoning options if enabled
    if [ "$ENABLE_REASONING" = true ]; then
        CMD="$CMD --enable-reasoning"
        if [ -n "$REASONING_PARSER" ]; then
            CMD="$CMD --reasoning-parser \"$REASONING_PARSER\""
        fi
    fi
    
    # Add max number of sequences if specified
    if [ -n "$MAX_NUM_SEQS" ]; then
        CMD="$CMD --max-num-seqs $MAX_NUM_SEQS"
    fi
fi

# Print the command
echo "Running command: $CMD"
echo ""

# Execute the command
eval $CMD 