# Phantom Strategy Migration Checklist (Repo-to-Repo)

Purpose: move the working Phantom Vantage strategy stack from this repo into a new repo with minimal drift.

## 1. Required Programs and Tooling

Copying files is not enough. The target machine also needs:

- Git
- Python 3.10+ (same minor version as current environment is preferred)
- pip + virtual environment tooling
- MetaTrader 5 (Terminal + MetaEditor)
- Wine (macOS/Linux deployments that run MT5 under Wine)
- Node.js + npm (required if you also migrate the dashboard/API workflows)
- Optional but recommended: VS Code + MQL tools extension for compile and syntax workflows

Python runtime packages required by live strategy execution:

- pandas
- numpy
- pytz (used by strategy logic when available)

For detached background execution on macOS (terminal-independent):

- launchd (user LaunchAgents)

## 2. Core Strategy Code (Must Copy)

Live strategy engine and bridge stack:

- [phantom/copy_for_live/Phantom_Vantage/PhantomEA_Vantage.py](../phantom/copy_for_live/Phantom_Vantage/PhantomEA_Vantage.py)
- [phantom/copy_for_live/Phantom_Vantage/phantom_live_daemon.py](../phantom/copy_for_live/Phantom_Vantage/phantom_live_daemon.py)
- [phantom/copy_for_live/Phantom_Vantage/PhantomBridge_Vantage.mq5](../phantom/copy_for_live/Phantom_Vantage/PhantomBridge_Vantage.mq5)
- [phantom/copy_for_live/Phantom_Vantage/PhantomBarWriter.mq5](../phantom/copy_for_live/Phantom_Vantage/PhantomBarWriter.mq5)
- [phantom/copy_for_live/Phantom_Vantage/PhantomVisual.mq5](../phantom/copy_for_live/Phantom_Vantage/PhantomVisual.mq5) (optional but useful for chart-side diagnostics)

Bundle policy and provenance notes:

- [phantom/copy_for_live/README.md](../phantom/copy_for_live/README.md)

## 3. Signal and Runtime State Files

Strategy consumes/produces JSONL signals. Seed these in the new repo:

- [phantom/copy_for_live/Phantom_Vantage/signals_vantage_live.jsonl](../phantom/copy_for_live/Phantom_Vantage/signals_vantage_live.jsonl)
- [phantom/copy_for_live/Phantom_Vantage/signals_vantage_live.jsonl.fps](../phantom/copy_for_live/Phantom_Vantage/signals_vantage_live.jsonl.fps)
- [signals/signals_vantage.jsonl](../signals/signals_vantage.jsonl) (if you also run non-live generation flows)

Optional archived/reference signal artifacts (copy if you need historical reproducibility):

- [signals/phantom_signals.jsonl](../signals/phantom_signals.jsonl)
- [signals/phantom_signals_a3c0f7e_10676.jsonl](../signals/phantom_signals_a3c0f7e_10676.jsonl)

Important: MT5 runtime state under Common/Files (for example phantom_state_<login>.json) is environment-local and should not be committed into the new repo.

## 4. MT5 Sync/Compile Automation (Must Copy)

These scripts and task definitions are needed to keep MQL source and EX5 deployment in sync:

- [scripts/sync_mt5_ea.sh](../scripts/sync_mt5_ea.sh)
- [.vscode/scripts/compile_mq5.sh](../.vscode/scripts/compile_mq5.sh)
- [.vscode/scripts/compile_mq5_poll.sh](../.vscode/scripts/compile_mq5_poll.sh) (optional helper)
- [.vscode/scripts/compile_mq5_robust.sh](../.vscode/scripts/compile_mq5_robust.sh) (optional helper)
- [.vscode/tasks.json](../.vscode/tasks.json)

Export collection helper (recommended):

- [scripts/copy_mt5_exports.sh](../scripts/copy_mt5_exports.sh)

Launchd runtime sync helper (recommended when using detached daemon on macOS):

- [scripts/sync_launchd_runtime.sh](../scripts/sync_launchd_runtime.sh)

## 5. Repo Config and Project Metadata (Recommended)

Minimum repo hygiene and deployment/docs context:

- [.gitignore](../.gitignore)
- [README.md](../README.md)
- [DEPLOYMENT_CHECKLIST.md](../DEPLOYMENT_CHECKLIST.md)
- [TIMEZONE_FIX_IMPLEMENTATION.md](../TIMEZONE_FIX_IMPLEMENTATION.md)
- [TIMEZONE_FIX_COMPLETE.md](../TIMEZONE_FIX_COMPLETE.md)
- [TIMEZONE_FIX_VALIDATION.md](../TIMEZONE_FIX_VALIDATION.md)

## 6. If You Also Migrate the API/Dashboard Side

Copy these if the new repo should keep comparative reports, strategy lab, or backend endpoints:

- [package.json](../package.json)
- [package-lock.json](../package-lock.json)
- [tsconfig.json](../tsconfig.json)
- [jest.config.js](../jest.config.js)
- [nodemon.json](../nodemon.json)
- [.eslintrc.js](../.eslintrc.js)
- [render.yaml](../render.yaml)
- [src](../src)
- [public](../public)
- [config](../config)
  - [config/phantom-strategy-registry.json](../config/phantom-strategy-registry.json)
  - [config/comparative-reports.json](../config/comparative-reports.json)
  - [config/dataset-symbol-aliases.json](../config/dataset-symbol-aliases.json)

## 7. Data Inputs Required at Runtime

Live daemon requires seven timeframe CSV feeds per instrument:

- M1
- M5
- M15
- H1
- H4
- Daily
- Weekly

These are passed by CLI to [phantom/copy_for_live/Phantom_Vantage/phantom_live_daemon.py](../phantom/copy_for_live/Phantom_Vantage/phantom_live_daemon.py).

## 8. Environment and Settings to Recreate

Recreate these machine settings in the new repo environment:

- WINEPREFIX path pointing to the MT5 installation root
- MT5 Common/Files visibility for daemon file fan-out
- Broker symbol mapping consistency (US100 vs NAS100 variants)
- EA input settings for timezone offsets and risk mode
- Unique magic number per account/EA instance

If using terminal-independent daemon execution on macOS, also recreate:

- User LaunchAgent file at ~/Library/LaunchAgents/com.niko.phantom-live-daemon.plist
- Runtime mirror folder at ~/Library/Application Support/niko-ai-runtime
- Launchd stdout/stderr log paths under the runtime mirror

Important macOS note: LaunchAgents may not have permission to read scripts directly under Documents on some systems. The runtime mirror path under Application Support avoids this blocker.

If using VS Code MQL integration, port editor settings:

- [.vscode/settings.json](../.vscode/settings.json)
- [.vscode/c_cpp_properties.json](../.vscode/c_cpp_properties.json)
- [.vscode/keybindings.json](../.vscode/keybindings.json)

## 9. Recommended Copy Sets

### A) Minimal Live-Only Pack

- phantom/copy_for_live/Phantom_Vantage/*
- phantom/copy_for_live/Phantom_Vantage/signals_vantage_live.jsonl
- phantom/copy_for_live/Phantom_Vantage/signals_vantage_live.jsonl.fps
- scripts/sync_mt5_ea.sh
- scripts/sync_launchd_runtime.sh
- .vscode/scripts/compile_mq5.sh
- .vscode/tasks.json
- .gitignore
- README.md

### B) Full Development Parity Pack

- Everything in Minimal Live-Only Pack
- Full [phantom](../phantom) tree
- Full [signals](../signals) tree
- [scripts](../scripts)
- [config](../config)
- Node/TS project files listed in section 6
- Deployment and timezone docs listed in section 5

## 10. Post-Migration Validation (Do Not Skip)

1. Create venv and install Python deps.
2. Start daemon and verify initial write to signals_vantage_live.jsonl.
3. Compile and attach PhantomBridge_Vantage in MT5.
4. Confirm bridge log shows FILE_POLL activity and correct filepos progression.
5. Append one harmless probe close event and confirm CLOSE_NO_MAP + processed=1.
6. Confirm no recurring err=5004 in Experts/bridge logs.
7. If using launchd, confirm service state is running and daemon has no TTY attachment.

## 11. Items You Should Not Copy Blindly

- .venv
- node_modules
- dist
- logs generated on this machine
- MT5 Common/Files runtime state files (phantom_state_*.json)
- User-specific LaunchAgent files with absolute local paths (unless templatized for the new machine)

Those should be regenerated in the target environment.

## 12. Detached Daemon (macOS launchd) Migration Notes

Use this pattern when you want the daemon to keep running after closing Terminal.

Files and paths to carry over:

- Repo helper script: [scripts/sync_launchd_runtime.sh](../scripts/sync_launchd_runtime.sh)
- Strategy sources copied into runtime mirror:
  - phantom_live_daemon.py
  - PhantomEA_Vantage.py
- Machine-local LaunchAgent plist:
  - ~/Library/LaunchAgents/com.niko.phantom-live-daemon.plist

Runtime mirror layout expected by the service:

- ~/Library/Application Support/niko-ai-runtime/Phantom_Vantage
- ~/Library/Application Support/niko-ai-runtime/logs
- ~/Library/Application Support/niko-ai-runtime/signals
- ~/Library/Application Support/niko-ai-runtime/tmp

Operational flow after code changes:

1. Run scripts/sync_launchd_runtime.sh --restart
2. Validate launchd service is running.
3. Verify fresh daemon output in runtime mirror logs.