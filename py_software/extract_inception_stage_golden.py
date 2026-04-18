#!/usr/bin/env python3
"""Export Inception stage activations and weights from PyTorch.

This script extracts the tensors needed to debug the first Inception branch
of ITMN/ITMBlock at stage level:
- encoder output
- ITMBlock conv output, which is the Inception input
- Bottleneck, pooling, branch outputs, concat, BN, and ReLU outputs
- All weights and BN statistics needed to reproduce the stage

All artifacts are written as float32 .bin files so they can be converted to
RTL-friendly Q3.12 .mem files with gen_rtl_mem_from_bin.py.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ITMN"))

from dataset import get_loaders
from ecg_models.ITMN import ITMN, ITMBlock
from utils.utils import get_config


def save_f32_bin(tensor: torch.Tensor, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    array = tensor.detach().cpu().numpy().astype(np.float32, copy=False)
    array.tofile(path)


def export_param(module: torch.nn.Module, attr: str, out_dir: Path, name: str) -> None:
    value = getattr(module, attr)
    if isinstance(value, torch.Tensor):
        save_f32_bin(value, out_dir / f"{name}.bin")


def export_module_weights(model: ITMN, out_dir: Path) -> None:
    encoder = model.encoder
    itm_block = model.layers[0]
    if not isinstance(itm_block, ITMBlock):
        raise TypeError("model.layers[0] is not an ITMBlock")

    inception = itm_block.inception_block

    export_param(encoder[0], "weight", out_dir, "encoder_conv_weight")
    export_param(encoder[1], "weight", out_dir, "encoder_bn_weight")
    export_param(encoder[1], "bias", out_dir, "encoder_bn_bias")
    export_param(encoder[1], "running_mean", out_dir, "encoder_bn_running_mean")
    export_param(encoder[1], "running_var", out_dir, "encoder_bn_running_var")

    export_param(itm_block.conv[0], "weight", out_dir, "itmblock_conv_weight")
    export_param(itm_block.conv[1], "weight", out_dir, "itmblock_conv_bn_weight")
    export_param(itm_block.conv[1], "bias", out_dir, "itmblock_conv_bn_bias")
    export_param(itm_block.conv[1], "running_mean", out_dir, "itmblock_conv_bn_running_mean")
    export_param(itm_block.conv[1], "running_var", out_dir, "itmblock_conv_bn_running_var")

    export_param(inception.bottleneck, "weight", out_dir, "inception_bottleneck_weight")
    export_param(inception.conv1, "weight", out_dir, "inception_conv1_k1_weight")
    export_param(inception.conv2, "weight", out_dir, "inception_conv2_k9_weight")
    export_param(inception.conv3, "weight", out_dir, "inception_conv3_k19_weight")
    export_param(inception.conv4, "weight", out_dir, "inception_conv4_k39_weight")

    export_param(inception.bn, "weight", out_dir, "inception_bn_weight")
    export_param(inception.bn, "bias", out_dir, "inception_bn_bias")
    export_param(inception.bn, "running_mean", out_dir, "inception_bn_running_mean")
    export_param(inception.bn, "running_var", out_dir, "inception_bn_running_var")


def run_forward(sample_waveform: torch.Tensor, model: ITMN) -> dict[str, torch.Tensor]:
    encoder = model.encoder
    itm_block = model.layers[0]
    if not isinstance(itm_block, ITMBlock):
        raise TypeError("model.layers[0] is not an ITMBlock")

    inception = itm_block.inception_block

    artifacts: dict[str, torch.Tensor] = {}
    x = sample_waveform.transpose(-1, -2)
    artifacts["00_waveform"] = sample_waveform
    artifacts["01_encoder_input"] = x

    x = encoder(x)
    artifacts["02_after_encoder"] = x

    x = itm_block.conv(x)
    artifacts["03_itmblock_conv_out"] = x
    artifacts["04_inception_input"] = x

    bottleneck = inception.bottleneck(x)
    artifacts["05_bottleneck_out"] = bottleneck

    conv4 = inception.conv4(bottleneck)
    conv3 = inception.conv3(bottleneck)
    conv2 = inception.conv2(bottleneck)
    pool = inception.maxpool(x)
    conv1 = inception.conv1(pool)

    artifacts["06_conv1_out"] = conv1
    artifacts["07_conv2_out"] = conv2
    artifacts["08_conv3_out"] = conv3
    artifacts["09_conv4_out"] = conv4

    concat = torch.cat((conv1, conv2, conv3, conv4), dim=1)
    artifacts["10_concat_prebn"] = concat

    bn_out = inception.bn(concat)
    artifacts["11_bn_out"] = bn_out

    relu_out = inception.relu(bn_out)
    artifacts["12_relu_out"] = relu_out

    return artifacts


def main() -> int:
    parser = argparse.ArgumentParser(description="Export Inception stage goldens from PyTorch")
    parser.add_argument("--exp_type", type=str, default="super", help="Experiment type")
    parser.add_argument(
        "--ckpt_path",
        type=str,
        default="/home/hatthanh/schoolwork/KLTN/pre-train/PTB-XL_SUPER_ITMN_DB.pth",
        help="Path to checkpoint",
    )
    parser.add_argument(
        "--output_dir",
        type=str,
        default="/home/hatthanh/schoolwork/KLTN/ITMN/golden_vectors/inception_stage",
        help="Output directory for stage tensors and weights",
    )
    parser.add_argument("--device", type=str, default="cuda", help="Device (cuda/cpu)")
    parser.add_argument("--sample_index", type=int, default=0, help="Sample index from the test loader")
    args = parser.parse_args()

    if args.device == "cuda" and torch.cuda.is_available():
        device = torch.device("cuda")
    else:
        device = torch.device("cpu")

    config = get_config(str(ROOT / "ITMN" / "config.yaml"))
    config["exp_type"] = args.exp_type.lower()

    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = ROOT / output_dir

    os.chdir(ROOT / "ITMN")
    _, _, test_loader, num_class, _ = get_loaders(config["data"], args.exp_type, 1)
    model = ITMN(n_classes=num_class, **config["model"]).to(device)

    checkpoint = torch.load(args.ckpt_path, map_location=device)
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()

    sample_waveform = None
    for idx, sample in enumerate(test_loader):
        if idx == args.sample_index:
            sample_waveform = sample["waveform"][0:1].to(device, dtype=torch.float32)
            break

    if sample_waveform is None:
        raise IndexError(f"sample_index {args.sample_index} is out of range")

    output_dir.mkdir(parents=True, exist_ok=True)

    export_module_weights(model, output_dir / "weights")

    with torch.no_grad():
        artifacts = run_forward(sample_waveform, model)

    tensors_dir = output_dir / "tensors"
    for name, tensor in artifacts.items():
        save_f32_bin(tensor, tensors_dir / f"{name}.bin")

    print(f"[INFO] Exported Inception stage tensors and weights to {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())