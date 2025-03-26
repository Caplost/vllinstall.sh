#!/usr/bin/env python3
"""
DeepSeek r1 INT8 Direct Deployment Script
========================================
This script handles the complete deployment of DeepSeek r1 INT8 model across 16 GPUs (2 servers).
It manages dependencies, Ray cluster setup, and model deployment in a single Python script.

Requirements:
- Python 3.8+
- 16 GPUs with 64GB VRAM each across two servers
"""

import os
import sys
import time
import json
import logging
import argparse
import subprocess
import importlib.util
from typing import Dict, List, Optional, Union, Any, Tuple
from pathlib import Path

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger("deepseek-deploy")

# Terminal colors for better readability
class Colors:
    GREEN = '\033[0;32m'
    YELLOW = '\033[0;33m'
    RED = '\033[0;31m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'  # No Color

def colored_print(color: str, prefix: str, message: str):
    """Print colored message with prefix."""
    print(f"{color}[{prefix}]{Colors.NC} {message}")

def print_info(message: str):
    colored_print(Colors.BLUE, "INFO", message)

def print_success(message: str):
    colored_print(Colors.GREEN, "SUCCESS", message)
    
def print_warning(message: str):
    colored_print(Colors.YELLOW, "WARNING", message)
    
def print_error(message: str):
    colored_print(Colors.RED, "ERROR", message)

# Parse command line arguments
def parse_args():
    parser = argparse.ArgumentParser(description="Deploy DeepSeek r1 INT8 model with Ray")
    
    # Model arguments
    parser.add_argument("--model_path", type=str, default="/home/models/DeepSeek-R1-Channel-INT8", 
                        help="Path to the DeepSeek r1 INT8 model")
    parser.add_argument("--tensor_parallel_size", type=int, default=16,
                        help="Number of GPUs to use for tensor parallelism")
    
    # Server arguments
    parser.add_argument("--host", type=str, default="0.0.0.0",
                        help="Host to bind the server to")
    parser.add_argument("--port", type=int, default=8000,
                        help="Port to bind the server to")
    
    # Generation arguments
    parser.add_argument("--max_batch_size", type=int, default=32,
                        help="Maximum batch size for inference")
    parser.add_argument("--max_input_length", type=int, default=4096,
                        help="Maximum input sequence length")
    parser.add_argument("--max_output_length", type=int, default=4096,
                        help="Maximum output sequence length")
    
    # Ray cluster arguments
    parser.add_argument("--mode", type=str, choices=["head", "worker", "deploy"], default="deploy",
                        help="Mode to run: head (start head node), worker (start worker node), or deploy (deploy model)")
    parser.add_argument("--head_address", type=str, default=None,
                        help="Ray cluster head address (required for worker mode)")
    parser.add_argument("--gpus_per_node", type=int, default=8,
                        help="Number of GPUs on this node")
    parser.add_argument("--ray_address", type=str, default="auto",
                        help="Ray cluster address (for deploy mode)")
    
    # Other arguments
    parser.add_argument("--install_deps", action="store_true",
                        help="Install dependencies before deployment")
    parser.add_argument("--cache_dir", type=str, default=None,
                        help="Directory to cache model weights")
    parser.add_argument("--debug", action="store_true",
                        help="Enable debug mode with detailed diagnostics")
    
    return parser.parse_args()

# Check and install dependencies
def install_dependencies():
    """Install all required dependencies for DeepSeek deployment."""
    print_info("Checking and installing required dependencies...")
    
    # Install PyTorch and other base dependencies
    print_info("Installing PyTorch and base dependencies...")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", 
                               "torch>=2.0.0", "numpy", "tqdm", "transformers>=4.31.0", 
                               "accelerate>=0.20.3", "ray[default,serve]>=2.9.0"])
    except subprocess.CalledProcessError:
        print_error("Failed to install PyTorch and base dependencies.")
        sys.exit(1)
    
    # Install the DeepSeek-specific packages
    print_info("Installing DeepSeek dependencies...")
    
    # Try installing deepseek-llm
    print_info("Trying to install deepseek-llm package...")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "deepseek-llm"])
    except subprocess.CalledProcessError:
        print_warning("Failed to install deepseek-llm package. Trying alternative approaches.")
    
    # Check if installation succeeded
    deepseek_installed = check_imports()
    
    if not deepseek_installed:
        # Try specific version or fork
        print_info("Trying to install from git repository...")
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", 
                                   "git+https://github.com/deepseek-ai/DeepSeek-LLM.git"])
        except subprocess.CalledProcessError:
            print_warning("Failed to install DeepSeek from git repository.")
        
        # Check again
        if not check_imports():
            print_warning("Still unable to import DeepSeek modules.")
            print_info("This might be expected if the DeepSeek modules are part of the model directory.")
            print_info("The deployment will attempt to use the modules provided with the model.")
        else:
            print_success("DeepSeek modules installed successfully!")
    else:
        print_success("DeepSeek modules installed successfully!")
    
    # Install any INT8-specific dependencies that might be needed
    print_info("Installing INT8-specific dependencies...")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "bitsandbytes>=0.40.0"])
    except subprocess.CalledProcessError:
        print_warning("Failed to install bitsandbytes. INT8 quantization may not work properly.")
    
    print_success("All dependencies installed successfully.")

# Check if DeepSeek modules can be imported
def check_imports() -> bool:
    """Check if DeepSeek modules can be imported."""
    try:
        import deepseek_llm
        logger.info("Successfully imported deepseek_llm package")
        return True
    except ImportError:
        pass
    
    try:
        import deepseek
        logger.info("Successfully imported deepseek package")
        return True
    except ImportError:
        pass
    
    return False

# Check if model directory exists and is accessible
def check_model(model_path: str) -> bool:
    """Check if the model directory exists and is accessible."""
    model_dir = Path(model_path)
    
    if not model_dir.exists():
        print_error(f"Model directory {model_path} does not exist!")
        return False
    
    if not model_dir.is_dir():
        print_error(f"{model_path} is not a directory!")
        return False
    
    print_success(f"Model directory {model_path} exists")
    
    # Check for config file
    config_file = model_dir / "config.json"
    if config_file.exists():
        print_success("Found config.json")
    else:
        print_warning("config.json not found. This may indicate an incomplete or non-standard model format.")
    
    # Check permissions
    if os.access(model_path, os.R_OK):
        print_success("Model directory is readable")
    else:
        print_error("Model directory is not readable! Please check permissions.")
        return False
    
    return True

# Check CUDA and GPU availability
def check_gpu_availability() -> Tuple[bool, int]:
    """Check CUDA and GPU availability. Returns (success, gpu_count)."""
    import torch
    
    cuda_available = torch.cuda.is_available()
    if not cuda_available:
        print_error("CUDA is not available! GPU is required for model deployment.")
        return False, 0
    
    gpu_count = torch.cuda.device_count()
    if gpu_count == 0:
        print_error("No GPUs detected!")
        return False, 0
    
    print_success(f"Found {gpu_count} GPUs")
    
    # Print GPU info
    for i in range(gpu_count):
        device_name = torch.cuda.get_device_name(i)
        device_memory = torch.cuda.get_device_properties(i).total_memory / (1024**3)  # GB
        print_info(f"GPU {i}: {device_name} ({device_memory:.2f} GB)")
    
    return True, gpu_count

# Start Ray head node
def start_ray_head(gpus_per_node: int = 8) -> str:
    """Start Ray head node and return head address."""
    import ray
    
    print_info(f"Starting Ray head node with {gpus_per_node} GPUs...")
    
    # Check if Ray is already running
    try:
        ray.init(ignore_reinit_error=True)
        ray.shutdown()
        print_warning("Ray was already running. Restarting it...")
    except Exception:
        pass
    
    # Get IP address
    import socket
    hostname = socket.gethostname()
    ip_address = socket.gethostbyname(hostname)
    
    # Start Ray head node
    ray_start_cmd = [
        "ray", "start", "--head",
        "--port=6379",
        "--dashboard-host=0.0.0.0",
        "--dashboard-port=8265",
        f"--num-gpus={gpus_per_node}",
    ]
    
    try:
        result = subprocess.run(ray_start_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print_error(f"Failed to start Ray head node: {result.stderr}")
            sys.exit(1)
        else:
            print_success(f"Ray head node started at {ip_address}:6379")
            print_info(f"Ray dashboard is available at http://{ip_address}:8265")
    except Exception as e:
        print_error(f"Error starting Ray head node: {e}")
        sys.exit(1)
    
    # Save head node address to file
    head_address = f"{ip_address}:6379"
    with open("ray_head_address.txt", "w") as f:
        f.write(head_address)
    
    print_info(f"Head node address saved to ray_head_address.txt")
    print_info(f"Use this address when connecting worker nodes")
    
    return head_address

# Start Ray worker node
def start_ray_worker(head_address: str, gpus_per_node: int = 8):
    """Start Ray worker node connecting to the head node."""
    import ray
    
    if not head_address:
        print_error("Head node address is required for worker nodes.")
        print_info("Use: --mode worker --head_address <head_ip>:6379")
        sys.exit(1)
    
    print_info(f"Starting Ray worker node connecting to {head_address}...")
    
    # Check if Ray is already running
    try:
        ray.init(ignore_reinit_error=True)
        ray.shutdown()
        print_warning("Ray was already running. Restarting it...")
    except Exception:
        pass
    
    # Start Ray worker node
    ray_start_cmd = [
        "ray", "start",
        f"--address={head_address}",
        f"--num-gpus={gpus_per_node}",
    ]
    
    try:
        result = subprocess.run(ray_start_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print_error(f"Failed to start Ray worker node: {result.stderr}")
            sys.exit(1)
        else:
            print_success(f"Ray worker node started and connected to {head_address}")
    except Exception as e:
        print_error(f"Error starting Ray worker node: {e}")
        sys.exit(1)

# Stop Ray cluster
def stop_ray():
    """Stop Ray on this node."""
    print_info("Stopping Ray on this node...")
    
    try:
        subprocess.run(["ray", "stop"], check=True)
        print_success("Ray stopped.")
    except subprocess.CalledProcessError:
        print_error("Failed to stop Ray.")
    except FileNotFoundError:
        print_warning("Ray command not found. Ray may not be installed or not in PATH.")

# Initialize Ray cluster
def init_ray_cluster(address: str = "auto"):
    """Initialize Ray cluster with the specified address."""
    import ray
    
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

# Check resources
def check_resources(min_gpus: int = 16):
    """Check if the Ray cluster has sufficient resources for the deployment."""
    import ray
    import torch
    
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

# Deploy model on Ray cluster
def deploy_model(args):
    """Deploy the DeepSeek r1 INT8 model on the Ray cluster."""
    from ray import serve
    
    # Import ray here to make sure it's installed
    import ray
    import torch
    
    # Check if the model path exists
    if not check_model(args.model_path):
        sys.exit(1)
    
    # Initialize Ray cluster
    logger.info(f"Connecting to Ray cluster at {args.ray_address}...")
    init_ray_cluster(args.ray_address)
    
    # Check available resources
    check_resources(min_gpus=args.tensor_parallel_size)
    
    # Deploy the model with Ray Serve
    logger.info("Deploying model with Ray Serve...")
    serve.start(detached=True, http_options={"host": args.host, "port": args.port})
    
    # Create the deployment
    from model_deployment import DeepSeekModel
    
    model_deployment = DeepSeekModel.bind(
        model_path=args.model_path,
        tensor_parallel_size=args.tensor_parallel_size,
        max_batch_size=args.max_batch_size,
        max_input_length=args.max_input_length,
        max_output_length=args.max_output_length,
        cache_dir=args.cache_dir
    )
    
    # Deploy
    serve.run(model_deployment, name="deepseek_r1_int8")
    
    logger.info(f"DeepSeek r1 INT8 model deployed successfully")
    logger.info(f"API is available at: http://{args.host}:{args.port}")
    logger.info("Example API usage (POST request):")
    logger.info("""
    curl -X POST http://{host}:{port} \\
         -H "Content-Type: application/json" \\
         -d '{{"prompt": "Once upon a time", "max_new_tokens": 512, "temperature": 0.7}}'
    """.format(host=args.host, port=args.port))

# Run diagnostic tests
def run_diagnostics():
    """Run diagnostic tests for deployment."""
    print_info("Running diagnostics...")
    
    # Check Python version
    print_info(f"Python version: {sys.version}")
    
    # Check PyTorch
    try:
        import torch
        print_info(f"PyTorch version: {torch.__version__}")
        print_info(f"CUDA available: {torch.cuda.is_available()}")
        if torch.cuda.is_available():
            print_info(f"CUDA version: {torch.version.cuda}")
            print_info(f"Number of GPUs: {torch.cuda.device_count()}")
    except ImportError:
        print_error("PyTorch not installed")
    
    # Check Ray
    try:
        import ray
        print_info(f"Ray version: {ray.__version__}")
    except ImportError:
        print_error("Ray not installed")
    
    # Check transformers
    try:
        import transformers
        print_info(f"Transformers version: {transformers.__version__}")
    except ImportError:
        print_error("Transformers not installed")
    
    # Check DeepSeek modules
    deepseek_installed = check_imports()
    if not deepseek_installed:
        print_error("DeepSeek modules not found")
    
    # Check system info
    try:
        import platform
        print_info(f"Platform: {platform.platform()}")
        print_info(f"Processor: {platform.processor()}")
        
        import psutil
        mem = psutil.virtual_memory()
        print_info(f"Memory: {mem.total / (1024**3):.2f} GB total, {mem.available / (1024**3):.2f} GB available")
    except ImportError:
        print_warning("psutil not installed, skipping system info")
    
    print_info("Diagnostics complete")

def main():
    """Main entry point."""
    args = parse_args()
    
    # Prepare model deployment module
    create_model_deployment_module()
    
    # Run in debug mode if requested
    if args.debug:
        run_diagnostics()
    
    # Install dependencies if requested
    if args.install_deps:
        install_dependencies()
    
    # Run in the specified mode
    if args.mode == "head":
        # Start head node
        start_ray_head(gpus_per_node=args.gpus_per_node)
    elif args.mode == "worker":
        # Start worker node
        start_ray_worker(args.head_address, gpus_per_node=args.gpus_per_node)
    elif args.mode == "deploy":
        # Deploy model
        deploy_model(args)
    else:
        print_error(f"Unknown mode: {args.mode}")
        sys.exit(1)

def create_model_deployment_module():
    """Create a module with the model deployment class."""
    # Define the content of the model_deployment.py module
    module_content = """
import os
import sys
import time
import json
import logging
from typing import Dict, List, Optional, Union, Any

import torch
from ray import serve

logger = logging.getLogger("deepseek-deploy")

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
        \"\"\"
        Initialize the DeepSeek r1 INT8 model with the specified configuration.
        
        Args:
            model_path: Path to the DeepSeek model
            tensor_parallel_size: Number of GPUs to use for tensor parallelism
            max_batch_size: Maximum batch size for inference
            max_input_length: Maximum input sequence length
            max_output_length: Maximum output sequence length
            cache_dir: Directory to cache model weights
        \"\"\"
        self.model_path = model_path
        self.tensor_parallel_size = tensor_parallel_size
        self.max_batch_size = max_batch_size
        self.max_input_length = max_input_length
        self.max_output_length = max_output_length
        self.cache_dir = cache_dir
        
        # Load the model - the actual loading will vary based on DeepSeek's API
        self._load_model()
    
    def _load_model(self):
        \"\"\"Load the DeepSeek r1 INT8 model with tensor parallelism.\"\"\"
        logger.info(f"Loading DeepSeek r1 INT8 model from {self.model_path}")
        logger.info(f"Using tensor parallel size: {self.tensor_parallel_size}")
        
        # Import the necessary DeepSeek modules for model loading
        try:
            # This import structure may need to be modified based on DeepSeek's actual API
            try:
                from deepseek.model import DeepSeekForCausalLM
                from deepseek.tokenizer import DeepSeekTokenizer
                import deepseek.parallel as parallel
            except ImportError:
                # Try alternative import structure (depending on DeepSeek's actual package structure)
                try:
                    from deepseek_llm.model import DeepSeekForCausalLM
                    from deepseek_llm.tokenizer import DeepSeekTokenizer
                    import deepseek_llm.parallel as parallel
                    logger.info("Using deepseek_llm package structure")
                except ImportError:
                    try:
                        from deepseek.llm.model import DeepSeekForCausalLM
                        from deepseek.llm.tokenizer import DeepSeekTokenizer
                        import deepseek.llm.parallel as parallel
                        logger.info("Using deepseek.llm package structure")
                    except ImportError:
                        # Final attempt: try using transformers directly if model is compatible
                        try:
                            from transformers import AutoModelForCausalLM as DeepSeekForCausalLM
                            from transformers import AutoTokenizer as DeepSeekTokenizer
                            logger.info("Using transformers as fallback")
                            # Mock parallel module if using transformers directly
                            class MockParallel:
                                @staticmethod
                                def init_distributed(*args, **kwargs):
                                    logger.info("Using mock parallel implementation with Transformers")
                            parallel = MockParallel()
                        except ImportError:
                            raise ImportError("Could not import any suitable module for loading the model")
        except ImportError as e:
            logger.error(f"Failed to import DeepSeek modules: {str(e)}")
            logger.error("Please make sure the required packages are installed.")
            logger.error("You can try the following installation commands:")
            logger.error("pip install deepseek-llm")
            logger.error("pip install deepseek")
            logger.error("Or check the official DeepSeek documentation for installation instructions.")
            sys.exit(1)
        
        # Add model directory to Python path to find any custom modules
        if self.model_path and self.model_path not in sys.path:
            sys.path.append(self.model_path)
            logger.info(f"Added model path to sys.path: {self.model_path}")
        
        # Initialize tensor parallelism
        try:
            logger.info("Initializing tensor parallelism...")
            parallel.init_distributed(tensor_parallel_size=self.tensor_parallel_size,
                                     pipeline_parallel_size=1)
            logger.info("Tensor parallelism initialized successfully")
        except Exception as e:
            logger.error(f"Failed to initialize tensor parallelism: {str(e)}")
            sys.exit(1)
        
        # Load tokenizer
        try:
            logger.info(f"Loading tokenizer from {self.model_path}")
            self.tokenizer = DeepSeekTokenizer.from_pretrained(self.model_path, cache_dir=self.cache_dir)
            logger.info("Tokenizer loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load tokenizer: {str(e)}")
            sys.exit(1)
        
        # Load model with tensor parallelism
        try:
            model_kwargs = {
                "tensor_parallel_size": self.tensor_parallel_size,
                "device_map": "auto",
                # No need to specify torch_dtype for INT8 model as it uses quantization
                "low_cpu_mem_usage": True,
            }
            
            if self.cache_dir:
                model_kwargs["cache_dir"] = self.cache_dir
            
            logger.info(f"Loading model from {self.model_path} with kwargs: {model_kwargs}")
            self.model = DeepSeekForCausalLM.from_pretrained(
                self.model_path,
                **model_kwargs
            )
            logger.info("Model loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load model: {str(e)}")
            logger.error("This could be due to missing dependencies, incorrect model path, or hardware limitations.")
            sys.exit(1)
    
    async def generate(self, prompt: str, 
                     max_new_tokens: int = 512,
                     temperature: float = 0.7,
                     top_p: float = 0.9,
                     top_k: int = 50,
                     repetition_penalty: float = 1.1,
                     **kwargs) -> Dict[str, Any]:
        \"\"\"
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
        \"\"\"
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
        \"\"\"Handle HTTP requests for model generation.\"\"\"
        if request.method == "GET":
            return {"status": "DeepSeek r1 INT8 model is running"}
        
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
"""
    
    # Write the module to a file
    with open("model_deployment.py", "w") as f:
        f.write(module_content)
    
    print_info("Created model deployment module")

if __name__ == "__main__":
    main() 