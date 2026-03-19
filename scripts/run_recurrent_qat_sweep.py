#!/usr/bin/env python3
from __future__ import annotations

import argparse
import itertools
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOGS_DIR = ROOT / "logs"
SWEEPS_DIR = ROOT / "sweeps"

FINAL_RE = re.compile(r"^final_int8_zlib_roundtrip_exact val_loss:(?P<loss>\S+) val_bpb:(?P<bpb>\S+)$")
VAL_RE = re.compile(r"^step:(?P<step>\d+)/(?P<iterations>\d+) val_loss:(?P<loss>\S+) val_bpb:(?P<bpb>\S+).*$")
SIZE_RE = re.compile(r"^Total submission size int8\+zlib: (?P<bytes>\d+) bytes$")
PARAMS_RE = re.compile(r"^model_params:(?P<params>\d+)$")
STOP_RE = re.compile(r"^stopping_early: wallclock_cap train_time:(?P<ms>\d+)ms step:(?P<step>\d+)/(?P<iterations>\d+)$")


@dataclass
class RunSummary:
    run_id: str
    log_path: str
    num_layers: int
    num_unique_blocks: int
    block_share_strategy: str
    qat_enable: bool
    qat_start_fraction: float
    final_val_bpb: float | None
    final_val_loss: float | None
    best_prequant_val_bpb: float | None
    best_prequant_val_loss: float | None
    total_submission_size_bytes: int | None
    model_params: int | None
    stop_step: int | None
    iterations: int | None
    wallclock_ms: int | None


def comma_values(raw: str) -> list[str]:
    return [value.strip() for value in raw.split(",") if value.strip()]


def parse_int_list(raw: str) -> list[int]:
    return [int(value) for value in comma_values(raw)]


def parse_float_list(raw: str) -> list[float]:
    return [float(value) for value in comma_values(raw)]


def sanitize_fraction(value: float) -> str:
    return str(value).replace(".", "p")


def parse_key_value(items: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            raise ValueError(f"Expected KEY=VALUE, got {item!r}")
        key, value = item.split("=", 1)
        out[key] = value
    return out


def has_final_metrics(log_path: Path) -> bool:
    if not log_path.is_file():
        return False
    text = log_path.read_text(encoding="utf-8")
    return FINAL_RE.search(text) is not None


def parse_log(log_path: Path, *, num_layers: int, num_unique_blocks: int, block_share_strategy: str, qat_enable: bool, qat_start_fraction: float) -> RunSummary:
    final_loss = None
    final_bpb = None
    best_prequant_loss = None
    best_prequant_bpb = None
    total_submission_size_bytes = None
    model_params = None
    stop_step = None
    iterations = None
    wallclock_ms = None

    for line in log_path.read_text(encoding="utf-8").splitlines():
        if final_match := FINAL_RE.match(line):
            final_loss = float(final_match.group("loss"))
            final_bpb = float(final_match.group("bpb"))
            continue
        if val_match := VAL_RE.match(line):
            bpb = float(val_match.group("bpb"))
            loss = float(val_match.group("loss"))
            if best_prequant_bpb is None or bpb < best_prequant_bpb:
                best_prequant_bpb = bpb
                best_prequant_loss = loss
            continue
        if size_match := SIZE_RE.match(line):
            total_submission_size_bytes = int(size_match.group("bytes"))
            continue
        if params_match := PARAMS_RE.match(line):
            model_params = int(params_match.group("params"))
            continue
        if stop_match := STOP_RE.match(line):
            stop_step = int(stop_match.group("step"))
            iterations = int(stop_match.group("iterations"))
            wallclock_ms = int(stop_match.group("ms"))
            continue

    return RunSummary(
        run_id=log_path.stem,
        log_path=str(log_path),
        num_layers=num_layers,
        num_unique_blocks=num_unique_blocks,
        block_share_strategy=block_share_strategy,
        qat_enable=qat_enable,
        qat_start_fraction=qat_start_fraction,
        final_val_bpb=final_bpb,
        final_val_loss=final_loss,
        best_prequant_val_bpb=best_prequant_bpb,
        best_prequant_val_loss=best_prequant_loss,
        total_submission_size_bytes=total_submission_size_bytes,
        model_params=model_params,
        stop_step=stop_step,
        iterations=iterations,
        wallclock_ms=wallclock_ms,
    )


def format_summary_table(rows: list[RunSummary]) -> str:
    headers = [
        "run_id",
        "final_bpb",
        "best_pre_bpb",
        "size_bytes",
        "params",
        "unique_blocks",
        "share",
        "qat_frac",
        "stop_step",
    ]
    lines = ["\t".join(headers)]
    for row in sorted(
        rows,
        key=lambda item: (
            float("inf") if item.final_val_bpb is None else item.final_val_bpb,
            float("inf") if item.best_prequant_val_bpb is None else item.best_prequant_val_bpb,
            item.run_id,
        ),
    ):
        lines.append(
            "\t".join(
                [
                    row.run_id,
                    "" if row.final_val_bpb is None else f"{row.final_val_bpb:.6f}",
                    "" if row.best_prequant_val_bpb is None else f"{row.best_prequant_val_bpb:.6f}",
                    "" if row.total_submission_size_bytes is None else str(row.total_submission_size_bytes),
                    "" if row.model_params is None else str(row.model_params),
                    str(row.num_unique_blocks),
                    row.block_share_strategy,
                    f"{row.qat_start_fraction:.3f}",
                    "" if row.stop_step is None else str(row.stop_step),
                ]
            )
        )
    return "\n".join(lines) + "\n"


def build_run_env(base_env: dict[str, str], args: argparse.Namespace, *, run_id: str, num_unique_blocks: int, block_share_strategy: str, qat_start_fraction: float) -> dict[str, str]:
    env = dict(base_env)
    env.update(
        {
            "RUN_ID": run_id,
            "DATA_PATH": args.data_path,
            "TOKENIZER_PATH": args.tokenizer_path,
            "VOCAB_SIZE": str(args.vocab_size),
            "NUM_LAYERS": str(args.num_layers),
            "NUM_UNIQUE_BLOCKS": str(num_unique_blocks),
            "BLOCK_SHARE_STRATEGY": block_share_strategy,
            "QAT_ENABLE": "1",
            "QAT_START_FRACTION": str(qat_start_fraction),
            "MODEL_DIM": str(args.model_dim),
            "NUM_HEADS": str(args.num_heads),
            "NUM_KV_HEADS": str(args.num_kv_heads),
            "MLP_MULT": str(args.mlp_mult),
            "TRAIN_BATCH_TOKENS": str(args.train_batch_tokens),
            "TRAIN_SEQ_LEN": str(args.train_seq_len),
            "ITERATIONS": str(args.iterations),
            "WARMUP_STEPS": str(args.warmup_steps),
            "MAX_WALLCLOCK_SECONDS": str(args.max_wallclock_seconds),
            "TRAIN_LOG_EVERY": str(args.train_log_every),
            "VAL_LOSS_EVERY": str(args.val_loss_every),
            "TORCH_COMPILE": "1" if args.torch_compile else "0",
        }
    )
    env.update(args.extra_env)
    return env


def run_sweep(args: argparse.Namespace) -> int:
    sweep_id = args.sweep_id or time.strftime("recurrent_qat_%Y%m%d_%H%M%S")
    sweep_dir = SWEEPS_DIR / sweep_id
    sweep_dir.mkdir(parents=True, exist_ok=True)
    summary_jsonl = sweep_dir / "summary.jsonl"
    leaderboard_tsv = sweep_dir / "leaderboard.tsv"
    manifest_path = sweep_dir / "manifest.json"
    LOGS_DIR.mkdir(parents=True, exist_ok=True)

    manifest = {
        "sweep_id": sweep_id,
        "created_at_unix": time.time(),
        "grid": {
            "num_unique_blocks": args.num_unique_blocks,
            "block_share_strategy": args.block_share_strategy,
            "qat_start_fraction": args.qat_start_fraction,
        },
        "base_args": {
            "nproc_per_node": args.nproc_per_node,
            "num_layers": args.num_layers,
            "model_dim": args.model_dim,
            "num_heads": args.num_heads,
            "num_kv_heads": args.num_kv_heads,
            "mlp_mult": args.mlp_mult,
            "train_batch_tokens": args.train_batch_tokens,
            "train_seq_len": args.train_seq_len,
            "iterations": args.iterations,
            "max_wallclock_seconds": args.max_wallclock_seconds,
            "torch_compile": args.torch_compile,
        },
        "extra_env": args.extra_env,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    completed: list[RunSummary] = []
    grid = list(itertools.product(args.num_unique_blocks, args.block_share_strategy, args.qat_start_fraction))
    for num_unique_blocks, block_share_strategy, qat_start_fraction in grid:
        run_id = f"{sweep_id}_u{num_unique_blocks}_{block_share_strategy}_q{sanitize_fraction(qat_start_fraction)}"
        log_path = LOGS_DIR / f"{run_id}.txt"
        if args.resume and has_final_metrics(log_path):
            summary = parse_log(
                log_path,
                num_layers=args.num_layers,
                num_unique_blocks=num_unique_blocks,
                block_share_strategy=block_share_strategy,
                qat_enable=True,
                qat_start_fraction=qat_start_fraction,
            )
            completed.append(summary)
            continue

        env = build_run_env(
            os.environ,
            args,
            run_id=run_id,
            num_unique_blocks=num_unique_blocks,
            block_share_strategy=block_share_strategy,
            qat_start_fraction=qat_start_fraction,
        )
        cmd = [
            sys.executable,
            "-m",
            "torch.distributed.run",
            "--standalone",
            f"--nproc_per_node={args.nproc_per_node}",
            str(ROOT / "train_gpt.py"),
        ]
        print("RUN", run_id)
        print("CMD", " ".join(cmd))
        if args.dry_run:
            continue
        subprocess.run(cmd, cwd=ROOT, env=env, check=True)
        summary = parse_log(
            log_path,
            num_layers=args.num_layers,
            num_unique_blocks=num_unique_blocks,
            block_share_strategy=block_share_strategy,
            qat_enable=True,
            qat_start_fraction=qat_start_fraction,
        )
        completed.append(summary)
        with summary_jsonl.open("a", encoding="utf-8") as f:
            f.write(json.dumps(asdict(summary), sort_keys=True) + "\n")
        leaderboard_tsv.write_text(format_summary_table(completed), encoding="utf-8")

    if completed:
        leaderboard_tsv.write_text(format_summary_table(completed), encoding="utf-8")
        print(format_summary_table(completed), end="")
    return 0


def summarize_logs(args: argparse.Namespace) -> int:
    rows: list[RunSummary] = []
    for log_path in sorted(Path(args.logs_dir).glob(args.pattern)):
        stem = log_path.stem
        match = re.search(r"_u(?P<u>\d+)_(?P<s>cycle|grouped)_q(?P<q>[0-9p]+)$", stem)
        if match is None:
            continue
        rows.append(
            parse_log(
                log_path,
                num_layers=args.num_layers,
                num_unique_blocks=int(match.group("u")),
                block_share_strategy=match.group("s"),
                qat_enable=True,
                qat_start_fraction=float(match.group("q").replace("p", ".")),
            )
        )
    table = format_summary_table(rows)
    print(table, end="")
    if args.output:
        Path(args.output).write_text(table, encoding="utf-8")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Launch and summarize recurrent/QAT sweeps for train_gpt.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="Launch a sweep sequentially")
    run_parser.add_argument("--sweep-id", default="")
    run_parser.add_argument("--data-path", required=True)
    run_parser.add_argument("--tokenizer-path", required=True)
    run_parser.add_argument("--vocab-size", type=int, required=True)
    run_parser.add_argument("--nproc-per-node", type=int, default=8)
    run_parser.add_argument("--num-layers", type=int, default=9)
    run_parser.add_argument("--model-dim", type=int, default=512)
    run_parser.add_argument("--num-heads", type=int, default=8)
    run_parser.add_argument("--num-kv-heads", type=int, default=4)
    run_parser.add_argument("--mlp-mult", type=int, default=2)
    run_parser.add_argument("--train-batch-tokens", type=int, default=524288)
    run_parser.add_argument("--train-seq-len", type=int, default=1024)
    run_parser.add_argument("--iterations", type=int, default=20000)
    run_parser.add_argument("--warmup-steps", type=int, default=20)
    run_parser.add_argument("--max-wallclock-seconds", type=float, default=600.0)
    run_parser.add_argument("--train-log-every", type=int, default=50)
    run_parser.add_argument("--val-loss-every", type=int, default=200)
    run_parser.add_argument("--num-unique-blocks", type=parse_int_list, default=parse_int_list("2,3,4,6,9"))
    run_parser.add_argument("--block-share-strategy", type=comma_values, default=comma_values("cycle,grouped"))
    run_parser.add_argument("--qat-start-fraction", type=parse_float_list, default=parse_float_list("0.5,0.7,0.8,0.9"))
    run_parser.add_argument("--extra-env", action="append", default=[], metavar="KEY=VALUE")
    run_parser.add_argument("--resume", action="store_true")
    run_parser.add_argument("--dry-run", action="store_true")
    run_parser.add_argument("--torch-compile", action="store_true", default=False)

    summarize_parser = subparsers.add_parser("summarize", help="Summarize existing sweep logs")
    summarize_parser.add_argument("--logs-dir", default=str(LOGS_DIR))
    summarize_parser.add_argument("--pattern", default="recurrent_qat_*.txt")
    summarize_parser.add_argument("--num-layers", type=int, default=9)
    summarize_parser.add_argument("--output", default="")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.command == "run":
        args.extra_env = parse_key_value(args.extra_env)
        return run_sweep(args)
    if args.command == "summarize":
        return summarize_logs(args)
    parser.error(f"Unsupported command {args.command!r}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
