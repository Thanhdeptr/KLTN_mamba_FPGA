#!/usr/bin/env python3
"""
Cross-validate golden extraction: extract_single_sample vs ITMN forward vs mamba_ssm.

Outputs:
  reports/golden_validation/<timestamp>/
    summary.md, results.csv, validation_manifest.txt
    figures/*.png
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import torch
import torch.nn.functional as F

KLTN_ROOT = Path(__file__).resolve().parents[2]
ITMN_ROOT = KLTN_ROOT / "ITMN"
CPP_DIR = ITMN_ROOT / "cpp_golden_files"
GV_DIR = ITMN_ROOT / "golden_vectors"
REPORT_ROOT = KLTN_ROOT / "reports" / "golden_validation"

sys.path.insert(0, str(ITMN_ROOT))

from dataset import get_loaders  # noqa: E402
from ecg_models.ITMN import ITMN  # noqa: E402
from utils.utils import get_config  # noqa: E402


@dataclass
class CompareResult:
    layer_id: str
    name: str
    max_err: float
    mean_err: float
    p99_err: float
    atol: float
    passed: bool
    note: str = ""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def to_numpy(t: torch.Tensor) -> np.ndarray:
    return t.detach().float().cpu().numpy()


def flatten_pair(a: np.ndarray, b: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    a = np.asarray(a, dtype=np.float32).reshape(-1)
    b = np.asarray(b, dtype=np.float32).reshape(-1)
    n = min(a.size, b.size)
    return a[:n], b[:n]


def compare_arrays(layer_id: str, name: str, ref: np.ndarray, ext: np.ndarray,
                   atol: float, note: str = "") -> CompareResult:
    a, b = flatten_pair(ref, ext)
    if a.size == 0:
        return CompareResult(layer_id, name, float("nan"), float("nan"), float("nan"),
                             atol, False, note or "empty tensor")
    err = np.abs(a - b)
    passed = bool(err.max() <= atol)
    return CompareResult(layer_id, name, float(err.max()), float(err.mean()),
                         float(np.percentile(err, 99)), atol, passed, note)


def find_cpp_txt(pattern: str) -> Optional[Path]:
    matches = sorted(CPP_DIR.glob(f"*{pattern}*.txt"))
    return matches[0] if matches else None


def load_cpp_txt(pattern: str) -> Optional[np.ndarray]:
    path = find_cpp_txt(pattern)
    if path is None:
        return None
    return np.loadtxt(path, dtype=np.float32)


def plot_overlay(ref: np.ndarray, ext: np.ndarray, title: str, out_path: Path,
                 xlabel: str = "index") -> None:
    a_full, b_full = flatten_pair(ref, ext)
    err_full = np.abs(a_full - b_full)
    max_err = float(err_full.max()) if err_full.size else float("nan")
    mean_err = float(err_full.mean()) if err_full.size else float("nan")
    p99_err = float(np.percentile(err_full, 99)) if err_full.size else float("nan")

    n_plot = min(a_full.size, 2000)
    a, b = a_full[:n_plot], b_full[:n_plot]

    fig, ax = plt.subplots(figsize=(10, 4))
    ax.plot(a, label="oracle (reference)", linewidth=1.0)
    ax.plot(b, "--", label="golden (manual)", linewidth=1.0, alpha=0.85)
    ax.set_ylabel("value")
    ax.set_xlabel(xlabel)
    ax.set_title(title)
    ax.legend(loc="upper right")
    ax.grid(True, alpha=0.3)
    stats = (
        f"max |error| = {max_err:.3e}\n"
        f"mean |error| = {mean_err:.3e}\n"
        f"p99 |error| = {p99_err:.3e}\n"
        f"n = {a_full.size} (plot: first {n_plot})"
    )
    ax.text(
        0.02, 0.98, stats, transform=ax.transAxes, fontsize=9,
        verticalalignment="top", bbox=dict(boxstyle="round", facecolor="wheat", alpha=0.85),
    )
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def plot_scatter(ref: np.ndarray, ext: np.ndarray, title: str, out_path: Path) -> None:
    a, b = flatten_pair(ref, ext)
    if a.size > 5000:
        idx = np.random.default_rng(0).choice(a.size, 5000, replace=False)
        a, b = a[idx], b[idx]

    fig, ax = plt.subplots(figsize=(6, 6))
    ax.scatter(a, b, s=6, alpha=0.35)
    lo = float(min(a.min(), b.min()))
    hi = float(max(a.max(), b.max()))
    ax.plot([lo, hi], [lo, hi], "r--", linewidth=1.2, label="y = x")
    ax.set_xlabel("reference")
    ax.set_ylabel("compare")
    ax.set_title(title)
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def plot_error_heatmap(ref: np.ndarray, ext: np.ndarray, title: str, out_path: Path,
                       shape: Tuple[int, int]) -> None:
    a = np.asarray(ref, dtype=np.float32).reshape(shape)
    b = np.asarray(ext, dtype=np.float32).reshape(shape)
    err = np.abs(a - b)
    fig, ax = plt.subplots(figsize=(12, 4))
    im = ax.imshow(err, aspect="auto", origin="lower", cmap="hot")
    fig.colorbar(im, ax=ax, label="|error|")
    ax.set_xlabel("timestep")
    ax.set_ylabel("channel")
    ax.set_title(title)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def plot_summary_bar(results: List[CompareResult], out_path: Path) -> None:
    names = [r.layer_id for r in results]
    vals = [r.max_err if np.isfinite(r.max_err) else 0.0 for r in results]
    colors = ["seagreen" if r.passed else "crimson" for r in results]

    fig, ax = plt.subplots(figsize=(12, 4))
    ax.bar(names, vals, color=colors)
    ax.set_yscale("log")
    ax.set_ylabel("max |error|")
    ax.set_title("Phase summary (log scale)")
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def build_mamba_block_input(model: ITMN, waveform: torch.Tensor) -> torch.Tensor:
    itm0 = model.layers[0]
    with torch.no_grad():
        x = waveform.transpose(-1, -2)
        x = model.encoder(x)
        x = itm0.conv(x)
        return x.transpose(-1, -2)


def run_extract_tensors(model: ITMN, waveform: torch.Tensor) -> Dict[str, np.ndarray]:
    """Replicate py_software/extract_single_sample.py mixer path."""
    device = waveform.device
    itm0 = model.layers[0]
    mamba_block = itm0.mamba_block
    mixer = mamba_block.mixer
    seq_len = waveform.shape[1]

    with torch.no_grad():
        mamba_block_input = build_mamba_block_input(model, waveform)
        x_norm = mamba_block.norm(mamba_block_input)

        xz = mixer.in_proj(x_norm)
        x_mixer, z_mixer = xz.chunk(2, dim=-1)

        x_mixer_t = x_mixer.transpose(1, 2)
        x_conv = mixer.conv1d(x_mixer_t)[..., :seq_len]
        x_activated = F.silu(x_conv)

        x_act_rearranged = x_activated.transpose(1, 2)
        x_dbl = mixer.x_proj(x_act_rearranged)
        dt_raw, b_raw, c_raw = torch.split(
            x_dbl, [mixer.dt_rank, mixer.d_state, mixer.d_state], dim=-1
        )

        delta_proj = mixer.dt_proj(dt_raw)
        delta_before_softplus = delta_proj.transpose(1, 2)
        delta = F.softplus(delta_proj).transpose(1, 2)

        a = -torch.exp(mixer.A_log.float())
        discrete_a = torch.exp(a.unsqueeze(0).unsqueeze(2) * delta.unsqueeze(3))
        discrete_b = delta.unsqueeze(3) * b_raw.unsqueeze(1)
        delta_b_u = discrete_b * x_activated.unsqueeze(3)

        ssm_state = torch.zeros(
            x_activated.shape[0], mixer.d_inner, mixer.d_state,
            device=device, dtype=torch.float32,
        )
        scan_outputs: List[torch.Tensor] = []
        for i in range(seq_len):
            ssm_state = discrete_a[:, :, i, :] * ssm_state + delta_b_u[:, :, i, :]
            scan_output_i = torch.matmul(ssm_state, c_raw[:, i, :].unsqueeze(-1))
            scan_outputs.append(scan_output_i.squeeze(-1))
        scan_output_raw = torch.stack(scan_outputs, dim=-1)

        d_vec = mixer.D.float().view(1, -1, 1)
        y_pre = scan_output_raw + d_vec * x_activated

        z_before_silu = z_mixer.transpose(1, 2)
        z_after_silu = F.silu(z_before_silu)
        y_gated = y_pre * z_after_silu
        mixer_output = mixer.out_proj(y_gated.transpose(1, 2))

    return {
        "L1_rmsnorm": to_numpy(x_norm),
        "L2_inproj_xz": to_numpy(xz),
        "L3_x_before_conv": to_numpy(x_mixer_t),
        "L4_x_after_conv": to_numpy(x_conv),
        "L5_x_activated": to_numpy(x_activated),
        "L6_delta_before_softplus": to_numpy(delta_before_softplus),
        "L7_delta_final": to_numpy(delta),
        "L8_B_raw": to_numpy(b_raw),
        "L8_C_raw": to_numpy(c_raw),
        "L9_y_pre_manual": to_numpy(y_pre),
        "L10_y_gated_manual": to_numpy(y_gated),
        "L11_out_proj_manual": to_numpy(mixer_output),
        "mamba_block_input": to_numpy(mamba_block_input),
    }


def run_mixer_forward_tensors(model: ITMN, waveform: torch.Tensor) -> Dict[str, np.ndarray]:
    mamba_block = model.layers[0].mamba_block
    mixer = mamba_block.mixer
    with torch.no_grad():
        x_norm = mamba_block.norm(build_mamba_block_input(model, waveform))
        y_fwd = mixer(x_norm)
    return {
        "L11_mixer_forward": to_numpy(y_fwd),
        "L1_rmsnorm_ref": to_numpy(x_norm),
    }


def run_mamba_ssm_oracle(model: ITMN, waveform: torch.Tensor) -> Optional[Dict[str, np.ndarray]]:
    try:
        from einops import rearrange
        from mamba_ssm.ops.selective_scan_interface import selective_scan_fn
    except ImportError:
        return None

    device = waveform.device
    mamba_block = model.layers[0].mamba_block
    mixer = mamba_block.mixer
    seq_len = waveform.shape[1]

    with torch.no_grad():
        x_norm = mamba_block.norm(build_mamba_block_input(model, waveform))
        xz = rearrange(mixer.in_proj(x_norm), "b l d -> b d l")
        x_branch, z_branch = xz.chunk(2, dim=1)
        x_branch = F.silu(mixer.conv1d(x_branch)[..., :seq_len])

        x_dbl = mixer.x_proj(rearrange(x_branch, "b d l -> (b l) d"))
        dt, b_mat, c_mat = torch.split(
            x_dbl, [mixer.dt_rank, mixer.d_state, mixer.d_state], dim=-1
        )
        dt = mixer.dt_proj.weight @ dt.t()
        dt = rearrange(dt, "d (b l) -> b d l", l=seq_len)
        b_mat = rearrange(b_mat, "(b l) dstate -> b dstate l", l=seq_len).contiguous()
        c_mat = rearrange(c_mat, "(b l) dstate -> b dstate l", l=seq_len).contiguous()
        a = -torch.exp(mixer.A_log.float())

        y_gated = selective_scan_fn(
            x_branch,
            dt,
            a,
            b_mat,
            c_mat,
            mixer.D.float(),
            z=z_branch,
            delta_bias=mixer.dt_proj.bias.float(),
            delta_softplus=True,
        )
        y_pre = selective_scan_fn(
            x_branch,
            dt,
            a,
            b_mat,
            c_mat,
            mixer.D.float(),
            z=None,
            delta_bias=mixer.dt_proj.bias.float(),
            delta_softplus=True,
        )
        out_proj = mixer.out_proj(rearrange(y_gated, "b d l -> b l d"))

    return {
        "L9_scan_mamba_ssm": to_numpy(y_pre),
        "L10_y_gated_mamba_ssm": to_numpy(y_gated),
        "L11_out_proj_mamba_ssm": to_numpy(out_proj),
    }


def float_to_q16(val: float) -> int:
    q = int(round(float(val) * (1 << 12)))
    return max(-32768, min(32767, q))


def q16_roundtrip(arr: np.ndarray) -> np.ndarray:
    out = np.empty(arr.size, dtype=np.float32)
    flat = arr.reshape(-1)
    for i, v in enumerate(flat):
        q = float_to_q16(float(v))
        out[i] = np.float32(q / float(1 << 12))
    return out.reshape(arr.shape)


def write_manifest(out_dir: Path, args: argparse.Namespace, ckpt_path: Path,
                   packages: Dict[str, str]) -> None:
    lines = [
        f"timestamp_utc: {datetime.now(timezone.utc).isoformat()}",
        f"exp_type: {args.exp_type}",
        f"input_source: {args.input_source}",
        f"device: {args.device}",
        f"checkpoint: {ckpt_path}",
    ]
    if ckpt_path.is_file():
        lines.append(f"checkpoint_sha256: {sha256_file(ckpt_path)}")
    for k, v in packages.items():
        lines.append(f"{k}: {v}")
    (out_dir / "validation_manifest.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_summary(out_dir: Path, results: List[CompareResult], report_dir: Path,
                  notes: List[str]) -> None:
    passed = sum(1 for r in results if r.passed)
    lines = [
        "# Golden validation summary",
        "",
        f"- Report directory: `{report_dir}`",
        f"- Comparisons: {len(results)}",
        f"- Passed: {passed}/{len(results)}",
        "",
        "## Results",
        "",
        "| ID | Name | max err | mean err | p99 | atol | pass | note |",
        "|----|------|---------|----------|-----|------|------|------|",
    ]
    for r in results:
        lines.append(
            f"| {r.layer_id} | {r.name} | {r.max_err:.3e} | {r.mean_err:.3e} | "
            f"{r.p99_err:.3e} | {r.atol:.1e} | {'PASS' if r.passed else 'FAIL'} | {r.note} |"
        )

    if notes:
        lines.extend(["", "## Notes", ""])
        lines.extend(f"- {n}" for n in notes)

    lines.extend([
        "",
        "## Interpretation",
        "",
        "- Phase 1 (`extract` live vs saved `cpp_golden_files`): expect PASS.",
        "- Phase 2 (`mixer.forward` vs `mamba_ssm`): expect PASS (L11b).",
        "- Manual scan (`y_pre`, `y_gated`) vs `mamba_ssm`: expect PASS (L9, L10).",
        "- Golden scan: `y_pre = C*h + D*x`, then `y_gated = y_pre * silu(z)`.",
        "",
    ])
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    with (out_dir / "results.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["layer_id", "name", "max_err", "mean_err", "p99_err", "atol", "passed", "note"])
        for r in results:
            writer.writerow([r.layer_id, r.name, r.max_err, r.mean_err, r.p99_err, r.atol, r.passed, r.note])


def load_waveform(args: argparse.Namespace, device: torch.device) -> torch.Tensor:
    if args.input_source == "cpp":
        cpp_path = CPP_DIR / "00_00_ITMN_input_waveform.txt"
        if not cpp_path.exists():
            raise FileNotFoundError(f"Missing {cpp_path}; run extract_single_sample.py first.")
        arr = np.loadtxt(cpp_path, dtype=np.float32).reshape(-1)
        if arr.size != 12000:
            raise ValueError(f"Expected 12000 values in cpp input, got {arr.size}")
        return torch.from_numpy(arr.reshape(1, 1000, 12)).to(device=device, dtype=torch.float32)

    _, _, test_loader, _, _ = get_loaders(
        get_config(str(ITMN_ROOT / "config.yaml"))["data"], args.exp_type, 1
    )
    sample = next(iter(test_loader))
    return sample["waveform"][0:1].to(device=device, dtype=torch.float32)


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare golden extraction vs ITMN / mamba_ssm")
    parser.add_argument("--exp_type", default="super")
    parser.add_argument("--input_source", choices=["dataset", "cpp"], default="cpp")
    parser.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda"])
    parser.add_argument("--atol_float", type=float, default=1e-5)
    parser.add_argument("--atol_scan", type=float, default=1e-4)
    parser.add_argument("--skip_plots", action="store_true")
    args = parser.parse_args()

    if not ITMN_ROOT.is_dir():
        print(f"ERROR: missing ITMN at {ITMN_ROOT}")
        return 2

    if args.device == "auto":
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    else:
        device = torch.device(args.device)

    if device.type == "cpu":
        print("WARNING: mamba_ssm selective_scan requires CUDA in most installs.")

    config = get_config(str(ITMN_ROOT / "config.yaml"))
    config["exp_type"] = args.exp_type.lower()
    exp_key = config["exp_type"].upper()
    num_class = {
        "SUPER": 5, "SUB": 23, "RHYTHM": 12, "ALL": 71,
        "DIAG": 44, "FORM": 19, "CPSC": 9,
    }[exp_key]

    ckpt_path = Path(config["test_ckpt_path"])
    model = ITMN(n_classes=num_class, **config["model"]).to(device)
    checkpoint = torch.load(ckpt_path, map_location=device)
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_dir = REPORT_ROOT / stamp
    fig_dir = out_dir / "figures"
    fig_dir.mkdir(parents=True, exist_ok=True)

    packages = {
        "torch": torch.__version__,
        "numpy": np.__version__,
    }
    for pkg in ("mamba_ssm", "einops"):
        try:
            packages[pkg] = importlib.import_module(pkg).__version__
        except Exception:
            packages[pkg] = "not_installed"

    write_manifest(out_dir, args, ckpt_path, packages)

    waveform = load_waveform(args, device)
    ext = run_extract_tensors(model, waveform)
    ref_fwd = run_mixer_forward_tensors(model, waveform)
    ssm = run_mamba_ssm_oracle(model, waveform)

    results: List[CompareResult] = []
    notes: List[str] = []

    def add_cmp(layer_id: str, name: str, ref: np.ndarray, cmp: np.ndarray,
                atol: float, note: str = "", plot: bool = True) -> None:
        res = compare_arrays(layer_id, name, ref, cmp, atol, note)
        results.append(res)
        if plot and not args.skip_plots:
            plot_overlay(ref, cmp, f"{layer_id} {name}", fig_dir / f"{layer_id}_overlay.png")
            plot_scatter(ref, cmp, f"{layer_id} scatter", fig_dir / f"{layer_id}_scatter.png")

    # Phase 1: extract manual uses same torch modules for pre-scan tensors.
    # Reference = recomputed live tensors (self-consistency) + saved cpp files.
    pre_scan_keys = [
        ("L1", "rmsnorm", "L1_rmsnorm", "_MambaBlock_after_norm"),
        ("L2", "inproj_xz", "L2_inproj_xz", "XZ_after_linear"),
        ("L5", "x_activated", "L5_x_activated", "_Mixer_x_activated"),
        ("L7", "delta_final", "L7_delta_final", "_Mixer_delta_final"),
    ]
    for layer_id, label, key, cpp_pat in pre_scan_keys:
        txt = load_cpp_txt(cpp_pat)
        if txt is not None:
            add_cmp(layer_id, f"live_vs_cpp_{label}", ext[key], txt, 1e-6,
                    note="extract live vs saved cpp_golden_files")

    add_cmp("L1b", "rmsnorm_vs_mixer_path", ext["L1_rmsnorm"], ref_fwd["L1_rmsnorm_ref"],
            args.atol_float, note="same norm() call")

    add_cmp("L11a", "manual_outproj_vs_mixer_forward", ext["L11_out_proj_manual"],
            ref_fwd["L11_mixer_forward"], args.atol_float,
            note="manual path with D*x skip")

    if ssm is not None:
        add_cmp("L11b", "mixer_forward_vs_mamba_ssm", ref_fwd["L11_mixer_forward"],
                ssm["L11_out_proj_mamba_ssm"], args.atol_float,
                note="oracle: selective_scan_fn + out_proj")
        add_cmp("L9", "manual_y_pre_vs_mamba_ssm", ext["L9_y_pre_manual"],
                ssm["L9_scan_mamba_ssm"], args.atol_scan,
                note="y_pre = C*h + D*x")
        add_cmp("L10", "manual_y_gated_vs_mamba_ssm", ext["L10_y_gated_manual"],
                ssm["L10_y_gated_mamba_ssm"], args.atol_scan,
                note="y_pre * silu(z); matches mamba_ssm gated output")
        if not args.skip_plots:
            plot_error_heatmap(
                ssm["L10_y_gated_mamba_ssm"], ext["L10_y_gated_manual"],
                "L10 |mamba_ssm - manual|", fig_dir / "L10_scan_heatmap.png",
                shape=(128, waveform.shape[1]),
            )
    else:
        notes.append("mamba_ssm not available; Phase 2 oracle skipped.")

    # Phase 3: quant round-trip sanity on a subset
    q_ref = q16_roundtrip(ext["L7_delta_final"])
    add_cmp("Q1", "delta_q16_roundtrip", ext["L7_delta_final"], q_ref, 1.0 / (1 << 12) + 1e-6,
            note="quantization grid only", plot=False)

    if not args.skip_plots:
        plot_summary_bar(results, fig_dir / "summary_max_err.png")

    write_summary(out_dir, results, out_dir, notes)

    print(f"\nReport written to: {out_dir}")
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        print(f"  [{status}] {r.layer_id} {r.name}: max={r.max_err:.3e} (atol={r.atol:.1e}) {r.note}")

    failed_critical = [r for r in results if not r.passed and r.layer_id in {"L9", "L10", "L11b", "L1"}]
    return 0 if not failed_critical else 1


if __name__ == "__main__":
    raise SystemExit(main())
