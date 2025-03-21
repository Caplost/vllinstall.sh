#!/usr/bin/env python3
"""
DeepSeek r1 671B Deployment Script with Ray (16 GPUs)
====================================================
This script sets up a Ray cluster for deploying the DeepSeek r1 671B model across 16 GPUs.
It handles model loading, tensor parallelism, and provides an inference API.

Requirements:
- Python 3.8+
- Ray 2.9.0+
- DeepSeek specific requirements
- 16 GPUs with sufficient VRAM (minimum 80GB per GPU recommended for 671B model)
"""

import os
import sys
import time
import json
import logging
import argparse
from typing import Dict, List, Optional, Union, Any

import ray
import torch
from ray import serve
import numpy as np
from tqdm import tqdm

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger("deepseek-deploy")

# Parse command line arguments
def parse_args():
    parser = argparse.ArgumentParser(description="Deploy DeepSeek r1 671B model with Ray")
    parser.add_argument("--model_path", type=str, required=True, 
                        help="Path to the DeepSeek r1 671B model")
    parser.add_argument("--tensor_parallel_size", type=int, default=16,
                        help="Number of GPUs to use for tensor parallelism")
    parser.add_argument("--host", type=str, default="0.0.0.0",
                        help="Host to bind the server to")
    parser.add_argument("--port", type=int, default=8000,
                        help="Port to bind the server to")
    parser.add_argument("--max_batch_size", type=int, default=32,
                        help="Maximum batch size for inference")
    parser.add_argument("--max_input_length", type=int, default=4096,
                        help="Maximum input sequence length")
    parser.add_argument("--max_output_length", type=int, default=4096,
                        help="Maximum output sequence length")
    parser.add_argument("--ray_address", type=str, default="auto",
                        help="Ray cluster address to connect to")
    parser.add_argument("--cache_dir", type=str, default=None,
                        help="Directory to cache model weights")
    return parser.parse_args()

# Ray cluster initialization
def init_ray_cluster(address: str = "auto"):
    """Initialize Ray cluster with the specified address."""
    if address == "auto":
        # Start a new Ray cluster
        ray.init(include_dashboard=True, dashboard_host="0.0.0.0", dashboard_port=8265)
        logger.info("Started a new Ray cluster")
    else:
        # Connect to an existing Ray cluster
        ray.init(address=address)
        logger.info(f"Connected to Ray cluster at {address}")
    
    # Print Ray cluster info
    cluster_resources = ray.cluster_resources()
    logger.info(f"Cluster resources: {cluster_resources}")
    return cluster_resources

# Ray resources checking
def check_resources(min_gpus: int = 16):
    """Check if the Ray cluster has sufficient resources for the deployment."""
    cluster_resources = ray.cluster_resources()
    available_gpus = cluster_resources.get("GPU", 0)
    
    if available_gpus < min_gpus:
        logger.error(f"Insufficient GPUs: Required {min_gpus}, found {available_gpus}")
        logger.error("Please make sure all GPUs are available and properly configured in Ray")
        sys.exit(1)
    
    logger.info(f"Found {available_gpus} GPUs in the cluster")
    
    # Check GPU memory
    gpu_info = []
    try:
        for i in range(int(available_gpus)):
            with torch.cuda.device(i):
                total_mem = torch.cuda.get_device_properties(i).total_memory / (1024**3)  # in GB
                free_mem = torch.cuda.memory_reserved(i) / (1024**3)  # in GB
                gpu_info.append({
                    "index": i,
                    "name": torch.cuda.get_device_name(i),
                    "total_memory_gb": round(total_mem, 2),
                    "free_memory_gb": round(free_mem, 2)
                })
        
        logger.info(f"GPU Information: {json.dumps(gpu_info, indent=2)}")
    except Exception as e:
        logger.warning(f"Failed to get detailed GPU information: {e}")
    
    return available_gpus

# Model deployment class
@serve.deployment(
    ray_actor_options={"num_gpus": 1, "num_cpus": 4},
    autoscaling_config={"min_replicas": 1, "max_replicas": 1}
)
class DeepSeekModel:
    def __init__(self, 
                 model_path: str,
                 tensor_parallel_size: int = 16,
                 max_batch_size: int = 32,
                 max_input_length: int = 4096,
                 max_output_length: int = 4096,
                 cache_dir: Optional[str] = None):
        """
        Initialize the DeepSeek r1 671B model with the specified configuration.
        
        Args:
            model_path: Path to the DeepSeek model
            tensor_parallel_size: Number of GPUs to use for tensor parallelism
            max_batch_size: Maximum batch size for inference
            max_input_length: Maximum input sequence length
            max_output_length: Maximum output sequence length
            cache_dir: Directory to cache model weights
        """
        self.model_path = model_path
        self.tensor_parallel_size = tensor_parallel_size
        self.max_batch_size = max_batch_size
        self.max_input_length = max_input_length
        self.max_output_length = max_output_length
        self.cache_dir = cache_dir
        
        # Load the model - the actual loading will vary based on DeepSeek's API
        self._load_model()
    
    def _load_model(self):
        """Load the DeepSeek r1 671B model with tensor parallelism."""
        logger.info(f"Loading DeepSeek r1 671B model from {self.model_path}")
        logger.info(f"Using tensor parallel size: {self.tensor_parallel_size}")
        
        # Import the necessary DeepSeek modules for model loading
        try:
            # This import structure may need to be modified based on DeepSeek's actual API
            from deepseek.model import DeepSeekForCausalLM
            from deepseek.tokenizer import DeepSeekTokenizer
            import deepseek.parallel as parallel
        except ImportError:
            logger.error("Failed to import DeepSeek modules. Please make sure they are installed.")
            logger.error("You may need to install with: pip install deepseek-llm")
            sys.exit(1)
        
        # Initialize tensor parallelism
        parallel.init_distributed(tensor_parallel_size=self.tensor_parallel_size,
                                 pipeline_parallel_size=1)
        
        # Load tokenizer
        self.tokenizer = DeepSeekTokenizer.from_pretrained(self.model_path, cache_dir=self.cache_dir)
        
        # Load model with tensor parallelism
        model_kwargs = {
            "tensor_parallel_size": self.tensor_parallel_size,
            "device_map": "auto",
            "torch_dtype": torch.bfloat16,  # Use bfloat16 for better performance
            "low_cpu_mem_usage": True,
        }
        
        if self.cache_dir:
            model_kwargs["cache_dir"] = self.cache_dir
        
        self.model = DeepSeekForCausalLM.from_pretrained(
            self.model_path,
            **model_kwargs
        )
        
        logger.info("Model loaded successfully")
    
    async def generate(self, prompt: str, 
                     max_new_tokens: int = 512,
                     temperature: float = 0.7,
                     top_p: float = 0.9,
                     top_k: int = 50,
                     repetition_penalty: float = 1.1,
                     **kwargs) -> Dict[str, Any]:
        """
        Generate text from the DeepSeek model based on the provided prompt.
        
        Args:
            prompt: Input prompt
            max_new_tokens: Maximum number of tokens to generate
            temperature: Sampling temperature
            top_p: Nucleus sampling parameter
            top_k: Top-k sampling parameter
            repetition_penalty: Repetition penalty parameter
            
        Returns:
            Dictionary containing the generated text and metadata
        """
        logger.info(f"Generating with input length: {len(prompt)}")
        
        # Tokenize input
        inputs = self.tokenizer(prompt, return_tensors="pt").to(device=self.model.device)
        input_length = inputs.input_ids.shape[1]
        
        # Generate
        generation_kwargs = {
            "max_new_tokens": min(max_new_tokens, self.max_output_length),
            "temperature": temperature,
            "top_p": top_p,
            "top_k": top_k,
            "repetition_penalty": repetition_penalty,
            "do_sample": temperature > 0,
            **kwargs
        }
        
        start_time = time.time()
        
        with torch.no_grad():
            output = self.model.generate(**inputs, **generation_kwargs)
        
        # Decode output
        generated_text = self.tokenizer.decode(output[0][input_length:], skip_special_tokens=True)
        
        end_time = time.time()
        generation_time = end_time - start_time
        tokens_per_second = len(output[0]) / generation_time
        
        return {
            "generated_text": generated_text,
            "input_tokens": input_length,
            "generated_tokens": len(output[0]) - input_length,
            "generation_time": generation_time,
            "tokens_per_second": tokens_per_second
        }
    
    async def __call__(self, request) -> Dict[str, Any]:
        """Handle HTTP requests for model generation."""
        if request.method == "GET":
            return {"status": "DeepSeek r1 671B model is running"}
        
        try:
            data = await request.json()
            prompt = data.get("prompt", "")
            params = {k: v for k, v in data.items() if k != "prompt"}
            
            if not prompt:
                return {"error": "No prompt provided"}
            
            result = await self.generate(prompt, **params)
            return result
        except Exception as e:
            logger.error(f"Error during inference: {e}")
            return {"error": str(e)}

# Main deployment function
def deploy_model(args):
    """Deploy the DeepSeek r1 671B model with Ray Serve."""
    # Initialize Ray cluster
    init_ray_cluster(args.ray_address)
    
    # Check available resources
    check_resources(min_gpus=args.tensor_parallel_size)
    
    # Deploy the model with Ray Serve
    logger.info("Deploying model with Ray Serve...")
    serve.start(detached=True, http_options={"host": args.host, "port": args.port})
    
    # Create the deployment
    model_deployment = DeepSeekModel.bind(
        model_path=args.model_path,
        tensor_parallel_size=args.tensor_parallel_size,
        max_batch_size=args.max_batch_size,
        max_input_length=args.max_input_length,
        max_output_length=args.max_output_length,
        cache_dir=args.cache_dir
    )
    
    # Deploy
    serve.run(model_deployment, name="deepseek_r1_671b")
    
    logger.info(f"DeepSeek r1 671B model deployed successfully")
    logger.info(f"API is available at: http://{args.host}:{args.port}")
    logger.info("Example API usage (POST request):")
    logger.info("""
    curl -X POST http://{host}:{port} \\
         -H "Content-Type: application/json" \\
         -d '{{"prompt": "Once upon a time", "max_new_tokens": 512, "temperature": 0.7}}'
    """.format(host=args.host, port=args.port))

# Script entrypoint
if __name__ == "__main__":
    args = parse_args()
    deploy_model(args) 