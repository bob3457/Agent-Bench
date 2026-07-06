# webarena-verified on Hopper (rootless Apptainer + SLURM)

Runs the ServiceNow **webarena-verified** `shopping` and `shopping_admin`
environments on GMU Hopper: no root, no `/etc/subuid` (single-uid user
namespaces), no privileged ports, no Docker.

The approach is the PoloWitty `webarena-lite-for-rootless-slurm` recipe ported
to the webarena-verified images. That works because the verified images are
squashed from the same CMU Alpine/Magento images PoloWitty patched, so the
config layout (`/etc/supervisor.d`, `/usr/local/etc/php-fpm.d`,
`/etc/my.cnf.d`, `/var/www/magento2`) is identical — while keeping the
verified extras you actually want: ~90% smaller images, the
`X-M2-Customer-Auto-Login` / `X-M2-Admin-Auto-Login` header-auth plugins baked
in, and offline HAR-based evaluation (so containers are only needed while the
agent browses, never for scoring).

Instead of the image's supervisord + env-ctrl stack (which needs `su` and
multiple uids), `container/wa_magento_entry.sh` starts redis, mariadb,
php-fpm, nginx (+ mailcatcher, and elasticsearch for shopping) directly as
your uid, then applies exactly what `env-ctrl init` would: set the Magento
base URL, patch `web/secure/base_url` in MySQL, disable the admin password
expiry policies (admin site), and flush caches.

## Layout

Everything defaults to **`/scratch/czhai/webarena-verified`** for this test
phase (scratch may be purged — move `persist/` to `/projects/kzhou6/czhai/`
later by setting `WA_ROOT`):

| Piece | Default location |
|---|---|
| Patched sandboxes / SIFs / seed state | `$WA_ROOT` = `/scratch/czhai/webarena-verified/persist` |
| Live state, run dirs, logs, apptainer cache | `$WA_SCRATCH` = `/scratch/czhai/webarena-verified/runtime` |
| Conda env, harness source, playwright browsers | `/scratch/czhai/webarena-verified/{conda-env,src,ms-playwright}` |

All ports and paths are overridable env vars in `wa_common.sh`. Defaults keep
the webarena-verified external ports (`7770` shopping, `7780` admin) and move
internal services to `1777x` / `1778x` so both sites share one node.

## Step 0: Python env (harness only — hosting needs no Python)

```bash
./00_setup_conda_env.sh
source /scratch/czhai/webarena-verified/activate_wa.sh
webarena-verified --help
```

This reuses your miniconda at `/projects/kzhou6/czhai/miniconda3` if found
(else bootstraps one into scratch), creates a prefix env
(`conda-env/`, python 3.12), clones + `pip install -e`'s webarena-verified
with the `examples` extra (Playwright), installs the chromium browser into
scratch, and keeps every cache (pip, conda pkgs, browsers) off `$HOME`.
`WA_INSTALL_EXAMPLES=0` skips Playwright if you only need offline evaluation.

## One-time setup

```bash
# 1. Pull images into user-owned sandboxes (needs network — login node is fine)
./01_fetch_images.sh

# 2. Apply the rootless patches
./02_patch_sandbox.sh shopping
./02_patch_sandbox.sh shopping_admin

# 3. Extract writable state (mysql, magento var/, nginx lib, ES data) + seed it
./03_prepare_state.sh prepare shopping
./03_prepare_state.sh prepare shopping_admin

# 4. (Recommended) pack to SIF on a compute node
srun -c 16 --mem=16G ./04_pack_sif.sh shopping
srun -c 16 --mem=16G ./04_pack_sif.sh shopping_admin

# 5. Smoke test on a compute node
srun -c 8 --mem=16G ./wa_site.sh shopping smoke
srun -c 8 --mem=16G ./wa_site.sh shopping_admin smoke
```

## Serving for a benchmark run

```bash
sbatch slurm/webarena_sites.sbatch
# once running:
source /scratch/czhai/webarena-verified/runtime/urls.env
echo $SHOPPING $SHOPPING_ADMIN
```

The job also writes `$WA_SCRATCH/config.hopper.json`, ready for the harness:

```bash
webarena-verified evaluate ... \
  --config /scratch/czhai/webarena-verified/runtime/config.hopper.json
```

Reset an environment to pristine state between runs:

```bash
./wa_site.sh shopping_admin reset     # stop + restore seed + start
```

## Agent-side notes

- Header auto-login (skips slow UI login):
  `X-M2-Customer-Auto-Login: emma.lopez@gmail.com:Password.123` (shopping),
  `X-M2-Admin-Auto-Login: admin:admin1234` (admin). Set via Playwright
  `extra_http_headers`, or use `use_header_login: true` in the config (already
  emitted by `make_config.sh`).
- `__SHOPPING_ADMIN__` maps to `http://<node>:7780/admin` (includes `/admin`).
- Agents on other compute nodes reach the site via the node IP written to
  `urls.env`; Hopper's internal network routes compute-node ports.

## Things to verify on first bring-up (known unknowns)

Written blind against the published images; the layout is confirmed from the
webarena-verified build scripts, but three spots are worth an eyeball on the
first `smoke`:

1. **`env.php` endpoints** — `02_patch_sandbox.sh` prints the `host`/`port`
   entries after patching. The db entry should read `127.0.0.1:<mysql_port>`
   and redis entries `<redis_port>`. If a *session* redis block uses
   `'host' => '127.0.0.1'` and got the mysql port appended, fix that line to
   plain `127.0.0.1` (redis port is a separate key).
2. **php-fpm as non-root** — user/group directives are commented out; if
   php-fpm still complains, check `$WA_LOG_DIR/<site>/php_fpm.log`.
3. **Elasticsearch (shopping only)** — first start may try to create a
   keystore in its config dir. `--writable-tmpfs` should absorb that (sandbox
   was built `--fix-perms`, so files are user-owned). If ES loops, storefront
   *browsing* still works; only catalog search breaks. Check
   `elasticsearch.log`.

## Troubleshooting

- **Port already in use**: another user on the node, or a stale run. Override
  e.g. `SHOPPING_HTTP_PORT=27770` (then regenerate the config).
- **MySQL slow / flaky on scratch**: point live state at node-local disk for
  the job: `WA_STATE_DIR=$TMPDIR/wa-state` before `03_prepare_state.sh restore`
  + `wa_site.sh start` (seed stays on `/projects`).
- **`apptainer build` OOM/tmp issues**: cache and tmp are already forced to
  scratch via `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` in `wa_common.sh`.
- **Wrong base URL after moving nodes**: just `wa_site.sh <site> start` again —
  init re-runs `setup:store-config:set` with the current `WA_HOST` every start.
