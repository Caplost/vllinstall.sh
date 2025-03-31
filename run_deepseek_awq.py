#!/usr/bin/env python3
import os
import subprocess
import argparse
import sys
from pathlib import Path

def set_environment_variables():
    """Set required environment variables for DeepSeek inference with 8 GPUs."""
    os.environ["HIP_VISIBLE_DEVICES"] = "0,1,2,3,4,5,6,7"
    os.environ["VLLM_MLA_DISABLE"] = "1"  # Required setting
    os.environ["ALLREDUCE_STREAM_WITH_COMPUTE"] = "1"
    os.environ["NCCL_MIN_NCHANNELS"] = "16"
    os.environ["NCCL_MAX_NCHANNELS"] = "16"
    
    # Print environment settings for confirmation
    print("Environment variables set:")
    print(f"HIP_VISIBLE_DEVICES = {os.environ['HIP_VISIBLE_DEVICES']}")
    print(f"VLLM_MLA_DISABLE = {os.environ['VLLM_MLA_DISABLE']}")
    print(f"ALLREDUCE_STREAM_WITH_COMPUTE = {os.environ['ALLREDUCE_STREAM_WITH_COMPUTE']}")
    print(f"NCCL_MIN_NCHANNELS = {os.environ['NCCL_MIN_NCHANNELS']}")
    print(f"NCCL_MAX_NCHANNELS = {os.environ['NCCL_MAX_NCHANNELS']}")

def run_benchmark(args):
    """Run the benchmark test for DeepSeek model."""
    cmd = [
        "python", "./benchmark_throughput.py",
        "--model", args.model_path,
        "--num-prompts", str(args.num_prompts),
        "--input-len", str(args.input_len),
        "--output-len", str(args.output_len),
        "-tp", str(args.tensor_parallel_size),
        "--trust-remote-code",
        "--dtype", "float16",
        "-q", "moe_wna16",
        "--max-model-len", str(args.max_model_len),
        "--gpu-memory-utilization", str(args.gpu_memory_utilization)
    ]
    
    print(f"Running benchmark command: {' '.join(cmd)}")
    subprocess.run(cmd)

def run_server(args):
    """Run the vllm server with DeepSeek model."""
    cmd = [
        "vllm", "serve",
        args.model_path,
        "--trust-remote-code",
        "--dtype", "float16",
        "--max-model-len", str(args.max_model_len),
        "-tp", str(args.tensor_parallel_size),
        "-q", "moe_wna16",
        "--gpu-memory-utilization", str(args.gpu_memory_utilization)
    ]
    
    # Add optional server port if specified
    if args.port:
        cmd.extend(["--port", str(args.port)])
    
    # Add reasoning capabilities if enabled
    if args.enable_reasoning:
        cmd.append("--enable-reasoning")
        
    # Add reasoning parser if specified
    if args.reasoning_parser:
        cmd.extend(["--reasoning-parser", args.reasoning_parser])
    
    # Add max number of sequences if specified
    if args.max_num_seqs:
        cmd.extend(["--max-num-seqs", str(args.max_num_seqs)])
    
    print(f"Running server command: {' '.join(cmd)}")
    subprocess.run(cmd)

def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Run DeepSeek V3 or R1 with AWQ-INT4 precision on 8 GPUs",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    
    parser.add_argument(
        "--model-path", 
        required=True,
        help="Path to the DeepSeek model (DeepSeek-V3-AWQ or DeepSeek-R1-AWQ)"
    )
    
    parser.add_argument(
        "--mode",
        choices=["benchmark", "server"],
        required=True,
        help="Run mode: benchmark for throughput testing or server for API service"
    )
    
    # Benchmark specific parameters
    parser.add_argument(
        "--num-prompts",
        type=int,
        default=1,
        help="Number of prompts for benchmark testing"
    )
    
    parser.add_argument(
        "--input-len",
        type=int,
        default=2,
        help="Input length for benchmark testing"
    )
    
    parser.add_argument(
        "--output-len",
        type=int,
        default=128,
        help="Output length for benchmark testing"
    )
    
    # Common parameters
    parser.add_argument(
        "--tensor-parallel-size", "-tp",
        type=int,
        default=8,
        help="Tensor parallel size (should be 8 for 8 GPUs)"
    )
    
    parser.add_argument(
        "--max-model-len",
        type=int,
        default=18000,
        help="Maximum model context length (up to 18k for AWQ-INT4 on 8 K100AI/BW GPUs)"
    )
    
    parser.add_argument(
        "--gpu-memory-utilization",
        type=float,
        default=0.97,
        help="GPU memory utilization factor"
    )
    
    # Server specific parameters
    parser.add_argument(
        "--port",
        type=int,
        default=None,
        help="Port for the vllm server (server mode only)"
    )
    
    # Reasoning capabilities (server mode only)
    parser.add_argument(
        "--enable-reasoning",
        action="store_true",
        help="Enable reasoning capabilities (server mode only)"
    )
    
    parser.add_argument(
        "--reasoning-parser",
        type=str,
        default=None,
        help="Specify the reasoning parser to use with --enable-reasoning (server mode only)"
    )
    
    parser.add_argument(
        "--max-num-seqs",
        type=int,
        default=None,
        help="Maximum number of sequences (server mode only)"
    )
    
    return parser.parse_args()

def main():
    args = parse_arguments()
    
    # Validate tensor parallel size
    if args.tensor_parallel_size != 8:
        print("Warning: It's recommended to use tensor parallel size of 8 for 8 GPUs")
        response = input("Continue anyway? (y/n): ")
        if response.lower() != 'y':
            sys.exit(0)
    
    # Set environment variables
    set_environment_variables()
    
    # Check if model path exists
    model_path = Path(args.model_path)
    if not model_path.exists():
        print(f"Error: Model path '{args.model_path}' does not exist")
        sys.exit(1)
    
    # Run the appropriate mode
    if args.mode == "benchmark":
        run_benchmark(args)
    elif args.mode == "server":
        run_server(args)

if __name__ == "__main__":
    main() 