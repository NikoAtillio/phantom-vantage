#!/usr/bin/env python3
from __future__ import annotations

import pandas as pd

DBG = "/Users/niko/Documents/projects/phantom-vantage/.diagnostics/phantom_phantom_us100_v5_fund_debug_US100_PHANTOM_US100_V5_FUNDB.csv"
BASE_TOL = 0.002
TOLS = [0.0023, 0.0024, 0.0025]


def main() -> None:
    df = pd.read_csv(DBG)
    df["ts"] = pd.to_datetime(df["ts"])

    mask_tol = (
        (df["event"] == "zone_skip")
        & (df["reason"] == "tolerance")
        & (df["zone_dist"] > BASE_TOL)
    )

    print(f"Baseline tolerance skip rows (> {BASE_TOL:.4f}): {int(mask_tol.sum())}")

    for tol in TOLS:
        m = mask_tol & (df["zone_dist"] <= tol)
        print(f"\nTol {tol:.4f} additional passes over base: {int(m.sum())}")

        by_day = (
            df.loc[m]
            .assign(day=df.loc[m, "ts"].dt.date.astype(str))
            .groupby("day")
            .size()
            .sort_index()
        )
        if len(by_day):
            print("  by_day:", ", ".join(f"{k}:{v}" for k, v in by_day.items()))
        else:
            print("  by_day: none")

        w = (df["ts"] >= pd.Timestamp("2026-07-29 13:00:00")) & (
            df["ts"] <= pd.Timestamp("2026-07-29 16:00:00")
        )
        mw = m & w
        print(f"  Jul29 13:00-16:00 additional: {int(mw.sum())}")

        z = df.loc[mw, "zone_dir"].value_counts()
        if len(z):
            print(
                "  Jul29 13:00-16:00 by zone_dir:",
                ", ".join(f"{k}:{v}" for k, v in z.items()),
            )


if __name__ == "__main__":
    main()
