"""python -m eval.judge {prepare,collect,report} <run_dir>

prepare : verify test data, build judge_inputs.jsonl (+ preview). Sends nothing anywhere.
collect : parse judge/raw/<input_id>.txt into ai_scores.jsonl.
report  : write judge_report.md and review_queue.csv.
Exit codes: 0 ok, 2 data/config problem (processing stopped).
"""
import argparse
import sys
from pathlib import Path

from eval.judge import collect as collect_mod
from eval.judge import prepare as prepare_mod
from eval.judge import report as report_mod


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="eval.judge")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("prepare", "collect", "report"):
        s = sub.add_parser(name)
        s.add_argument("run_dir")
        s.add_argument("--judge-dir", default=None, help="default: <run_dir>/judge")
    sub.choices["prepare"].add_argument("--limit", type=int, default=None)
    sub.choices["prepare"].add_argument("--force", action="store_true")
    args = p.parse_args(argv)
    run_dir = Path(args.run_dir)
    judge_dir = Path(args.judge_dir) if args.judge_dir else run_dir / "judge"
    try:
        if args.cmd == "prepare":
            if args.limit is not None and args.limit < 1:
                print("--limit は1以上を指定してください")
                return 2
            inputs, key, selected = prepare_mod.build_inputs(run_dir, args.limit)
            print(prepare_mod.render_preview(inputs, selected))
            prepare_mod.write_inputs(judge_dir, inputs, key, args.force, prepare_mod.run_id_of(run_dir))
            print(f"\n書き出し: {judge_dir}/judge_inputs.jsonl, judge_key.json, judge_meta.json（モデル名は含まない）")
        elif args.cmd == "collect":
            print(collect_mod.collect(judge_dir, run_dir))
        else:
            res = report_mod.build(judge_dir, run_dir)
            print(f"出力: {judge_dir}/judge_report.md, review_queue.csv（{res['review_rows']}行）")
    except (prepare_mod.JudgeDataError, OSError, ValueError, KeyError) as e:
        print(f"停止: {type(e).__name__}: {e}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
