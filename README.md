# DeepSeek AWQ Inference Script

This script simplifies running DeepSeek V3 or R1 models with AWQ-INT4 precision on a single machine with 8 GPUs.

## Requirements

- Python 3.6+
- vllm with DeepSeek support
- 8 GPUs (e.g., K100AI, BW)
- DeepSeek V3 or R1 model with AWQ-INT4 quantization

## Usage

### Option 1: Using the Shell Script (Recommended)

Make both scripts executable:

```bash
chmod +x run_deepseek.sh run_deepseek_awq.py
```

#### Benchmark Mode

```bash
./run_deepseek.sh --model /path/to/DeepSeek-V3-AWQ --benchmark
```

#### Server Mode

Basic server:
```bash
./run_deepseek.sh --model /path/to/DeepSeek-V3-AWQ --server --port 8000
```

Server with reasoning capabilities:
```bash
./run_deepseek.sh --model /path/to/DeepSeek-R1-AWQ --server --enable-reasoning --reasoning-parser default --max-num-seqs 30
```

#### Additional Shell Script Options

```
Options:
  -m, --model PATH        Path to the DeepSeek model (required)
  -b, --benchmark         Run in benchmark mode
  -s, --server            Run in server mode
  -l, --max-len LENGTH    Max model context length (default: 18000)
  -p, --port PORT         Server port (default: 8000, server mode only)
  -np, --num-prompts NUM  Number of prompts for benchmark (default: 1)
  -il, --input-len LEN    Input length for benchmark (default: 2)
  -ol, --output-len LEN   Output length for benchmark (default: 128)
  -tp, --tp-size SIZE     Tensor parallel size (default: 8)
  -g, --gpu-util FACTOR   GPU memory utilization (default: 0.97)
  --enable-reasoning      Enable reasoning capabilities (server mode only)
  --reasoning-parser TYPE Specify reasoning parser type (requires --enable-reasoning)
  --max-num-seqs NUM      Maximum number of sequences (server mode only)
  -h, --help              Display this help message
```

### Option 2: Using the Python Script Directly

Make the Python script executable:

```bash
chmod +x run_deepseek_awq.py
```

#### Running Benchmark

To test the model's throughput performance:

```bash
./run_deepseek_awq.py \
  --mode benchmark \
  --model-path /path/to/DeepSeek-V3-AWQ \
  --num-prompts 1 \
  --input-len 2 \
  --output-len 128 \
  --max-model-len 12800
```

#### Running Server

Basic server:
```bash
./run_deepseek_awq.py \
  --mode server \
  --model-path /path/to/DeepSeek-V3-AWQ \
  --max-model-len 18000 \
  --port 8000
```

Server with reasoning capabilities:
```bash
./run_deepseek_awq.py \
  --mode server \
  --model-path /path/to/DeepSeek-R1-Int4-AWQ \
  --max-model-len 13000 \
  --tensor-parallel-size 8 \
  --enable-reasoning \
  --reasoning-parser default \
  --max-num-seqs 30
```

## Python Script Parameters

### Common Parameters

- `--model-path`: Path to the DeepSeek model (DeepSeek-V3-AWQ or DeepSeek-R1-AWQ)
- `--mode`: Run mode, either `benchmark` or `server`
- `--tensor-parallel-size`: Tensor parallel size (default: 8)
- `--max-model-len`: Maximum model context length (default: 18000)
- `--gpu-memory-utilization`: GPU memory utilization factor (default: 0.97)

### Benchmark Mode Parameters

- `--num-prompts`: Number of prompts for benchmark testing (default: 1)
- `--input-len`: Input length for benchmark testing (default: 2)
- `--output-len`: Output length for benchmark testing (default: 128)

### Server Mode Parameters

- `--port`: Port for the vllm server (optional)
- `--enable-reasoning`: Enable reasoning capabilities (flag without value)
- `--reasoning-parser`: Specify the reasoning parser to use (requires `--enable-reasoning`)
- `--max-num-seqs`: Maximum number of sequences for inference

## Environment Variables

The script automatically sets the following environment variables:

- `HIP_VISIBLE_DEVICES=0,1,2,3,4,5,6,7`
- `VLLM_MLA_DISABLE=1`
- `ALLREDUCE_STREAM_WITH_COMPUTE=1`
- `NCCL_MIN_NCHANNELS=16`
- `NCCL_MAX_NCHANNELS=16`

## Notes

- For K100AI and BW GPUs with 8 cards, the maximum supported context length is 18k tokens.
- Script ensures all required environment variables are set correctly.
- The `--reasoning-parser` flag requires a value whenever used with `--enable-reasoning`. 