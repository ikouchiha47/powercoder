import os
import torch
from datasets import load_dataset
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    TrainingArguments,
)
from trl import SFTTrainer
from peft import LoraConfig, get_peft_model
from datasets import load_dataset

from py.prepare_data import prepare_json_data

# Your existing configuration
train_config = {
    "batch_size": 2,
    "num_workers": os.cpu_count(),
    "epochs": 10,
    "bf16": False,
    "fp16": False,
    "gradient_accumulation_steps": 256,
    "context_length": 512,
    "learning_rate": 2e-4,
    "model_name": "Qwen/Qwen1.5-0.5B",
    "out_dir": "outputs/qwen_05b_code",
    "warmup_steps": 5,
    "max_steps": 60,
}

# Load tokenizer and define EOS token
tokenizer = AutoTokenizer.from_pretrained(
    train_config["model_name"], trust_remote_code=True, use_fast=False
)
EOS_TOKEN = tokenizer.eos_token


# Formatting function
def formatting_prompts_func(example):
    return f"### Instruction:\n{example['instruction']}\n\n### Input:\n{example['input']}\n\n### Response:\n{example['output']}\n{EOS_TOKEN}"


# Prepare the dataset (assuming prepare_json_data is defined elsewhere)
data_dir = os.path.abspath("./dataset/train/")
output_file = os.path.abspath("./comments.json")

prepare_json_data(data_dir, output_file)
train_dataset = load_dataset("json", data_files=output_file)["train"]

test_dir = os.path.abspath("./dataset/eval/")
test_file = os.path.abspath("./results.json")

prepare_json_data(data_dir, test_file)
eval_dataset = load_dataset("json", data_files=test_file)

# Define the model
if train_config["bf16"]:
    model = AutoModelForCausalLM.from_pretrained(train_config["model_name"]).to(
        dtype=torch.bfloat16
    )
else:
    model = AutoModelForCausalLM.from_pretrained(train_config["model_name"])

# Configure LoRA
lora_config = LoraConfig(
    r=16,  # Low-rank adaptation dimension
    lora_alpha=16,
    lora_dropout=0.0,
    target_modules=[
        "q_proj",
        "k_proj",
        "v_proj",
        "o_proj",
        "gate_proj",
        "up_proj",
        "down_proj",
    ],
    bias="none",
)

# Wrap the model with LoRA
model = get_peft_model(model, lora_config)

# Training arguments
training_args = TrainingArguments(
    output_dir=f"{train_config['out_dir']}/logs",
    evaluation_strategy="epoch",
    weight_decay=0.01,
    load_best_model_at_end=True,
    per_device_train_batch_size=train_config["batch_size"],
    per_device_eval_batch_size=train_config["batch_size"],
    logging_strategy="epoch",
    save_strategy="epoch",
    num_train_epochs=train_config["epochs"],
    save_total_limit=2,
    # bf16=train_config["bf16"],
    # fp16=train_config["fp16"],
    warmup_steps=train_config["warmup_steps"],
    max_steps=train_config["max_steps"],
    dataloader_num_workers=train_config["num_workers"],
    gradient_accumulation_steps=train_config["gradient_accumulation_steps"],
    learning_rate=train_config["learning_rate"],
    lr_scheduler_type="constant",
)

# Initialize Trainer
trainer = SFTTrainer(
    model=model,
    train_dataset=train_dataset,
    eval_dataset=eval_dataset,
    max_seq_length=train_config["context_length"],
    tokenizer=tokenizer,
    args=training_args,
    formatting_func=formatting_prompts_func,
    packing=True,
)

# Start training
trainer.train()

# Save the model and tokenizer
model.save_pretrained(train_config["out_dir"])
tokenizer.save_pretrained(train_config["out_dir"])
