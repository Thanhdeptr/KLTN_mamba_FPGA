import os
import argparse
import numpy as np
import torch
import torch.nn.functional as F

from dataset import get_loaders
from ecg_models.ITMN import ITMN
from utils.utils import get_config


DEBUG_DIR = "silu_golden"


def save_tensor(t: torch.Tensor, name: str):
    """
    Lưu tensor ra txt: nếu B=1 thì bỏ batch, nếu >2D thì gộp về (N, D).
    """
    os.makedirs(DEBUG_DIR, exist_ok=True)
    path = os.path.join(DEBUG_DIR, name)

    arr = t.detach().cpu().numpy()
    if arr.shape[0] == 1:
        arr = arr[0]
    if arr.ndim > 2:
        arr = arr.reshape(-1, arr.shape[-1])

    np.savetxt(path, arr, fmt="%.8e")
    print(f"Saved {name} with shape {t.shape} -> {arr.shape}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exp_type", type=str, default="super")
    args = parser.parse_args()

    # 1) Load config / data / model (giống test.py, extract_single_sample.py)
    config = get_config("config.yaml")
    config["exp_type"] = args.exp_type.lower()
    model_cfg = config["model"]
    ckpt_path = config["test_ckpt_path"]

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Using device: {device}")

    _, _, test_loader, num_class, _ = get_loaders(
        config["data"], args.exp_type, batch_size=1
    )

    sample = next(iter(test_loader))
    waveform = sample["waveform"][0:1].to(device, dtype=torch.float)

    model = ITMN(n_classes=num_class, **model_cfg).to(device)
    checkpoint = torch.load(ckpt_path, map_location=device)
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()
    print(f"Loaded checkpoint: {ckpt_path}")

    # 2) Lấy các module con giống extract_single_sample.py
    encoder = model.encoder
    itm_block_0 = model.layers[0]
    mamba_block = itm_block_0.mamba_block
    mixer = mamba_block.mixer

    with torch.no_grad():
        # ITMN: encoder
        x = waveform.transpose(-1, -2)
        x = encoder(x)  # (B, d_model, L)

        # ITMBlock: conv → input cho MambaBlock
        x_conv_itm = itm_block_0.conv(x)           # (B, out_ch, L)
        x_in = x_conv_itm.transpose(-1, -2)        # (B, L, D)

        # RMSNorm trong MambaBlock
        x_norm = mamba_block.norm(x_in)            # (B, L, D)

        # in_proj: tách x / z
        xz = mixer.in_proj(x_norm)                 # (B, L, 2*D_inner)
        x_mixer, z_mixer = xz.chunk(2, dim=-1)     # (B, L, D_inner)

        # ===== SiLU #1: nhánh conv (x-branch) =====
        x_mixer_t = x_mixer.transpose(1, 2)        # (B, D_inner, L)
        x_conv = mixer.conv1d(x_mixer_t)           # (B, D_inner, L + pad)
        seq_len = x_mixer_t.shape[-1]
        x_conv_sliced = x_conv[..., :seq_len]      # (B, D_inner, L)
        x_activated = F.silu(x_conv_sliced)        # SiLU(x_conv_sliced)

        save_tensor(x_conv_sliced, "silu1_x_input_conv_branch.txt")
        save_tensor(x_activated,   "silu1_y_output_conv_branch.txt")

        # ===== SiLU #2: gate (z-branch) =====
        z_gate_in = z_mixer.transpose(1, 2)        # (B, D_inner, L)
        z_gate_out = F.silu(z_gate_in)             # SiLU(z_gate_in)

        save_tensor(z_gate_in,   "silu2_x_input_gate_branch.txt")
        save_tensor(z_gate_out,  "silu2_y_output_gate_branch.txt")

    print(f"\nDone. Golden SiLU I/O saved in: {DEBUG_DIR}")


if __name__ == "__main__":
    main()
