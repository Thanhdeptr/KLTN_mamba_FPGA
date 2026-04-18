#!/usr/bin/env python3
"""
Extract Full ITMN Golden Data from PyTorch Model
=================================================

Purpose:
  - Load pre-trained ITMN checkpoint
  - Pass 1 sample through forward() with hooks
  - Extract intermediate layer outputs  
  - Export weights (A, B, C, D from Mamba, Inception kernels, RMSNorm scales)
  - Save as .bin and .npy for RTL testing

Structure:
  Input → Encoder → ITMBlock 1,2,3 → Classifier → Output
  Each ITMBlock: Conv1D → Inception (4 kernels) + Mamba (RMSNorm+SSM) → Add → ReLU

Output Directory: /ITMN/golden_vectors_full_itmn_1_1/
  ├── intermediates/
  │   ├── 00_input_waveform.npy            (1, 12, 1000)
  │   ├── 01_after_encoder.npy              (1, 64, 1000)
  │   ├── 02_after_itmblock_1.npy           (1, 64, 1000)
  │   ├── 03_after_itmblock_2.npy           (1, 64, 500)  [after maxpool]
  │   ├── 04_after_itmblock_3.npy           (1, 128, 250)
  │   ├── 05_final_logits.npy               (1, 5)
  │   └── ...
  ├── layers/
  │   ├── encoder_conv_weight.npy           (64, 12, 1)
  │   ├── encoder_bn_weight.npy             (64,)
  │   ├── encoder_bn_bias.npy               (64,)
  │   ├── itmblock_1_conv_weight.npy        (64, 64, 1)
  │   ├── itmblock_1_inception_...
  │   ├── itmblock_1_mamba_rmsn_scale.npy   (64,)
  │   └── ...
  ├── mamba_internals/
  │   ├── mamba_A.npy                        (64, 16) or full state matrix
  │   ├── mamba_B.npy
  │   ├── mamba_C.npy
  │   ├── mamba_D.npy
  │   └── ...
  └── README.txt (metadata)
"""

import sys
import os
import argparse
import numpy as np
import torch
import torch.nn as nn
from pathlib import Path

# Add ITMN to path
sys.path.insert(0, '/home/hatthanh/schoolwork/KLTN/ITMN')

from ecg_models.ITMN import ITMN, RMSNorm, MambaBlock, BaseInceptionBlock, ITMBlock
from dataset import get_loaders
from utils.utils import get_config


class GoldenHook:
    """Hook to capture intermediate activations"""
    def __init__(self):
        self.activations = {}
    
    def register(self, module, name):
        def hook_fn(module, input, output):
            self.activations[name] = output.detach().cpu().numpy() if isinstance(output, torch.Tensor) else output
        module.register_forward_hook(hook_fn)


def extract_weights_from_model(model, out_dir):
    """
    Extract all weights and parameters from model
    """
    weights_dir = os.path.join(out_dir, 'layers')
    os.makedirs(weights_dir, exist_ok=True)
    
    for name, param in model.named_parameters():
        if param.dim() > 0:  # skip biases if you want, or include all
            param_np = param.detach().cpu().numpy()
            # Clean name for file
            clean_name = name.replace('.', '_').replace('[', '').replace(']', '')
            filepath = os.path.join(weights_dir, f'{clean_name}.npy')
            np.save(filepath, param_np)
            print(f"  Saved: {name} -> shape {param_np.shape}")


def extract_mamba_state_matrices(model, out_dir):
    """
    Extract Mamba state-space matrices if accessible
    Mamba uses: dt, A, B, C, D
    """
    mamba_dir = os.path.join(out_dir, 'mamba_internals')
    os.makedirs(mamba_dir, exist_ok=True)
    
    # Try to access Mamba internals
    # This depends on mamba_ssm version and how it's exported
    print("  Note: Mamba state matrices extraction depends on mamba_ssm internals")
    print("        Manual export may be needed from checkpoint")


def extract_golden_forward_pass(model, sample_input, device, out_dir):
    """
    Pass sample through model with hooks to capture intermediate outputs
    """
    intermediates_dir = os.path.join(out_dir, 'intermediates')
    os.makedirs(intermediates_dir, exist_ok=True)
    
    hook = GoldenHook()
    
    # Register hooks on key layers
    step_num = 0
    
    # Hook encoder
    def encoder_hook(module, input, output):
        nonlocal step_num
        out_np = output.detach().cpu().numpy()
        np.save(os.path.join(intermediates_dir, f'{step_num:02d}_after_encoder.npy'), out_np)
        print(f"  {step_num:02d} after_encoder: {out_np.shape}")
        step_num += 1
    
    model.encoder.register_forward_hook(encoder_hook)
    
    # Hook each ITMBlock
    block_names = ['ITMBlock_0', 'ITMBlock_1', 'ITMBlock_2', 'ITMBlock_3', 'ITMBlock_4', 'ITMBlock_5', 'ITMBlock_6']
    for i, layer in enumerate(model.layers):
        if isinstance(layer, ITMBlock):
            def block_hook(module, input, output, block_idx=i):
                nonlocal step_num
                out_np = output.detach().cpu().numpy()
                np.save(os.path.join(intermediates_dir, f'{step_num:02d}_after_itmblock_{block_idx}.npy'), out_np)
                print(f"  {step_num:02d} after_itmblock_{block_idx}: {out_np.shape}")
                step_num += 1
            
            layer.register_forward_hook(block_hook)
    
    # Save input
    input_np = sample_input.detach().cpu().numpy()
    np.save(os.path.join(intermediates_dir, f'00_input_waveform.npy'), input_np)
    print(f"  Saved input: {input_np.shape}")
    
    # Forward pass
    model.eval()
    with torch.no_grad():
        output = model(sample_input)
    
    # Save final output
    output_np = output.detach().cpu().numpy()
    np.save(os.path.join(intermediates_dir, f'{step_num:02d}_final_logits.npy'), output_np)
    print(f"  {step_num:02d} final_logits: {output_np.shape}")
    
    return output_np


def main():
    parser = argparse.ArgumentParser(description='Extract Full ITMN Golden Data')
    parser.add_argument('--exp_type', type=str, default='super', 
                       help='Experiment type (super/sub/rhythm/all/diag/form/cpsc)')
    parser.add_argument('--ckpt_path', type=str, default='/home/hatthanh/schoolwork/KLTN/pre-train/PTB-XL_SUPER_ITMN_DB.pth',
                       help='Path to checkpoint')
    parser.add_argument('--output_dir', type=str, default='/home/hatthanh/schoolwork/KLTN/ITMN/golden_vectors_full_itmn_1_1',
                       help='Output directory for golden data')
    parser.add_argument('--device', type=str, default='cuda', help='Device (cuda/cpu)')
    
    args = parser.parse_args()
    
    # Setup device
    if args.device == 'cuda' and torch.cuda.is_available():
        device = torch.device('cuda')
        print(f"Using GPU: {torch.cuda.get_device_name(device)}")
    else:
        device = torch.device('cpu')
        print("Using CPU")
    
    # Create output directory
    os.makedirs(args.output_dir, exist_ok=True)
    print(f"\n✓ Output directory: {args.output_dir}\n")
    
    # Load config
    config = get_config('/home/hatthanh/schoolwork/KLTN/ITMN/config.yaml')
    config['exp_type'] = args.exp_type.lower()
    
    model_config = config['model']
    print(f"Model config: {model_config}")
    
    # Create model
    print("\n[1] Creating ITMN model...")
    model = ITMN(n_classes=5, **model_config).to(device)
    print(f"  Model params: {sum(p.numel() for p in model.parameters() if p.requires_grad):,}")
    
    # Load checkpoint
    print(f"\n[2] Loading checkpoint: {args.ckpt_path}")
    if not os.path.exists(args.ckpt_path):
        print(f"  ERROR: Checkpoint not found!")
        return
    
    checkpoint = torch.load(args.ckpt_path, map_location=device)
    model.load_state_dict(checkpoint['model_state_dict'])
    model.eval()
    print("  ✓ Checkpoint loaded")
    
    # Create dummy input (1, 12, 1000)
    print(f"\n[3] Creating dummy input sample (1, 12, 1000)")
    sample_input = torch.randn(1, 12, 1000).to(device)
    
    # Extract weights
    print(f"\n[4] Extracting all model weights...")
    extract_weights_from_model(model, args.output_dir)
    
    # Extract Mamba internals
    print(f"\n[5] Extracting Mamba state matrices...")
    extract_mamba_state_matrices(model, args.output_dir)
    
    # Forward pass with hooks
    print(f"\n[6] Forward pass with intermediate capture...")
    output = extract_golden_forward_pass(model, sample_input, device, args.output_dir)
    
    # Save metadata
    metadata_path = os.path.join(args.output_dir, 'README.txt')
    with open(metadata_path, 'w') as f:
        f.write("ITMN Full 1:1 Golden Data Export\n")
        f.write("=" * 60 + "\n")
        f.write(f"Exp Type: {args.exp_type}\n")
        f.write(f"Model: ITMN(d_model={model_config.get('d_model', 64)}, n_classes=5)\n")
        f.write(f"Checkpoint: {args.ckpt_path}\n")
        f.write(f"Generated: {np.datetime64('now')}\n")
        f.write("\nDirectory Structure:\n")
        f.write("  intermediates/  - Layer outputs (input, encoder, itmblock_1..3, final_logit)\n")
        f.write("  layers/         - All model weights and biases\n")
        f.write("  mamba_internals/- Mamba SSM state matrices (if exported)\n")
        f.write("\nNext Steps for RTL:\n")
        f.write("  1. Convert .npy files to .mem (Verilog memory format)\n")
        f.write("  2. Create testbenches for each module\n")
        f.write("  3. Compare RTL output vs PyTorch golden\n")
    
    print(f"\n[7] Metadata saved: {metadata_path}")
    print(f"\n✅ Golden data extraction complete!")
    print(f"   Output: {args.output_dir}")
    print(f"   Total output: {output.shape}")


if __name__ == '__main__':
    main()
