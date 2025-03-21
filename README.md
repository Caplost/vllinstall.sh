# DeepSeek r1 671B Deployment with Ray (16 GPUs)

This repository contains scripts for deploying the DeepSeek r1 671B large language model using Ray for distributed inference across 16 GPUs.

## Requirements

- Python 3.8+
- PyTorch 2.0+
- Ray 2.9.0+
- 16 GPUs with sufficient VRAM (80GB+ per GPU recommended for the 671B model)
- NVIDIA drivers and CUDA toolkit
- DeepSeek-specific packages

## Files Overview

- `deploy_deepseek_r1_671b.py`: Main Python script for model deployment
- `deploy_deepseek_r1_671b.sh`: Interactive shell script for single-node deployment
- `deploy_deepseek_r1_671b_multi_node.sh`: Script for multi-node deployment

## Single-Node Deployment (16 GPUs on one machine)

For a single machine with 16 GPUs, you can use the interactive deployment script:

```bash
chmod +x deploy_deepseek_r1_671b.sh
./deploy_deepseek_r1_671b.sh
```

This will guide you through the following steps:
1. Checking system dependencies
2. Installing required packages
3. Starting a Ray cluster
4. Configuring the model deployment
5. Deploying the model
6. Testing the deployed model

Alternatively, run the whole process at once:

```bash
./deploy_deepseek_r1_671b.sh all
```

## Multi-Node Deployment (GPUs distributed across machines)

When your 16 GPUs are distributed across multiple machines, use the multi-node deployment script:

### On the head node:

```bash
chmod +x deploy_deepseek_r1_671b_multi_node.sh
./deploy_deepseek_r1_671b_multi_node.sh --head
```

This will start the Ray head node and display the address to use for worker nodes.

### On each worker node:

```bash
./deploy_deepseek_r1_671b_multi_node.sh --worker --head-address <head_ip>:6379
```

Replace `<head_ip>` with the IP address of your head node.

### Deploy the model (run on the head node):

```bash
./deploy_deepseek_r1_671b_multi_node.sh --deploy
```

This will deploy the DeepSeek r1 671B model across all available GPUs in the cluster.

## API Usage

Once deployed, the model serves an HTTP API on port 8000 by default. Here's how to use it:

### Generate text

```bash
curl -X POST http://localhost:8000 \
     -H "Content-Type: application/json" \
     -d '{
       "prompt": "DeepSeek r1 671B is a large language model that can",
       "max_new_tokens": 512,
       "temperature": 0.7,
       "top_p": 0.9,
       "top_k": 50,
       "repetition_penalty": 1.1
     }'
```

### API Parameters

- `prompt`: Text input to the model
- `max_new_tokens`: Maximum number of tokens to generate (default: 512)
- `temperature`: Controls randomness (default: 0.7)
- `top_p`: Nucleus sampling parameter (default: 0.9)
- `top_k`: Top-k sampling parameter (default: 50)
- `repetition_penalty`: Penalizes repetition (default: 1.1)

## Stopping the Cluster

To stop the Ray cluster:

```bash
# Single-node
./deploy_deepseek_r1_671b.sh
# Then select option 7 from the menu

# Multi-node
./deploy_deepseek_r1_671b_multi_node.sh --stop
```

## Troubleshooting

### Insufficient GPU Memory

The DeepSeek r1 671B model requires significant GPU memory. If you encounter CUDA out-of-memory errors:

1. Ensure each GPU has enough VRAM (80GB+ per GPU recommended)
2. Try increasing the level of tensor parallelism
3. Reduce batch size and sequence length parameters

### Connection Issues in Multi-Node Setup

If worker nodes cannot connect to the head node:

1. Ensure firewalls allow connections on port 6379
2. Verify all machines can communicate on the network
3. Make sure the correct IP address is used for the head node

### Model Loading Failures

If the model fails to load:

1. Verify the model path is correct
2. Ensure all required DeepSeek packages are installed
3. Check for compatibility between the model and DeepSeek library versions

## Advanced Configuration

For advanced configurations, you can directly edit the Python deployment script or pass additional parameters:

```bash
python3 deploy_deepseek_r1_671b.py \
    --model_path /path/to/model \
    --tensor_parallel_size 16 \
    --max_batch_size 16 \
    --max_input_length 2048 \
    --max_output_length 2048 \
    --host 0.0.0.0 \
    --port 8000 \
    --ray_address auto
``` 