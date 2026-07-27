# niko-ai
Niko.ai market pattern tracker

Raw instrument history lives in `data/`.
Active backtest inputs are stored under `uploads/datasets/` after import or registration.

## Deploy Live (Render)

This repo includes `render.yaml` for deployment.

1. Push this repo to GitHub.
2. In Render, choose **New +** -> **Blueprint** and connect the repo.
3. Render will detect `render.yaml` and create the `niko-ai` web service.
4. Wait for the first deploy to finish.
5. Open your live URL and visit:
	- `/comparative-reports`

### Notes

- The app uses a persistent disk mounted at `/var/data`.
- Mutable files (uploads, saved runs, backtest artifacts, comparative report registry) are stored under `NIKO_DATA_ROOT`.
- By default in Render this is set to `/var/data/niko-ai`, so data survives restarts/redeploys.
