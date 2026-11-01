# AGENTS.md

## Project overview

- scripts-de-moi: personal Debian server scripts (quota bot, CDT cost fuse, CDN IP selection, WARP upkeep, server setup). Human docs: [README.md](README.md).
- Type: collection repo (F). Sub-tools are CLI/timer scripts (A) plus one long-running bot (C).
- Runs on: Debian + systemd, as root. Stack: bash, Python 3 (cdt-guard: stdlib only; traffic-bot: venv with `python-telegram-bot[job-queue]`, `boto3`, `requests`, `oci`), `curl`, `jq`.
- The owner's interactive shell is fish; servers are administered as root.

## Commands

| Task | Command |
|---|---|
| cdt-guard tests (no deps, no network) | `python3 -m unittest discover CDT-Management/tests` |
| traffic-bot tests (needs bot deps) | `/opt/traffic-bot/venv/bin/python -m unittest discover traffic-bot/tests` |
| Syntax-check shell | `bash -n brutal-cn.sh cfst-ddns/cfst-ddns.sh warp-keeper/warp-keeper.sh upsing.sh debian-init.sh */install.sh */update.sh` |
| Syntax-check Python | `python3 -m py_compile traffic-bot/bot.py CDT-Management/cdt_guard.py` |
| Deploy on a server | `cd /opt/scripts-de-moi && git am -3 *.patch && rm *.patch && git push && ./update.sh` |
| Deployed vs repo versions | `./update.sh --status` |

No test venv? `python3 -m venv /tmp/v && /tmp/v/bin/pip install "python-telegram-bot[job-queue]" boto3 requests oci`.

## Repository map

- `traffic-bot/bot.py` — the whole bot. One `get_<provider>_data()` per source returns a `Section`; `PROVIDERS` lists them; `collect_sections()` runs them in threads with `PROVIDER_TIMEOUT_SEC`; `evaluate_alerts()` dedups alerts; `sonde_report()` builds the panel payload. The env template lives inside `traffic-bot/install.sh` (`write_env`, `ensure_line`).
- `CDT-Management/cdt_guard.py` — `check()` is the fuse logic; `rpc()` signs Aliyun RPC calls; `sonde_due()` throttles Sonde. `init.sh` installs and configures.
- `cfst-ddns/cfst-ddns.sh` — `do_check` / `do_pool` / `do_full` are the three levels; `select_and_update` decides and writes DNS; `notify` / `sonde_report` format output.
- `warp-keeper/warp-keeper.sh` — `cmd_check` is the self-healing ladder; `build_fragment` writes the sing-box JSON.
- `brutal-cn.sh` — config constants at the top; embedded Python (`PY_HELPER`) builds the add/delete plan.
- `update.sh`, `uninstall.sh` (root) — iterate over installed tools. `docs/` — pages for the root-level scripts.

## Conventions

- User-facing text (logs, Telegram, prompts, comments) is Chinese; README.md / AGENTS.md are English with `README.zh-CN.md` mirrors.
- Commit messages: Chinese, first line `<tool>：<what changed>`, body as bullet list.
- Changes are delivered to the owner as `git format-patch` files, applied with `git am -3`.
- Shell commands in docs must run unchanged in fish: no `$(…)` in command position, no `<(…)`, no heredocs, no `export A=1 B=2`; wrap bash-only snippets in `bash -c '…'`. Don't prefix with `sudo`.
- Every installer is idempotent and never overwrites an existing `/etc/<tool>.env`.
- The block between `==== 公共部分 v1` and `==== 公共部分结束` is identical in every `*/update.sh` (and in the owner's other repos). Change it in all copies or not at all.

## Architecture & invariants

- **No IPs, domains or URLs in Telegram or Sonde output.** Each tool has its own scrub (`scrub()` in bot.py and the shell tools, `_redact()` in cdt_guard.py); keep the IPv4, IPv6, URL and domain patterns in sync. Only exception: warp-keeper shows the WARP exit IP in Telegram (not in Sonde).
- **cdt-guard is fail-safe.** A failed query means no action; a reading is never treated as 0 on error; the traffic fuse lifts only when `bill_cycle()` differs from `lock_cycle` **and** usage < release; stop/start/security-group calls use `ecs_once()` (no retry).
- **cdt-guard must finish within `TimeoutStartSec=300`**: two queries ≈ 65 s each worst case, bill query skipped past `QUERY_BUDGET`.
- **traffic-bot never calls paid AWS APIs**: CloudWatch `GetMetricStatistics` / `ListMetrics` only — never `GetMetricData` or Cost Explorer.
- **CPU P90 metrics use `notify=False`**: they fluctuate around the limit; only 24 h breaches and killed calls alert.
- **Sonde runs on Cloudflare D1** (owner-confirmed). Budget writes: cdt-guard reports on change + 15 min heartbeat; traffic-bot once per alert round. Don't add per-minute reporters.
- warp-keeper must `sing-box check` before every reload and keep `fragment.prev` for rollback. Temp files in the sing-box config dir must not end in `.json`.
- cfst-ddns: speed tests must go direct (service user UID 950 is excluded from sing-box TUN); API calls may use `API_PROXY`.

## Do not

- Do not commit secrets; config goes in `/etc/<tool>.env` (templates: `*.env.example`, `traffic-bot/install.sh`).
- Do not add backward-compatibility shims for old env names or old file layouts; the owner redeploys from the latest repo.
- Do not make cdt-guard release a fuse, start an instance or retry a stop on uncertain data.
- Do not reload or restart sing-box from anything except warp-keeper's existing paths and `upsing.sh`.
- Do not break the `00-` fragment naming or the `-C` config-dir assumption in warp-keeper.

## Config & secrets

- Each tool reads `/etc/<tool>.env` (brutal-cn and debian-init: constants at the top of the script). Full tables: each tool's README → Configuration.
- Tests need no secrets: cdt-guard tests use a fake API via `ALI_ENDPOINT_OVERRIDE`; bot tests mock `requests` and providers.

## Deployment & environments

- Servers clone the repo to `/opt/scripts-de-moi` and run `./update.sh`, which updates each tool whose program file and env both exist.
- traffic-bot and cdt-guard share one machine (the bot reads `/var/lib/cdt-guard/state.json`); cfst-ddns runs on a home Debian box; warp-keeper runs on the overseas VPS with sing-box.
- Rollback: `git revert <sha>` and `./update.sh`.

## Before you finish

- [ ] Both test suites pass; `bash -n` and `py_compile` are clean.
- [ ] Docs synced: changed a command, config key, default or behavior → update the tool's `README.md` **and** `README.zh-CN.md`, its `docs/MANUAL.zh-CN.md`, the env template, and this file if an invariant moved.
- [ ] New env key → add it to the env template (`*.env.example` or `install.sh`) and the README config table.
- [ ] Output still scrubbed (no IP / domain / URL in Telegram or Sonde).
- [ ] A fact you could not verify goes into the README table "Environment facts and open questions".

## Gotchas

- `asyncio.run()` waits for leftover executor threads on exit; time async code inside the loop in tests.
- `scrub()`'s IPv6 pattern also matches `h:m:s` times with two colons; keep `HH:MM` in messages.
- `CDT-Management/update.sh` and the other tools' `update.sh` are executable; root `update.sh` calls them via `bash` anyway.
- GitHub's API and most websites are unreachable from sandboxed agents; `upsing.sh` can only be tested with a stubbed releases file.
