# copy_for_live

Purpose: immutable, run-labeled bundles for live deployment and reruns.

Folder naming convention (required):
- high_risk_US100_<YYYY-MM-DD>_<HHMMSS>

Signal naming convention (required):
- signals_<result_or_tag>_<event_count>.jsonl

Examples:
- high_risk_US100_2026-07-07_155407/signals_696k_10676.jsonl
- high_risk_US100_2026-07-08_101500/signals_v5fund_trial_11842.jsonl

Rules:
1. Never run MT5 from a generic signals/phantom_signals.jsonl without first copying a run-labeled file into place.
2. Keep signal + python + mql together in one profile folder.
3. Always write SHA256SUMS.txt after creating a bundle.
4. Preserve the signal meta header line (engine, instrument, account size) for provenance.
