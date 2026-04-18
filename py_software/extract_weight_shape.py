import torch
import numpy as np
import os
import argparse
from pathlib import Path
import sys

KLTN_ROOT = Path(__file__).resolve().parents[1]
ITMN_ROOT = KLTN_ROOT / "ITMN"
sys.path.insert(0, str(ITMN_ROOT))

from ecg_models.ITMN import ITMN
from dataset import get_loaders
from utils.utils import get_config

# --- CAU HINH ---
OUTPUT_DIR = ITMN_ROOT / "golden_vectors"
TARGET_LAYER_NAME = 'layers.0.mamba_block'


def save_and_report(arr, filename):
    """Luu file .bin va in shape + dtype"""
    path = OUTPUT_DIR / filename
    arr = arr.astype(np.float32)
    arr.tofile(path)
    print(f"   - Saved {filename:25s} | shape={arr.shape} | dtype={arr.dtype}")


def register_io_hook(module, captured, key):
    def _hook(_, inp, out):
        if inp and isinstance(inp[0], torch.Tensor):
            captured[f"{key}_input"] = inp[0].detach().cpu().numpy()
        if isinstance(out, torch.Tensor):
            captured[f"{key}_output"] = out.detach().cpu().numpy()
    return module.register_forward_hook(_hook)


def load_sample_input(params, exp_type: str, input_source: str, device: torch.device) -> torch.Tensor:
    if input_source == "dataset":
        _, _, test_loader, _, _ = get_loaders(params['data'], exp_type, batch_size=1)
        real_sample = next(iter(test_loader))
        real_waveform = real_sample['waveform']
        if real_waveform.ndim != 3:
            raise ValueError(f"Unexpected waveform shape from dataset: {real_waveform.shape}")
        return real_waveform.to(device)

    if input_source == "cpp":
        cpp_path = ITMN_ROOT / "cpp_golden_files" / "00_00_ITMN_input_waveform.txt"
        if not cpp_path.exists():
            raise FileNotFoundError(f"Missing cpp golden input: {cpp_path}")
        arr = np.loadtxt(cpp_path, dtype=np.float32)
        flat = arr.reshape(-1)
        if flat.size != 12000:
            raise ValueError(f"Expected 12000 values in cpp input, got {flat.size}")
        waveform = torch.from_numpy(flat.reshape(1, 1000, 12))
        return waveform.to(device)

    # random fallback
    return torch.randn(1, 1000, 12, device=device)


def extract(params, ckpt_path, input_source: str):
    print("\n=== SETUP MODEL & DATA ===")
    model_config = params['model']
    exp_type = params['exp_type']
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"Device: {device}")

    # Num class is derived from exp config to avoid forcing dataset availability
    exp_key = exp_type.upper()
    num_class = {
        "SUPER": 5,
        "SUB": 23,
        "RHYTHM": 12,
        "ALL": 71,
        "DIAG": 44,
        "FORM": 19,
        "CPSC": 9,
    }[exp_key]

    real_waveform = load_sample_input(params, exp_type, input_source, device)
    print(f"Input waveform shape: {real_waveform.shape}")

    model = ITMN(n_classes=num_class, **model_config).to(device)
    checkpoint = torch.load(ckpt_path, map_location=device)
    model.load_state_dict(checkpoint['model_state_dict'])
    model.eval()
    print(f"Checkpoint loaded: {ckpt_path}")

    # --- HOOK ---
    captured_io = {}

    target_module = dict(model.named_modules()).get(TARGET_LAYER_NAME)
    if target_module is None:
        raise ValueError(f"Layer not found: {TARGET_LAYER_NAME}")

    hooks = []
    hooks.append(register_io_hook(target_module, captured_io, TARGET_LAYER_NAME))

    # Module-level hooks for new blocks
    itm0 = model.layers[0]
    hooks.append(register_io_hook(itm0.inception_block, captured_io, "layers.0.inception_block"))
    hooks.append(register_io_hook(itm0.mamba_block.norm, captured_io, "layers.0.mamba_block.norm"))
    hooks.append(register_io_hook(itm0.mamba_block.mixer.in_proj, captured_io, "layers.0.mamba_block.mixer.in_proj"))
    hooks.append(register_io_hook(itm0.mamba_block.mixer.out_proj, captured_io, "layers.0.mamba_block.mixer.out_proj"))
    print(f"Hook registered on: {TARGET_LAYER_NAME}")

    # --- FORWARD ---
    with torch.no_grad():
        model(real_waveform.to(device))

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("\n=== SAVE GOLDEN INPUT / OUTPUT ===")
    save_and_report(captured_io[TARGET_LAYER_NAME + "_input"][0], "golden_input.bin")
    save_and_report(captured_io[TARGET_LAYER_NAME + "_output"][0], "golden_output.bin")

    print("\n=== SAVE LAYER WEIGHTS ===")
    with torch.no_grad():
        # RMSNorm
        save_and_report(
            target_module.norm.weight.cpu().numpy(),
            "rms_norm_weight.bin"
        )

        mixer = target_module.mixer

        # in_proj (split)
        in_proj1, in_proj2 = np.split(
            mixer.in_proj.weight.cpu().numpy(), 2, axis=0
        )
        save_and_report(in_proj1, "in_proj1_weight.bin")
        save_and_report(in_proj2, "in_proj2_weight.bin")

        # conv1d
        save_and_report(mixer.conv1d.weight.cpu().numpy(), "conv1d_weight.bin")
        save_and_report(mixer.conv1d.bias.cpu().numpy(), "conv1d_bias.bin")

        # x_proj
        save_and_report(mixer.x_proj.weight.cpu().numpy(), "x_proj_weight.bin")

        # dt_proj
        save_and_report(mixer.dt_proj.weight.cpu().numpy(), "dt_proj_weight.bin")
        save_and_report(mixer.dt_proj.bias.cpu().numpy(), "dt_proj_bias.bin")

        # A_log, D
        save_and_report(mixer.A_log.cpu().numpy(), "A_log.bin")
        save_and_report(mixer.D.cpu().numpy(), "D.bin")

        # out_proj
        save_and_report(mixer.out_proj.weight.cpu().numpy(), "out_proj_weight.bin")

        # Inception block weights (ITM block 0)
        inception = itm0.inception_block
        save_and_report(inception.bottleneck.weight.cpu().numpy(), "inception_bottleneck_weight.bin")
        save_and_report(inception.conv1.weight.cpu().numpy(), "inception_conv1_k1_weight.bin")
        save_and_report(inception.conv2.weight.cpu().numpy(), "inception_conv2_k9_weight.bin")
        save_and_report(inception.conv3.weight.cpu().numpy(), "inception_conv3_k19_weight.bin")
        save_and_report(inception.conv4.weight.cpu().numpy(), "inception_conv4_k39_weight.bin")
        save_and_report(inception.bn.weight.cpu().numpy(), "inception_bn_weight.bin")
        save_and_report(inception.bn.bias.cpu().numpy(), "inception_bn_bias.bin")
        save_and_report(inception.bn.running_mean.cpu().numpy(), "inception_bn_running_mean.bin")
        save_and_report(inception.bn.running_var.cpu().numpy(), "inception_bn_running_var.bin")

    print("\n=== SAVE MODULE I/O GOLDEN ===")
    module_pairs = [
        ("layers.0.mamba_block.norm", "rmsnorm"),
        ("layers.0.mamba_block.mixer.in_proj", "in_proj"),
        ("layers.0.mamba_block.mixer.out_proj", "out_proj"),
        ("layers.0.inception_block", "inception"),
        (TARGET_LAYER_NAME, "mamba_block"),
    ]
    for key, prefix in module_pairs:
        in_key = f"{key}_input"
        out_key = f"{key}_output"
        if in_key in captured_io:
            save_and_report(captured_io[in_key][0], f"{prefix}_golden_input.bin")
        if out_key in captured_io:
            save_and_report(captured_io[out_key][0], f"{prefix}_golden_output.bin")

    for h in hooks:
        h.remove()

    print(f"\nDONE. Tat ca file da duoc luu trong '{OUTPUT_DIR}'\n")


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--exp_type', type=str, default='super')
    parser.add_argument('--input_source', type=str, default='cpp', choices=['cpp', 'dataset', 'random'])
    args = parser.parse_args()

    config = get_config(str(ITMN_ROOT / 'config.yaml'))
    config['exp_type'] = args.exp_type.lower()

    extract(config, config['test_ckpt_path'], args.input_source)
