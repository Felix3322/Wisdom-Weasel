import torch
import os
import argparse
from pathlib import Path
from transformers import AutoConfig
from optimum.exporters.onnx import main_export
from optimum.exporters.onnx.base import OnnxConfig
from collections import OrderedDict
from typing import Dict, Optional

# Import quantization modules
from onnxruntime.quantization import quantize_dynamic, QuantType


class QwenBaseOnnxConfig(OnnxConfig):
    def __init__(self, config):
        self._config = config

    @property
    def inputs(self) -> OrderedDict[str, Dict[int, str]]:
        return OrderedDict(
            [
                ("input_ids", {0: "batch_size", 1: "sequence_length"}),
                ("attention_mask", {0: "batch_size", 1: "sequence_length"}),
            ]
        )

    @property
    def outputs(self) -> OrderedDict[str, Dict[int, str]]:
        return OrderedDict([("last_hidden_state", {0: "batch_size", 1: "sequence_length", 2: "hidden_size"})])

    def generate_dummy_inputs(self, framework: str = "pt", **kwargs):
        if framework == "pt":
            input_ids = torch.randint(0, self._config.vocab_size, (2, 8))
            attention_mask = torch.ones_like(input_ids)
            return {"input_ids": input_ids, "attention_mask": attention_mask}
        return super().generate_dummy_inputs(framework, **kwargs)

def apply_int8_quantization(model_path: str, quantized_model_path: str):
    """Apply dynamic int8 quantization to ONNX model"""
    print(f"Applying int8 quantization...")
    quantize_dynamic(
        model_input=model_path,
        model_output=quantized_model_path,
        weight_type=QuantType.QInt8
    )
    print(f"Int8 quantized model saved to: {quantized_model_path}")

def apply_int4_quantization(model_id: str, quant_path: str):
    """Apply int4 AWQ quantization"""
    from awq import AutoAWQForCausalLM

    print("Applying INT4 AWQ quantization...")
    # Load model and tokenizer
    model = AutoAWQForCausalLM.from_pretrained(model_id, trust_remote_code=True, safetensors=True)
    tokenizer = model.tokenizer

    quant_config = { "w_bit": 4, "q_group_size": 128, "zero_point": True, "version": "GEMM" }

    # Quantize
    model.quantize(tokenizer, quant_config=quant_config)
    
    # Save quantized model
    model.save_quantized(quant_path)
    tokenizer.save_pretrained(quant_path)
    print(f"Int4 quantized model saved to: {quant_path}")


def export_qwen_onnx(
    model_id: str,
    output_dir: str,
    quantization: Optional[str] = None,
    opset: int = 14
):
    """
    Export Qwen model to ONNX format with optional quantization
    
    Args:
        model_id: Path to the model
        output_dir: Output directory for ONNX model
        quantization: Quantization type - 'int8', 'int4', or None
        opset: ONNX opset version
    """
    
    output_dir = output_dir.strip()

    print(f"Exporting model to ONNX format...")
    print(f"Model ID: {model_id}")
    print(f"Output directory: {output_dir}")
    print(f"Quantization: {quantization if quantization else 'None'}")
    print(f"Opset version: {opset}")

    config = AutoConfig.from_pretrained(model_id, trust_remote_code=True)
    custom_onnx_config = QwenBaseOnnxConfig(config)

    if quantization == "int4":
        # Quantize to a temporary directory first
        quant_tmp_dir = f"{output_dir}_awq_tmp"
        apply_int4_quantization(model_id, quant_tmp_dir)
        model_to_export = quant_tmp_dir
        
        # Export the quantized model to the final output directory
        main_export(
            model_to_export,
            output=output_dir,
            task="feature-extraction",
            custom_onnx_configs={"model": custom_onnx_config},
            trust_remote_code=True,
            opset=opset
        )
        
        # Clean up temporary directory
        import shutil
        if os.path.exists(quant_tmp_dir):
            shutil.rmtree(quant_tmp_dir)
            print(f"Cleaned up temporary directory: {quant_tmp_dir}")

    elif quantization == "int8":
        # Export FP32 model to a temporary directory first
        fp32_tmp_dir = f"{output_dir}_fp32_tmp"
        main_export(
            model_id,
            output=fp32_tmp_dir,
            task="feature-extraction",
            custom_onnx_configs={"model": custom_onnx_config},
            trust_remote_code=True,
            opset=opset
        )
        
        # Apply INT8 quantization to the final output directory
        model_onnx_path = os.path.join(fp32_tmp_dir, "model.onnx")
        os.makedirs(output_dir, exist_ok=True)
        quantized_model_path = os.path.join(output_dir, "model.onnx")
        apply_int8_quantization(model_onnx_path, quantized_model_path)
        
        # Copy other files
        for file in ["config.json", "tokenizer.json", "tokenizer_config.json"]:
            src_path = os.path.join(fp32_tmp_dir, file)
            dst_path = os.path.join(output_dir, file)
            if os.path.exists(src_path):
                import shutil
                shutil.copy2(src_path, dst_path)
        
        # Clean up temporary directory
        import shutil
        if os.path.exists(fp32_tmp_dir):
            shutil.rmtree(fp32_tmp_dir)
            print(f"Cleaned up temporary directory: {fp32_tmp_dir}")

    else: # No quantization
        main_export(
            model_id,
            output=output_dir,
            task="feature-extraction",
            custom_onnx_configs={"model": custom_onnx_config},
            trust_remote_code=True,
            opset=opset
        )

    print(f"Model successfully exported to: {output_dir}")


def main():
    parser = argparse.ArgumentParser(description="Export Qwen model to ONNX with optional quantization")
    parser.add_argument("--model_id", type=str, 
                       default="./model",
                       help="Path to the model")
    parser.add_argument("--output", type=str,
                       default="./model-onnx",
                       help="Output directory for ONNX model")
    parser.add_argument("--quantization", type=str, choices=["int8", "int4"],
                       help="Quantization type: int8, int4 (default: no quantization)")
    parser.add_argument("--opset", type=int, default=14,
                       help="ONNX opset version (default: 14)")
    
    args = parser.parse_args()
    
    export_qwen_onnx(
        model_id=args.model_id,
        output_dir=args.output,
        quantization=args.quantization,
        opset=args.opset
    )

if __name__ == "__main__":
    main()
