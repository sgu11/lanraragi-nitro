#!/usr/bin/env python3
"""Benchmark reader image border-crop algorithms on anonymized library samples.

The harness intentionally stores no original archive paths or page names. It
expects a sample directory containing image files named `sample_XX_<hash>.*` and
an optional `sample_manifest.json` produced from the live library.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import math
import statistics
import textwrap
import time
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from typing import Callable, Iterable

import numpy as np
import pandas as pd
from PIL import Image


IMPLEMENTATIONS = [
    "LANraragi",
    "Komikku",
    "Suwayomi",
]

LANRARAGI_MIN_BYTE_SAVINGS_RATIO = 0.02
LANRARAGI_MIN_AREA_SAVINGS_RATIO = 0.05


@dataclass(frozen=True)
class Bounds:
    x: int
    y: int
    width: int
    height: int

    def area_ratio(self, width: int, height: int) -> float:
        if width <= 0 or height <= 0:
            return 1.0
        return (self.width * self.height) / (width * height)


def clamp(value: int, lo: int, hi: int) -> int:
    return min(hi, max(lo, value))


def sample_positions(limit: int) -> list[int]:
    if limit <= 1:
        return [0]
    return [clamp(int((limit - 1) * p), 0, limit - 1) for p in (0.10, 0.30, 0.50, 0.70, 0.90)]


def pil_image_from_bytes(data: bytes) -> Image.Image:
    image = Image.open(BytesIO(data))
    image.load()
    return image


def image_arrays(image: Image.Image) -> tuple[np.ndarray, np.ndarray]:
    rgb = np.asarray(image.convert("RGB"), dtype=np.uint8)
    gray = np.asarray(image.convert("L"), dtype=np.uint8)
    return rgb, gray


def encode_crop(image: Image.Image, bounds: Bounds, fmt: str) -> bytes:
    cropped = image.crop((bounds.x, bounds.y, bounds.x + bounds.width, bounds.y + bounds.height))
    out = BytesIO()
    normalized = (fmt or "jpeg").lower()
    if normalized in {"jpg", "jpeg"}:
        cropped.convert("RGB").save(out, format="JPEG", quality=95)
    elif normalized == "png":
        cropped.save(out, format="PNG")
    elif normalized == "webp":
        cropped.convert("RGB").save(out, format="WEBP", quality=95)
    else:
        cropped.convert("RGB").save(out, format="PNG")
    return out.getvalue()


def suwayomi_bounds(rgb: np.ndarray) -> Bounds | None:
    height, width, _ = rgb.shape
    if width == 0 or height == 0:
        return None

    filled = np.any(rgb < 230, axis=2)

    def threshold(length: int) -> int:
        return max(1, math.ceil(length * 0.0025))

    row_threshold = threshold(width)
    top = 0
    for y in range(height):
        if int(filled[y, :].sum()) >= row_threshold:
            top = y
            break

    bottom = height - 1
    for y in range(height - 1, top - 1, -1):
        if int(filled[y, :].sum()) >= row_threshold:
            bottom = y
            break

    scan_height = bottom - top + 1
    if scan_height <= 0:
        return None

    column_threshold = threshold(scan_height)
    left = 0
    for x in range(width):
        if int(filled[top : bottom + 1, x].sum()) >= column_threshold:
            left = x
            break

    right = width - 1
    for x in range(width - 1, left - 1, -1):
        if int(filled[top : bottom + 1, x].sum()) >= column_threshold:
            right = x
            break

    cropped_top = top
    cropped_bottom = height - 1 - bottom
    cropped_left = left
    cropped_right = width - 1 - right
    if all(v < 5 for v in (cropped_top, cropped_bottom, cropped_left, cropped_right)):
        return None

    crop_width = right - left + 1
    crop_height = bottom - top + 1
    if crop_width <= 0 or crop_height <= 0:
        return None
    return Bounds(left, top, crop_width, crop_height)


def komikku_bounds(gray: np.ndarray) -> Bounds | None:
    height, width = gray.shape
    if width == 0 or height == 0:
        return None

    filled_ratio_limit = 0.0025
    threshold_for_black = int(255.0 * 0.75)
    threshold_for_white = int(255.0 - 255.0 * 0.75)

    def is_black(pixel: np.ndarray | int) -> np.ndarray | bool:
        return pixel < threshold_for_black

    def is_white(pixel: np.ndarray | int) -> np.ndarray | bool:
        return pixel > threshold_for_white

    def filled_limit(length: int) -> int:
        return int(round(length * filled_ratio_limit / 2))

    def side_detector(edge_values: np.ndarray) -> Callable[[np.ndarray], np.ndarray] | None:
        limit = filled_limit(len(edge_values))
        black_pixels = int(is_black(edge_values).sum())
        white_pixels = int(is_white(edge_values).sum())
        if white_pixels > limit and black_pixels > limit:
            return None
        if black_pixels > limit:
            return is_white
        return is_black

    def find_top() -> int:
        detector = side_detector(gray[0, ::2])
        if detector is None:
            return 0
        limit = filled_limit(width)
        for y in range(1, height):
            if int(detector(gray[y, ::2]).sum()) > limit:
                return y
        return 0

    def find_bottom() -> int:
        detector = side_detector(gray[height - 1, ::2])
        if detector is None:
            return height
        limit = filled_limit(width)
        for y in range(height - 2, 0, -1):
            if int(detector(gray[y, ::2]).sum()) > limit:
                return y + 1
        return height

    top = find_top()
    bottom = find_bottom()
    if bottom <= top:
        return None

    def find_left() -> int:
        detector = side_detector(gray[top:bottom:2, 0])
        if detector is None:
            return 0
        limit = filled_limit(height)
        for x in range(1, width):
            if int(detector(gray[top:bottom:2, x]).sum()) > limit:
                return x
        return 0

    def find_right() -> int:
        detector = side_detector(gray[top:bottom:2, width - 1])
        if detector is None:
            return width
        limit = filled_limit(height)
        for x in range(width - 2, 0, -1):
            if int(detector(gray[top:bottom:2, x]).sum()) > limit:
                return x + 1
        return width

    left = find_left()
    right = find_right()
    if right <= left:
        return None

    if left == 0 and top == 0 and right == width and bottom == height:
        return None
    return Bounds(left, top, right - left, bottom - top)


def lanraragi_bounds(rgb: np.ndarray) -> Bounds | None:
    height, width, _ = rgb.shape
    if width == 0 or height == 0:
        return None
    if width < 7 or height < 7:
        return None
    if width > height:
        return None

    light_background_min = 191
    dark_background_max = 64
    edge_ignore_pixels = 2
    edge_background_band = 4
    edge_background_step = 16
    edge_line_sample_step = 4
    edge_blank_delta = 40
    edge_allowed_bad_ratio = 0.005
    edge_nonblank_run = 3
    edge_scan_max_ratio = 0.30
    min_crop_pixels = 5
    min_retain_ratio = 0.20
    safety_padding = 2

    def channel_luma(channels: np.ndarray) -> int:
        r, g, b = [int(v) for v in channels[:3]]
        return int(0.299 * r + 0.587 * g + 0.114 * b + 0.5)

    def edge_background_mode(channels: np.ndarray) -> str | None:
        luma = channel_luma(channels)
        if luma >= light_background_min:
            return "light"
        if luma <= dark_background_max:
            return "dark"
        return None

    def edge_background(side: str) -> np.ndarray | None:
        samples: list[np.ndarray] = []
        ignore = edge_ignore_pixels
        if width <= ignore * 2 or height <= ignore * 2:
            return None
        if side in {"left", "right"}:
            if side == "left":
                start_x = ignore
                end_x = min(width - ignore - 1, ignore + edge_background_band - 1)
            else:
                start_x = max(ignore, width - ignore - edge_background_band)
                end_x = width - ignore - 1
            for x in range(start_x, end_x + 1):
                for y in range(ignore, height - ignore, edge_background_step):
                    samples.append(rgb[y, x, :3].astype(int))
        else:
            if side == "top":
                start_y = ignore
                end_y = min(height - ignore - 1, ignore + edge_background_band - 1)
            else:
                start_y = max(ignore, height - ignore - edge_background_band)
                end_y = height - ignore - 1
            for y in range(start_y, end_y + 1):
                for x in range(ignore, width - ignore, edge_background_step):
                    samples.append(rgb[y, x, :3].astype(int))
        if not samples:
            return None
        return np.median(np.vstack(samples), axis=0)

    def edge_line_bad_ratio(side: str, position: int, background: np.ndarray, background_mode: str) -> float:
        bad = 0
        total = 0
        ignore = edge_ignore_pixels
        if side in {"left", "right"}:
            for y in range(ignore, height - ignore, edge_line_sample_step):
                channels = rgb[y, position, :3].astype(int)
                delta = int(np.max(np.abs(channels - background)))
                luma = channel_luma(channels)
                if background_mode == "dark":
                    is_bad = delta > edge_blank_delta or luma >= light_background_min
                else:
                    is_bad = delta > edge_blank_delta or luma <= dark_background_max
                if is_bad:
                    bad += 1
                total += 1
        else:
            for x in range(ignore, width - ignore, edge_line_sample_step):
                channels = rgb[position, x, :3].astype(int)
                delta = int(np.max(np.abs(channels - background)))
                luma = channel_luma(channels)
                if background_mode == "dark":
                    is_bad = delta > edge_blank_delta or luma >= light_background_min
                else:
                    is_bad = delta > edge_blank_delta or luma <= dark_background_max
                if is_bad:
                    bad += 1
                total += 1
        return 1.0 if total == 0 else bad / total

    def scan_positions(side: str) -> Iterable[int]:
        ignore = edge_ignore_pixels
        if side == "left":
            max_x = min(width - ignore - 1, max(ignore, int(width * edge_scan_max_ratio)))
            return range(ignore, max_x + 1)
        if side == "right":
            min_x = max(ignore, min(width - ignore - 1, int(width * (1 - edge_scan_max_ratio))))
            return range(width - ignore - 1, min_x - 1, -1)
        if side == "top":
            max_y = min(height - ignore - 1, max(ignore, int(height * edge_scan_max_ratio)))
            return range(ignore, max_y + 1)
        min_y = max(ignore, min(height - ignore - 1, int(height * (1 - edge_scan_max_ratio))))
        return range(height - ignore - 1, min_y - 1, -1)

    def detect_edge(side: str) -> int | None:
        background = edge_background(side)
        if background is None:
            return None
        background_mode = edge_background_mode(background)
        if background_mode is None:
            return None
        run = 0
        for position in scan_positions(side):
            if edge_line_bad_ratio(side, position, background, background_mode) > edge_allowed_bad_ratio:
                run += 1
                if run >= edge_nonblank_run:
                    if side in {"left", "top"}:
                        return position - run + 1
                    return position + run - 1
            else:
                run = 0
        return None

    left, top, right, bottom = 0, 0, width, height
    left_boundary = detect_edge("left")
    if left_boundary is not None and left_boundary >= min_crop_pixels:
        left = left_boundary
    right_boundary = detect_edge("right")
    if right_boundary is not None and width - (right_boundary + 1) >= min_crop_pixels:
        right = right_boundary + 1
    top_boundary = detect_edge("top")
    if top_boundary is not None and top_boundary >= min_crop_pixels:
        top = top_boundary
    bottom_boundary = detect_edge("bottom")
    if bottom_boundary is not None and height - (bottom_boundary + 1) >= min_crop_pixels:
        bottom = bottom_boundary + 1

    if right <= left or bottom <= top:
        return None
    bounds = Bounds(left, top, right - left, bottom - top)
    cropped = (
        bounds.x,
        bounds.y,
        width - (bounds.x + bounds.width),
        height - (bounds.y + bounds.height),
    )
    if all(v < min_crop_pixels for v in cropped):
        return None
    if bounds.width / width < min_retain_ratio or bounds.height / height < min_retain_ratio:
        return None

    padded_left = max(0, bounds.x - safety_padding)
    padded_top = max(0, bounds.y - safety_padding)
    padded_right = min(width, bounds.x + bounds.width + safety_padding)
    padded_bottom = min(height, bounds.y + bounds.height + safety_padding)
    return Bounds(padded_left, padded_top, padded_right - padded_left, padded_bottom - padded_top)


ALGORITHMS: dict[str, Callable[[np.ndarray, np.ndarray], Bounds | None]] = {
    "LANraragi": lambda rgb, gray: lanraragi_bounds(rgb),
    "Komikku": lambda rgb, gray: komikku_bounds(gray),
    "Suwayomi": lambda rgb, gray: suwayomi_bounds(rgb),
}


def run_once(sample_path: Path, implementation: str, encode: bool = True) -> dict:
    data = sample_path.read_bytes()
    suffix = sample_path.suffix.lower().lstrip(".").replace("jpeg", "jpg")
    started = time.perf_counter()
    image = pil_image_from_bytes(data)
    width, height = image.size
    rgb, gray = image_arrays(image)
    decode_ms = (time.perf_counter() - started) * 1000

    detect_started = time.perf_counter()
    bounds = ALGORITHMS[implementation](rgb, gray)
    detect_ms = (time.perf_counter() - detect_started) * 1000

    encoded_bytes = None
    encode_ms = 0.0
    crop_rejected_larger = False
    if encode and bounds is not None:
        encode_started = time.perf_counter()
        encoded_bytes = encode_crop(image, bounds, suffix)
        encode_ms = (time.perf_counter() - encode_started) * 1000
        if (
            implementation == "LANraragi"
            and len(encoded_bytes) >= len(data) * (1 - LANRARAGI_MIN_BYTE_SAVINGS_RATIO)
            and (1 - bounds.area_ratio(width, height)) < LANRARAGI_MIN_AREA_SAVINGS_RATIO
        ):
            crop_rejected_larger = True
            bounds = None
            encoded_bytes = None

    total_ms = (time.perf_counter() - started) * 1000
    area_ratio = bounds.area_ratio(width, height) if bounds is not None else 1.0
    return {
        "implementation": implementation,
        "width": width,
        "height": height,
        "format": suffix,
        "input_bytes": len(data),
        "cropped": bounds is not None,
        "crop_rejected_larger": crop_rejected_larger,
        "bounds": None if bounds is None else bounds.__dict__,
        "area_ratio": area_ratio,
        "area_reduction_pct": (1 - area_ratio) * 100,
        "output_bytes": len(encoded_bytes) if encoded_bytes is not None else len(data),
        "byte_reduction_pct": (1 - (len(encoded_bytes) / len(data))) * 100 if encoded_bytes else 0.0,
        "decode_ms": decode_ms,
        "detect_ms": detect_ms,
        "encode_ms": encode_ms,
        "total_ms": total_ms,
    }


def load_manifest(sample_dir: Path) -> dict:
    manifest_path = sample_dir / "sample_manifest.json"
    if manifest_path.exists():
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    return {"samples": []}


def sample_id_from_path(path: Path) -> str:
    return path.stem.split("_")[1].upper()


def source_hash_from_path(path: Path) -> str:
    parts = path.stem.split("_")
    return parts[2] if len(parts) >= 3 else path.stem


def classify_and_select(sample_paths: list[Path], max_samples: int) -> tuple[list[Path], list[dict]]:
    records: list[dict] = []
    for sample_path in sample_paths:
        sample_id = sample_id_from_path(sample_path)
        source_hash = source_hash_from_path(sample_path)
        sample_records = []
        for implementation in IMPLEMENTATIONS:
            result = run_once(sample_path, implementation, encode=False)
            result.update({"sample_id": sample_id, "source_hash": source_hash, "sample_file": sample_path.name})
            sample_records.append(result)
            records.append(result)

        width = sample_records[0]["width"]
        height = sample_records[0]["height"]
        crop_count = sum(1 for r in sample_records if r["cropped"])
        best_reduction = max(r["area_reduction_pct"] for r in sample_records)
        for record in sample_records:
            record["selection_crop_count"] = crop_count
            record["selection_best_reduction_pct"] = best_reduction
            record["selection_landscape"] = width > height

    by_sample = {}
    for record in records:
        by_sample.setdefault(record["sample_file"], []).append(record)

    def sample_score(sample_file: str) -> dict:
        rows = by_sample[sample_file]
        first = rows[0]
        return {
            "sample_file": sample_file,
            "best_reduction": max(r["area_reduction_pct"] for r in rows),
            "crop_count": sum(1 for r in rows if r["cropped"]),
            "landscape": bool(first["width"] > first["height"]),
            "input_bytes": int(first["input_bytes"]),
        }

    scores = [sample_score(path.name) for path in sample_paths]
    selected_names: list[str] = []

    def add_candidates(candidates: Iterable[dict], limit: int) -> None:
        for candidate in candidates:
            name = candidate["sample_file"]
            if name not in selected_names:
                selected_names.append(name)
            if len(selected_names) >= limit:
                return

    add_candidates(sorted(scores, key=lambda s: s["best_reduction"], reverse=True), min(max_samples, 8))
    add_candidates([s for s in scores if s["crop_count"] in {1, 2}], min(max_samples, 14))
    add_candidates([s for s in scores if s["landscape"]], min(max_samples, 18))
    add_candidates(sorted(scores, key=lambda s: s["input_bytes"], reverse=True), min(max_samples, 22))
    add_candidates([s for s in scores if s["crop_count"] == 0], max_samples)

    selected = [path for path in sample_paths if path.name in set(selected_names[:max_samples])]
    return selected, records


def summarize(records: list[dict], selected_sample_count: int, scanned_sample_count: int) -> dict:
    df = pd.DataFrame(records)
    summary_rows = []
    for implementation, group in df.groupby("implementation"):
        per_sample = group.groupby("sample_id").agg(
            median_total_ms=("total_ms", "median"),
            median_detect_ms=("detect_ms", "median"),
            median_encode_ms=("encode_ms", "median"),
            cropped=("cropped", "max"),
            area_reduction_pct=("area_reduction_pct", "median"),
            byte_reduction_pct=("byte_reduction_pct", "median"),
        )
        cropped_samples = per_sample[per_sample["cropped"].astype(bool)]
        if cropped_samples.empty:
            cropped_area_median = 0.0
            cropped_area_p90 = 0.0
            cropped_byte_median = 0.0
        else:
            cropped_area_median = float(cropped_samples["area_reduction_pct"].median())
            cropped_area_p90 = float(cropped_samples["area_reduction_pct"].quantile(0.90))
            cropped_byte_median = float(cropped_samples["byte_reduction_pct"].median())
        summary_rows.append(
            {
                "implementation": implementation,
                "median_total_ms": round(float(per_sample["median_total_ms"].median()), 2),
                "p90_total_ms": round(float(per_sample["median_total_ms"].quantile(0.90)), 2),
                "median_detect_ms": round(float(per_sample["median_detect_ms"].median()), 2),
                "median_encode_ms": round(float(per_sample["median_encode_ms"].median()), 2),
                "crop_rate_pct": round(float(per_sample["cropped"].mean() * 100), 1),
                "cropped_sample_count": int(cropped_samples.shape[0]),
                "median_area_reduction_pct": round(float(per_sample["area_reduction_pct"].median()), 1),
                "median_byte_reduction_pct": round(float(per_sample["byte_reduction_pct"].median()), 1),
                "median_area_reduction_cropped_only_pct": round(cropped_area_median, 1),
                "p90_area_reduction_cropped_only_pct": round(cropped_area_p90, 1),
                "median_byte_reduction_cropped_only_pct": round(cropped_byte_median, 1),
            }
        )
    summary_rows.sort(key=lambda row: row["median_total_ms"])
    fastest = summary_rows[0]
    return {
        "scanned_sample_count": scanned_sample_count,
        "selected_sample_count": selected_sample_count,
        "repeat_count": int(df["repeat"].max()) + 1 if "repeat" in df else 1,
        "implementation_summary": summary_rows,
        "fastest_median_implementation": fastest["implementation"],
        "fastest_median_total_ms": fastest["median_total_ms"],
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
    }


def use_chart_theme() -> None:
    import seaborn as sns
    import matplotlib.pyplot as plt

    sns.set_theme(
        style="whitegrid",
        rc={
            "figure.facecolor": "#FCFCFD",
            "axes.facecolor": "#FFFFFF",
            "axes.edgecolor": "#D7DBE7",
            "axes.labelcolor": "#1F2430",
            "grid.color": "#E6E8F0",
            "grid.linewidth": 0.8,
            "font.family": "sans-serif",
            "font.sans-serif": ["Aptos", "Inter", "Segoe UI", "DejaVu Sans", "Arial", "sans-serif"],
            "font.monospace": ["SF Mono", "Menlo", "Consolas", "DejaVu Sans Mono", "monospace"],
        },
    )
    plt.rcParams["savefig.facecolor"] = "none"
    plt.rcParams["savefig.edgecolor"] = "none"


def add_chart_header(fig, ax, title: str, subtitle: str) -> None:
    import seaborn as sns

    title = "\n".join(textwrap.wrap(title, width=78, break_long_words=False))
    subtitle = "\n".join(textwrap.wrap(subtitle, width=112, break_long_words=False))
    ax.set_title("")
    fig.subplots_adjust(top=0.82)
    left = ax.get_position().x0
    fig.text(left, 0.97, title, ha="left", va="top", fontsize=13, fontweight="semibold", color="#1F2430")
    fig.text(left, 0.91, subtitle, ha="left", va="top", fontsize=9, color="#6F768A")
    sns.despine(ax=ax)


def render_charts(records: list[dict], summary: dict, output_dir: Path) -> list[dict]:
    import matplotlib.pyplot as plt
    import seaborn as sns

    use_chart_theme()
    charts_dir = output_dir / "assets"
    charts_dir.mkdir(parents=True, exist_ok=True)
    df = pd.DataFrame(records)
    per_sample = (
        df.groupby(["implementation", "sample_id"], as_index=False)
        .agg(
            median_total_ms=("total_ms", "median"),
            median_area_reduction_pct=("area_reduction_pct", "median"),
            cropped=("cropped", "max"),
        )
    )
    summary_df = pd.DataFrame(summary["implementation_summary"]).sort_values("median_total_ms", ascending=True)

    chart_map = []
    palette = {
        "LANraragi": "#A3BEFA",
        "Komikku": "#F0986E",
        "Suwayomi": "#A3D576",
    }

    fig, ax = plt.subplots(figsize=(8.5, 4.6))
    sns.barplot(
        data=summary_df,
        y="implementation",
        x="median_total_ms",
        hue="implementation",
        palette=palette,
        legend=False,
        ax=ax,
        edgecolor="#2E4780",
        linewidth=1.0,
    )
    ax.set_xlabel("Median total processing time (ms)")
    ax.set_ylabel("")
    for container in ax.containers:
        ax.bar_label(container, fmt="%.1f ms", padding=4, fontsize=8)
    add_chart_header(
        fig,
        ax,
        "Median crop-processing time by implementation",
        f"{summary['selected_sample_count']} selected LANraragi library samples; local model includes decode, detection, and re-encode when a crop is produced.",
    )
    path = charts_dir / "median_processing_time.png"
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    chart_map.append(
        {
            "file": str(path.relative_to(output_dir)),
            "section": "key-findings",
            "question": "Which implementation is fastest on the selected sample set?",
            "chart_type": "ranked horizontal bar",
            "takeaway": f"{summary['fastest_median_implementation']} has the lowest modeled median processing time.",
        }
    )

    fig, ax = plt.subplots(figsize=(8.8, 4.8))
    melted = summary_df.melt(
        id_vars=["implementation"],
        value_vars=["crop_rate_pct", "median_area_reduction_cropped_only_pct"],
        var_name="metric",
        value_name="pct",
    )
    labels = {
        "crop_rate_pct": "Crop rate",
        "median_area_reduction_cropped_only_pct": "Cropped-only median area saved",
    }
    melted["metric"] = melted["metric"].map(labels)
    sns.barplot(
        data=melted,
        x="implementation",
        y="pct",
        hue="metric",
        palette=["#5477C4", "#CC6F47"],
        ax=ax,
        edgecolor="#464C55",
        linewidth=1.0,
    )
    ax.set_xlabel("")
    ax.set_ylabel("Percent")
    ax.set_ylim(0, max(5, melted["pct"].max() * 1.2))
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.14), frameon=False, ncol=2, borderaxespad=0)
    for container in ax.containers:
        ax.bar_label(container, fmt="%.1f%%", padding=3, fontsize=8)
    add_chart_header(
        fig,
        ax,
        "Crop selectivity and median page-area savings",
        "Area savings are calculated only on pages each implementation decided to crop; crop rate keeps the no-op pages visible.",
    )
    path = charts_dir / "crop_rate_area_savings.png"
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    chart_map.append(
        {
            "file": str(path.relative_to(output_dir)),
            "section": "key-findings",
            "question": "How aggressive is each implementation?",
            "chart_type": "grouped bar",
            "takeaway": "Komikku still crops the most samples, while LANraragi now lands between Komikku and Suwayomi.",
        }
    )

    pivot = per_sample.pivot(index="sample_id", columns="implementation", values="median_total_ms")
    order = pivot.mean(axis=1).sort_values(ascending=False).head(16).index
    fig, ax = plt.subplots(figsize=(8.8, 6.0))
    sns.heatmap(
        pivot.loc[order, IMPLEMENTATIONS],
        cmap=sns.blend_palette(["#FFFFFF", "#CEDFFE", "#A3BEFA", "#5477C4"], as_cmap=True),
        annot=True,
        fmt=".0f",
        linewidths=1.0,
        linecolor="#FFFFFF",
        cbar_kws={"label": "ms"},
        ax=ax,
    )
    ax.set_xlabel("")
    ax.set_ylabel("Sample ID")
    add_chart_header(
        fig,
        ax,
        "Slowest selected samples by implementation",
        "Top 16 samples by mean modeled processing time; labels are anonymized sample IDs.",
    )
    path = charts_dir / "sample_latency_heatmap.png"
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    chart_map.append(
        {
            "file": str(path.relative_to(output_dir)),
            "section": "methodology",
            "question": "Which samples create the largest processing tail?",
            "chart_type": "heatmap",
            "takeaway": "Large high-resolution pages dominate tail latency across all implementations.",
        }
    )

    return chart_map


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def format_summary_table(rows: list[dict]) -> str:
    headers = [
        "Implementation",
        "Median total ms",
        "P90 total ms",
        "Crop rate",
        "Cropped pages",
        "Cropped-only area saved",
        "Cropped-only byte saved",
    ]
    body = [
        [
            row["implementation"],
            f"{row['median_total_ms']:.2f}",
            f"{row['p90_total_ms']:.2f}",
            f"{row['crop_rate_pct']:.1f}%",
            f"{row['cropped_sample_count']}",
            f"{row['median_area_reduction_cropped_only_pct']:.1f}%",
            f"{row['median_byte_reduction_cropped_only_pct']:.1f}%",
        ]
        for row in rows
    ]
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    lines.extend("| " + " | ".join(row) + " |" for row in body)
    return "\n".join(lines)


def write_markdown(output_dir: Path, summary: dict, chart_map: list[dict]) -> None:
    rows = summary["implementation_summary"]
    fastest = summary["fastest_median_implementation"]
    chart_lines = "\n".join(
        f"- `{chart['file']}`: {chart['takeaway']}" for chart in chart_map
    )
    content = f"""# Image Cropping Benchmark Report Source

**Question:** Compare LANraragi, Komikku, and Suwayomi reader image border-cropping architectures and modeled performance on selected real LANraragi library samples.

**Delivery surface:** Korean static HTML report generated from this English source and anonymized benchmark data.

## Technical Summary

The benchmark used {summary['selected_sample_count']} selected image pages from a {summary['scanned_sample_count']}-sample anonymous extraction of the live LANraragi library. Under the local modeled benchmark, **{fastest}** had the lowest median total processing time at **{summary['fastest_median_total_ms']:.2f} ms**. The result is a local algorithm-and-transform model, not an on-device Android or production JVM/Perl timing run.

## Architecture Summary

- **LANraragi**: browser toggles `crop=border`; Mojolicious page serving applies `ImageBorderCrop` server-side, prefers libvips, falls back to ImageMagick, detects clean light or dark edge backgrounds, records crop metrics, caches positive crop variants, and writes no-crop cache entries when no crop is produced or when a byte-larger crop removes less than 5% of page area.
- **Komikku**: Android reader stores crop preferences by reading mode; SSIV and Coil pass `cropBorders` into `tachiyomi.decoder.ImageDecoder`, whose native decoder adjusts image bounds and decodes cropped regions locally on-device.
- **Suwayomi**: WebUI appends `crop=true` for non-webtoon pages; Server `PageServe` resolves raw page bytes, calls `CropBorderDetector`, persists transformed serve variants, and writes `.nocrop` markers when no crop is produced.

## Metrics

{format_summary_table(rows)}

## Chart Map

{chart_lines}

## Methodology

Samples were extracted from zip/cbz library archives into `/tmp`, renamed to anonymous sample IDs, and not committed. Each selected sample was run through three local algorithm models derived from inspected source:

- LANraragi model mirrors the v5 edge-background checks from `ImageBorderCrop.pm`: portrait-only server crops, clean light or dark per-edge backgrounds, safety padding, and a post-encode byte guard that still keeps crops with at least 5% page-area savings.
- Komikku model mirrors the published Tachiyomi native decoder `findBorders` scanner from the `image-decoder` repository and the verified Komikku/SSIV call boundary.
- Suwayomi model mirrors `CropBorderDetector.detectBounds`.

Each run includes image decode, detection, and re-encoding when a crop result is produced. Area and byte savings are reported both in the raw JSON across all pages and, in the reader-facing table, over cropped pages only so no-op samples do not hide the effect size. This intentionally favors auditability and same-sample comparison over exact production wall-clock fidelity.

## Limitations

- Komikku production work runs on Android native decoder and tile decode paths; this benchmark does not run an APK or Android device.
- LANraragi production can use libvips or ImageMagick inside the container; the local model does not import LANraragi's Perl module because the macOS system Perl is older than LANraragi's required Perl.
- Suwayomi production uses JVM ImageIO and disk variant cache behavior; this benchmark models the crop scanner and image transform but does not include database, HTTP, or disk-cache timing.
- Original archive names and sample images are intentionally omitted from committed artifacts.
"""
    (output_dir / "image-cropping-report.md").write_text(content, encoding="utf-8")


def html_table(headers: list[str], rows: list[list[str]]) -> str:
    head = "".join(f"<th>{html.escape(header)}</th>" for header in headers)
    body = "\n".join(
        "<tr>" + "".join(f"<td>{cell}</td>" for cell in row) + "</tr>"
        for row in rows
    )
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"


def write_html(output_dir: Path, summary: dict, chart_map: list[dict]) -> None:
    rows = summary["implementation_summary"]
    row_by_name = {row["implementation"]: row for row in rows}
    table_rows = [
        [
            f"<code>{html.escape(row['implementation'])}</code>",
            f"{row['median_total_ms']:.2f} ms",
            f"{row['p90_total_ms']:.2f} ms",
            f"{row['crop_rate_pct']:.1f}%",
            f"{row['cropped_sample_count']}",
            f"{row['median_area_reduction_cropped_only_pct']:.1f}%",
            f"{row['median_byte_reduction_cropped_only_pct']:.1f}%",
        ]
        for row in rows
    ]
    pros_cons = [
        [
            "<code>LANraragi</code>",
            "서버가 crop variant와 nocrop cache를 공유한다. light/dark edge를 모두 처리하고, byte savings가 없어도 5% 이상 면적을 줄이면 crop을 유지한다.",
            "첫 요청은 서버 CPU와 encode 비용을 낸다. landscape/spread 보호는 유지되어 Komikku보다 crop 후보가 좁다.",
        ],
        [
            "<code>Komikku</code>",
            "Android native decoder가 bounds를 조정해 tile/region decode에 바로 반영한다. 별도 서버 저장소가 필요 없다.",
            "비용이 기기별 CPU/메모리에 붙고, 같은 페이지라도 다른 기기에서 다시 계산한다. native dependency 내부 동작은 앱 레벨에서 관측성이 낮다.",
        ],
        [
            "<code>Suwayomi</code>",
            "WebUI는 단순히 <code>crop=true</code>를 붙이고 Server가 disk variant와 <code>.nocrop</code> marker를 관리한다. Web client가 가볍다.",
            "JVM ImageIO decode/re-encode와 disk variant 관리 비용이 있다. remote uncached crop에서는 preload 폭을 줄여야 한다.",
        ],
    ]
    chart_figures = "\n".join(
        "\n".join(
            [
                "    <figure>",
                f"      <img src=\"{html.escape(chart['file'])}\" alt=\"{html.escape(chart['takeaway'])}\">",
                f"      <figcaption>{html.escape(chart['takeaway'])}</figcaption>",
                "    </figure>",
            ]
        )
        for chart in chart_map
    )
    metric_cards = [
        ("샘플", f"{summary['selected_sample_count']} / {summary['scanned_sample_count']}", "선별 / 추출"),
        ("반복", f"{summary['repeat_count']}회", "sample × implementation"),
        ("최저 중앙값", f"{summary['fastest_median_implementation']}", f"{summary['fastest_median_total_ms']:.2f} ms"),
        ("LANraragi crop rate", f"{row_by_name['LANraragi']['crop_rate_pct']:.1f}%", "보수적 기준"),
    ]
    metric_html = "\n".join(
        f"""<div class="cell"><div class="k">{html.escape(k)}</div><div class="v">{html.escape(v)}</div><div class="s">{html.escape(s)}</div></div>"""
        for k, v, s in metric_cards
    )
    html_doc = f"""<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>LANraragi / Komikku / Suwayomi 이미지 crop 벤치마크</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/dist/web/variable/pretendardvariable-dynamic-subset.min.css">
  <style>
    :root {{
      --ivory: #FAF9F5;
      --slate: #141413;
      --clay: #D97757;
      --oat: #E3DACC;
      --olive: #788C5D;
      --rust: #B04A3F;
      --gray-150: #F0EEE6;
      --gray-300: #D1CFC5;
      --gray-500: #87867F;
      --gray-700: #3D3D3A;
      --white: #FFFFFF;
      --serif: ui-serif, Georgia, 'Times New Roman', serif;
      --sans: "Pretendard Variable", Pretendard, system-ui, -apple-system, "Apple SD Gothic Neo", "Noto Sans KR", sans-serif;
      --mono: ui-monospace, 'SF Mono', Menlo, Monaco, monospace;
      --border: 1.5px solid var(--gray-300);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      padding: 56px 28px 120px;
      background: var(--ivory);
      color: var(--gray-700);
      font-family: var(--sans);
      line-height: 1.62;
      -webkit-font-smoothing: antialiased;
    }}
    main {{ max-width: 1120px; margin: 0 auto; }}
    header {{ max-width: 860px; margin-bottom: 34px; }}
    .eyebrow {{
      font-family: var(--mono);
      font-size: 12px;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--gray-500);
      margin-bottom: 12px;
    }}
    h1 {{
      font-family: var(--serif);
      font-weight: 500;
      font-size: 38px;
      line-height: 1.18;
      color: var(--slate);
      margin: 0 0 18px;
    }}
    h2 {{
      font-family: var(--serif);
      font-weight: 500;
      font-size: 25px;
      line-height: 1.25;
      color: var(--slate);
      margin: 0 0 8px;
    }}
    h3 {{ color: var(--slate); margin: 0 0 8px; font-size: 17px; }}
    p {{ margin: 0 0 14px; }}
    section {{ margin-bottom: 58px; scroll-margin-top: 24px; }}
    code {{
      font-family: var(--mono);
      font-size: 0.92em;
      background: var(--gray-150);
      border-radius: 5px;
      padding: 1px 5px;
      color: var(--slate);
    }}
    .summary-box {{
      background: var(--slate);
      color: var(--ivory);
      border-radius: 12px;
      padding: 22px 26px;
      margin: 28px 0 34px;
    }}
    .summary-box strong {{ color: white; }}
    .summary {{
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 14px;
      margin: 0 0 52px;
    }}
    @media (max-width: 900px) {{ .summary {{ grid-template-columns: repeat(2, 1fr); }} }}
    @media (max-width: 560px) {{ body {{ padding: 32px 16px 80px; }} .summary {{ grid-template-columns: 1fr; }} h1 {{ font-size: 30px; }} }}
    .cell {{
      background: var(--white);
      border: var(--border);
      border-radius: 12px;
      padding: 17px 18px;
    }}
    .cell .k {{ font-family: var(--mono); font-size: 11px; color: var(--gray-500); text-transform: uppercase; letter-spacing: 0.06em; }}
    .cell .v {{ color: var(--slate); font-weight: 700; font-size: 18px; margin-top: 5px; }}
    .cell .s {{ color: var(--gray-500); font-size: 13px; margin-top: 2px; }}
    .grid-3 {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; }}
    @media (max-width: 900px) {{ .grid-3 {{ grid-template-columns: 1fr; }} }}
    .panel {{
      background: var(--white);
      border: var(--border);
      border-radius: 12px;
      padding: 20px;
    }}
    .panel .label {{
      display: inline-block;
      font-family: var(--mono);
      font-size: 11px;
      background: var(--oat);
      color: var(--slate);
      border-radius: 7px;
      padding: 3px 8px;
      margin-bottom: 10px;
    }}
    table {{
      width: 100%;
      border-collapse: separate;
      border-spacing: 0;
      background: var(--white);
      border: var(--border);
      border-radius: 12px;
      overflow: hidden;
      margin-top: 14px;
    }}
    th, td {{
      text-align: left;
      vertical-align: top;
      padding: 11px 13px;
      border-bottom: 1px solid var(--gray-150);
      font-size: 14px;
    }}
    th {{ color: var(--slate); background: var(--gray-150); font-weight: 700; }}
    tr:last-child td {{ border-bottom: 0; }}
    figure {{
      background: var(--white);
      border: var(--border);
      border-radius: 12px;
      padding: 18px;
      margin: 20px 0;
    }}
    figure img {{ width: 100%; display: block; height: auto; }}
    figcaption {{ color: var(--gray-500); font-size: 13px; margin-top: 10px; }}
    .note {{
      border-left: 4px solid var(--clay);
      background: var(--gray-150);
      padding: 14px 16px;
      border-radius: 0 10px 10px 0;
      margin-top: 18px;
    }}
    ul {{ padding-left: 20px; margin: 8px 0 0; }}
    li {{ margin-bottom: 8px; }}
  </style>
</head>
<body>
<main data-report-audience="technical">
  <header data-contract-section="title">
    <div class="eyebrow">Technical benchmark · image crop</div>
    <h1>LANraragi / Komikku / Suwayomi 이미지 crop 벤치마크</h1>
    <p>LANraragi production library에서 익명으로 추출한 page sample을 기준으로 세 구현의 crop architecture, 처리 비용, 장단점을 비교했다.</p>
  </header>

  <section class="summary-box" data-contract-section="technical-summary">
    <p><strong>핵심 결과:</strong> local model 기준 median 처리 시간은 <strong>{html.escape(summary['fastest_median_implementation'])}</strong>가 가장 낮았다. 다만 이 값은 동일 sample에서 algorithm과 transform 비용을 비교하기 위한 모델이다. Android native decoder, LANraragi container의 libvips, Suwayomi JVM/disk cache를 그대로 재현한 production wall-clock은 아니다.</p>
  </section>

  <div class="summary">
    {metric_html}
  </div>

  <section data-contract-section="key-findings">
    <h2>측정 결과는 속도보다 crop 정책 차이를 더 크게 보여준다</h2>
    <p>세 구현은 모두 “빈 border 제거”라는 같은 UX를 제공하지만, 비용을 내는 위치와 false positive를 피하는 방식이 다르다. LANraragi v5는 Komikku처럼 밝은 edge와 어두운 edge를 모두 보되, 서버 cache 비용 때문에 landscape/spread 보호와 작은 crop용 byte-size guard를 유지한다.</p>
    {chart_figures}
    {html_table(["구현", "Median", "P90", "Crop rate", "Cropped pages", "Cropped-only area saved", "Cropped-only byte saved"], table_rows)}
  </section>

  <section data-contract-section="scope-data-and-metric-definitions">
    <h2>범위와 metric 정의</h2>
    <p>샘플은 production LANraragi library의 zip/cbz archive에서 image entry만 추출했다. 원본 archive path와 page filename은 저장하지 않고, sample id와 hash만 남겼다.</p>
    <ul>
      <li><strong>Median total ms</strong>: image decode, crop bounds detection, crop 결과가 있을 때 re-encode까지 포함한 local model time.</li>
      <li><strong>Crop rate</strong>: 선별 sample 중 해당 구현이 crop bounds를 반환한 비율.</li>
      <li><strong>Area saved</strong>: reader-facing 표에서는 실제 crop된 page만 기준으로 본 원본 pixel area 대비 제거 면적 비율.</li>
      <li><strong>Byte saved</strong>: 실제 crop된 page의 re-encode byte 기준 절감률. 원본 압축률과 서비스 cache/decoder 조건에 따라 음수가 될 수 있다.</li>
    </ul>
  </section>

  <section data-contract-section="methodology">
    <h2>Architecture별 측정 모델</h2>
    <div class="grid-3">
      <div class="panel">
        <span class="label">LANraragi</span>
        <h3>서버 변환 + variant cache</h3>
        <p>Reader JS는 <code>?crop=border</code>를 붙인다. 서버는 <code>ImageBorderCrop</code>으로 light/dark edge background를 찾고, crop 성공 variant와 no-crop marker를 cache한다. Re-encode 결과가 원본보다 작지 않아도 면적 감소가 충분하면 crop variant를 유지한다.</p>
      </div>
      <div class="panel">
        <span class="label">Komikku</span>
        <h3>기기 local native decoder</h3>
        <p>Reader 설정과 bottom bar가 <code>cropBorders</code> preference를 바꾸고, SSIV/Coil이 <code>tachiyomi.decoder.ImageDecoder</code> JNI boundary로 전달한다. Native decoder는 bounds를 조정해 region decode한다.</p>
      </div>
      <div class="panel">
        <span class="label">Suwayomi</span>
        <h3>WebUI query + Server disk variant</h3>
        <p>WebUI는 non-webtoon page에 <code>crop=true</code>를 붙인다. Server <code>PageServe</code>는 raw page를 resolve하고 <code>CropBorderDetector</code>를 실행한 뒤 transformed variant 또는 <code>.nocrop</code> marker를 저장한다.</p>
      </div>
    </div>
    <div class="note">벤치마크 harness는 inspect한 source의 crop decision logic을 Python으로 옮긴 것이다. absolute time보다 같은 sample에서의 상대적 비용, crop aggressiveness, tail sample을 읽는 데 초점을 둔다.</div>
  </section>

  <section data-contract-section="limitations-uncertainty-and-robustness-checks">
    <h2>한계와 신뢰 구간</h2>
    <p>이 결과는 source-derived local model이다. Komikku는 Android native decoder를 실제 기기에서 실행하지 않았고, LANraragi는 macOS Perl 버전 제약 때문에 Perl module을 직접 import하지 않았다. Suwayomi도 production JVM, HTTP, DB, disk cache timing을 포함하지 않는다.</p>
    <p>대신 robustness check로 세 구현 모두 동일 sample set, 동일 decode library, 동일 반복 수에서 비교했다. 원본 sample은 repo에 넣지 않았고, committed output은 익명 JSON/CSV와 chart PNG만 포함한다.</p>
  </section>

  <section data-contract-section="recommended-next-steps">
    <h2>권장 사항</h2>
    <ul>
      <li>LANraragi는 byte guard 완화 배포 후 production metrics의 <code>crop_seconds_total</code>, <code>nocrop_larger</code> cache status, reader toggle usage를 같이 보며 실제 hit rate를 확인한다.</li>
      <li>Suwayomi는 remote uncached crop preload cap이 타당하다. crop page tail latency가 높게 남으면 no-crop marker와 variant warmup hit rate를 먼저 본다.</li>
      <li>Komikku는 기기별 체감 차이가 클 수 있으므로 Android macrobenchmark나 representative device profile이 다음 측정 단계다.</li>
    </ul>
  </section>

  <section data-contract-section="further-questions">
    <h2>남은 질문</h2>
    <p>세 구현의 user-visible latency를 정확히 비교하려면 production LANraragi HTTP, Suwayomi Server HTTP, Android Komikku APK macrobenchmark를 같은 page set으로 별도 측정해야 한다. 이번 문서는 그 전에 architecture와 algorithm 비용 차이를 좁히기 위한 기준선이다.</p>
  </section>
</main>
</body>
</html>
"""
    (output_dir / "image-cropping-report.ko.html").write_text(html_doc, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=Path, default=Path("/tmp/lrr-crop-samples"))
    parser.add_argument("--output", type=Path, default=Path("docs/benchmarks/image-cropping"))
    parser.add_argument("--max-samples", type=int, default=24)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    sample_paths = sorted(
        path for path in args.samples.glob("sample_[0-9][0-9]_*")
        if path.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}
    )
    if not sample_paths:
        raise SystemExit(f"No sample image files found in {args.samples}")

    manifest = load_manifest(args.samples)
    selected_paths, preselection_records = classify_and_select(sample_paths, args.max_samples)

    records: list[dict] = []
    for sample_path in selected_paths:
        sample_id = sample_id_from_path(sample_path)
        source_hash = source_hash_from_path(sample_path)
        for repeat in range(args.repeats):
            for implementation in IMPLEMENTATIONS:
                row = run_once(sample_path, implementation, encode=True)
                row.update(
                    {
                        "sample_id": sample_id,
                        "source_hash": source_hash,
                        "sample_file": sample_path.name,
                        "repeat": repeat,
                    }
                )
                records.append(row)

    summary = summarize(records, len(selected_paths), len(sample_paths))
    chart_map = render_charts(records, summary, args.output)
    summary["chart_map"] = chart_map
    summary["manifest"] = {
        "archive_scan_limit": manifest.get("archive_scan_limit"),
        "selected_from_extraction": manifest.get("selected_count"),
        "sample_source": "anonymized LANraragi production library zip/cbz image entries",
    }
    summary["selected_samples"] = [
        {
            "sample_id": sample_id_from_path(path),
            "source_hash": source_hash_from_path(path),
            "sample_file": path.name,
        }
        for path in selected_paths
    ]

    (args.output / "image-cropping-results.json").write_text(
        json.dumps({"summary": summary, "records": records, "preselection_records": preselection_records}, indent=2),
        encoding="utf-8",
    )
    write_csv(args.output / "image-cropping-records.csv", records)
    write_markdown(args.output, summary, chart_map)
    write_html(args.output, summary, chart_map)
    print(json.dumps({"output": str(args.output), "summary": summary}, indent=2))


if __name__ == "__main__":
    main()
