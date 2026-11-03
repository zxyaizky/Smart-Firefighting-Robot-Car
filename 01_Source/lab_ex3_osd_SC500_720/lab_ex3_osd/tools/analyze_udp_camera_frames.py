#!/usr/bin/env python3
"""Analyze lossless FPGA UDP frames and run the deployed QAT model on them."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import cv2
import numpy as np
import torch


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument(
        "--model-dir", type=Path,
        default=Path("C:/Users/lx292/Desktop/safety_grid_v1"),
    )
    parser.add_argument("--integer-check-first", action="store_true")
    args = parser.parse_args()

    sys.path.insert(0, str(args.model_dir))
    from test_qat_fire_camera import load_qat_model  # type: ignore

    manifest = json.loads((args.capture / "capture.json").read_text(encoding="utf-8"))
    model = load_qat_model(
        args.model_dir / "runs/qat_fire_only/best_qat.pth", torch.device("cpu")
    )
    if args.integer_check_first:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "sim"))
        from run_fire_only import reference_tensor  # type: ignore

    outputs = []
    previous = None
    for entry in manifest["frames"]:
        bgr = cv2.imread(entry["file"], cv2.IMREAD_COLOR)
        if bgr is None or bgr.shape != (120, 160, 3):
            raise ValueError(f"invalid frame {entry['file']}")
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        content = rgb[15:105]
        flat = content.reshape(-1, 3)
        tensor = torch.from_numpy(rgb.transpose(2, 0, 1).copy()).float()
        tensor = tensor.div_(255).unsqueeze(0)
        with torch.no_grad():
            prediction = model(tensor)[0]
        gy, gx = divmod(int(torch.argmax(prediction[..., 0])), 20)
        cell = prediction[gy, gx]
        cell_bytes = [int(np.clip(round(float(value) * 255), 0, 255))
                      for value in cell]
        obj, dx, dy, width, height, fire = cell_bytes
        overlay_y, overlay_x = np.where(np.all(rgb == [255, 32, 32], axis=2))
        row = {
            "frame_id": entry["frame_id"],
            "mean_rgb": np.round(flat.mean(axis=0), 1).tolist(),
            "median_rgb": np.median(flat, axis=0).astype(int).tolist(),
            "p99_rgb": np.percentile(flat, 99, axis=0).astype(int).tolist(),
            "clipped_rgb_percent": np.round((flat == 255).mean(axis=0) * 100, 2).tolist(),
            "dark_percent": round(float(np.mean(np.max(flat, axis=1) < 25)) * 100, 2),
            "white_percent": round(float(np.mean(np.min(flat, axis=1) > 245)) * 100, 2),
            "overlay_red_pixels": int(len(overlay_x)),
            "overlay_bbox": [int(overlay_x.min()), int(overlay_y.min()),
                             int(overlay_x.max()), int(overlay_y.max())]
            if len(overlay_x) else None,
            "top_pad_nonzero": int(np.count_nonzero(rgb[:15])),
            "bottom_pad_nonzero": int(np.count_nonzero(rgb[105:])),
            "winner": {"gx": gx, "gy": gy, "obj": obj, "dx": dx, "dy": dy,
                       "w": width, "h": height, "fire": fire,
                       "detect_128": obj >= 128 and fire >= 128,
                       "detect_64": obj >= 64 and fire >= 128},
        }
        if args.integer_check_first and not outputs:
            integer = reference_tensor(rgb.transpose(2, 0, 1))
            qat_bytes = np.clip(
                np.rint(prediction.numpy() * 255), 0, 255
            ).astype(np.uint8).transpose(2, 0, 1)
            integer_index = int(np.argmax(integer[0]))
            iy, ix = divmod(integer_index, 20)
            row["compiled_integer_check"] = {
                "different_output_bytes": int(np.count_nonzero(integer != qat_bytes)),
                "total_output_bytes": int(integer.size),
                "max_abs_delta": int(np.max(np.abs(
                    integer.astype(np.int16) - qat_bytes.astype(np.int16)
                ))),
                "winner": {"gx": ix, "gy": iy,
                           "obj": int(integer[0, iy, ix]),
                           "fire": int(integer[5, iy, ix])},
            }
        if len(overlay_x):
            # The UDP path draws the previous FPGA result. Inpaint that small
            # synthetic outline only as a sensitivity check, not as an exact
            # reconstruction of the FPGA network's unmarked input.
            overlay_mask = np.all(rgb == [255, 32, 32], axis=2).astype(np.uint8)
            unmarked = cv2.inpaint(rgb, overlay_mask, 1, cv2.INPAINT_TELEA)
            unmarked_tensor = torch.from_numpy(
                unmarked.transpose(2, 0, 1).copy()
            ).float().div_(255).unsqueeze(0)
            with torch.no_grad():
                unmarked_prediction = model(unmarked_tensor)[0]
            uy, ux = divmod(int(torch.argmax(unmarked_prediction[..., 0])), 20)
            unmarked_cell = unmarked_prediction[uy, ux]
            row["winner_after_overlay_inpaint"] = {
                "gx": ux, "gy": uy,
                "obj": int(np.clip(round(float(unmarked_cell[0]) * 255), 0, 255)),
                "fire": int(np.clip(round(float(unmarked_cell[5]) * 255), 0, 255)),
            }
        if previous is not None:
            row["mean_abs_change_from_prev"] = round(
                float(np.abs(content.astype(np.int16) - previous.astype(np.int16)).mean()), 2
            )
        previous = content.copy()
        outputs.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
    report = {"source": manifest, "analysis": outputs}
    (args.capture / "analysis.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )


if __name__ == "__main__":
    main()
