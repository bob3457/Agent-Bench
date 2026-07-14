# webarena-verified on Hopper (rootless Apptainer + SLURM)

Runs the ServiceNow **webarena-verified** environments — everything in
WebArena **except wikipedia** — on GMU Hopper: no root, no `/etc/subuid`
(single-uid user namespaces), no privileged ports, no Docker.

| Site | Kind | External port | URL placeholder | Credentials |
|---|---|---|---|---|
| `shopping` | Magento storefront | 7770 | `__SHOPPING__` | `emma.lopez@gmail.com` / `Password.123` |
| `shopping_admin` | Magento admin | 7780 (`/admin`) | `__SHOPPING_ADMIN__` | `admin` / `admin1234` |
| `reddit` | Postmill (nginx + php-fpm + postgres) | 9999 | `__REDDIT__` | `MarvelsGrantMan136` / `test1234` |
| `gitlab` | GitLab omnibus (runit) | 8023 | `__GITLAB__` | `byteblaze` / `hello1234` |
| `map` | OSM website (rails + apache/mod_tile + renderd + 3× postgres + 3× osrm) | 3030 | `__MAP__` | — |

The approach is the PoloWitty `webarena-lite-for-rootless-slurm` recipe ported
to the webarena-verified images and extended per service stack. Instead of
each image's supervisord/runit + env-ctrl (which need `su` and multiple uids),
`02_patch_sandbox.sh` strips every user-switch from the configs and a per-kind
entry script in `container/` starts the services directly as your uid, then
applies exactly what `env-ctrl init` would (base-URL rewrite, cache flush).

- **magento** (`wa_magento_entry.sh`): redis, mariadb, php-fpm, nginx
  (+ mailcatcher, + elasticsearch for shopping), Magento base-URL set per start.
- **reddit** (`wa_reddit_entry.sh`): postgres (moved to 19991), php-fpm
  (19992), nginx; rewrites `APP_SITE_NAME` in `.env` and clears the Symfony
  cache per start. Header auto-login: `X-Postmill-Auto-Login`.
- **gitlab** (`wa_gitlab_entry.sh`): keeps omnibus runit but with
  `chpst -u`/`su` stripped from all `sv` run scripts; **never runs
  `gitlab-ctl reconfigure`** (would restore root-isms) — instead seds the
  `host:`/`port:` in `gitlab-rails/etc/gitlab.yml` per start. Puma pins
  `127.0.0.1:8080` internally.
- **map** (`wa_map_entry.sh`): starts the three postgres clusters (website
  5433, tiles 5432, nominatim 5434), rails (3000), apache (external
  `MAP_HTTP_PORT`, internal 8080/8085 restricted to loopback), renderd, and
  the three osrm-routed instances. Internal ports are **not** remapped —
  `localhost:8080` URLs are baked into the rails settings and precompiled
  assets — so map wants its own node.

**Node placement rules**

- `gitlab` and `map` must **not** share a node (both use internal port 8080).
- `map` also needs 3000, 5000–5002, 5432–5434 free; give it its own node.
- Everything else has internal services moved to >1024 unique ports and can
  share: `shopping shopping_admin reddit gitlab` fit on one ~48G node.
- Rough memory: magento pair ~20G, reddit ~4G, gitlab ~16G, map ~32G.

## Layout

Everything defaults to **`/scratch/czhai/webarena-verified`** for this test
phase (scratch may be purged — move `persist/` to `/projects/kzhou6/czhai/`
later by setting `WA_ROOT`):

| Piece | Default location |
|---|---|
| Patched sandboxes / SIFs / seed state | `$WA_ROOT` = `.../persist` |
| Map external data (tiles, nominatim, osrm) | `$WA_MAP_DATA_DIR` = `.../persist/mapdata` |
| Live state, run dirs, logs, URL fragments, apptainer cache | `$WA_SCRATCH` = `.../runtime` |
| Conda env, harness source, playwright browsers | `.../{conda-env,src,ms-playwright}` |

All ports and paths are overridable env vars in `wa_common.sh`.

## Step 0: Python env (harness only — hosting needs no Python)

```bash
./00_setup_conda_env.sh
source /scratch/czhai/webarena-verified/activate_wa.sh
webarena-verified --help
```

## One-time setup

```bash
# 1. Pull images into user-owned sandboxes (LOGIN NODE — compute nodes
#    throttle egress; gitlab is ~15-25GB, map ~10-15GB)
./01_fetch_images.sh                       # all sites, or list them:
./01_fetch_images.sh reddit gitlab map

# 2. Apply the rootless patches (per site)
for s in shopping shopping_admin reddit gitlab map; do ./02_patch_sandbox.sh $s; done

# 3. Map only: download + extract external data (LOGIN NODE, huge — check first)
./05_fetch_map_data.sh sizes
./05_fetch_map_data.sh                     # download + extract into $WA_MAP_DATA_DIR

# 4. Extract writable state + snapshot seed (per site)
for s in shopping shopping_admin reddit map; do ./03_prepare_state.sh prepare $s; done
WA_SKIP_SEED=1 ./03_prepare_state.sh prepare gitlab   # gitlab seed is tens of GB;
                                                      # skip it, or budget the space

# 5. (Optional) pack to SIF on a compute node — skip for gitlab (huge; the
#    sandbox runs fine and wa_site.sh falls back to it automatically)
srun -c 16 --mem=16G ./04_pack_sif.sh shopping
srun -c 16 --mem=16G ./04_pack_sif.sh shopping_admin
srun -c 16 --mem=16G ./04_pack_sif.sh reddit

# 6. Smoke test on a compute node (gitlab needs ~10-15 min, map ~5-10)
srun -c 8  --mem=16G ./wa_site.sh shopping smoke
srun -c 8  --mem=8G  ./wa_site.sh reddit smoke
srun -c 8  --mem=24G --time=00:40:00 ./wa_site.sh gitlab smoke
srun -c 16 --mem=40G --time=00:40:00 ./wa_site.sh map smoke
```

## Serving for a benchmark run

```bash
# four light sites on one node:
sbatch slurm/webarena_sites.sbatch shopping shopping_admin reddit gitlab
# map on its own node:
sbatch --mem=64G slurm/webarena_sites.sbatch map

# once running:
source /scratch/czhai/webarena-verified/runtime/urls.env
echo $SHOPPING $SHOPPING_ADMIN $REDDIT $GITLAB $MAP
```

Each hosting job writes `$WA_URLS_DIR/<site>.env` and regenerates the merged
`$WA_SCRATCH/urls.env` + `$WA_SCRATCH/config.hopper.json`, so multi-node
hosting composes automatically — whichever job finishes last produces a config
containing every live URL:

```bash
webarena-verified evaluate ... \
  --config /scratch/czhai/webarena-verified/runtime/config.hopper.json
```

Reset an environment to pristine state between runs:

```bash
./wa_site.sh reddit reset        # stop + restore seed + start
```

(For gitlab prepared with `WA_SKIP_SEED=1` there is no seed — `reset` will
fail at restore; re-run `03_prepare_state.sh prepare gitlab` from the sandbox
instead, or accept state drift across runs.)

## Agent-side notes

- Header auto-login (skips slow UI login):
  `X-M2-Customer-Auto-Login: emma.lopez@gmail.com:Password.123` (shopping),
  `X-M2-Admin-Auto-Login: admin:admin1234` (admin),
  `X-Postmill-Auto-Login: MarvelsGrantMan136:test1234` (reddit).
  GitLab has no header plugin — agents log in via the UI form.
- `__SHOPPING_ADMIN__` maps to `http://<node>:7780/admin` (includes `/admin`).
- Agents on other compute nodes reach the sites via the node IPs written to
  `urls.env`; Hopper's internal network routes compute-node ports.
- The webarena-verified dataset has **369 usable tasks** for the original
  two-site setup; adding reddit/gitlab/map unlocks the rest except
  wikipedia-dependent and `__HOMEPAGE__`-dependent tasks.

## Things to verify on first bring-up (known unknowns)

Written blind against the published images; layouts are confirmed from the
webarena-verified build scripts, but per site the spots worth an eyeball on
first `smoke`:

**magento** (unchanged from the two-site setup)
1. `env.php` endpoints — db `127.0.0.1:<mysql_port>`, redis `<redis_port>`.
2. php-fpm non-root — check `php_fpm.log` if it complains.
3. Elasticsearch keystore on first start (shopping) — absorbed by
   `--writable-tmpfs`; only catalog search breaks if ES loops.

**reddit** — *verified end-to-end locally (WSL2, non-suid Apptainer 1.5.2,
no subuid) on 2026-07-13: full request path nginx→php-fpm→Symfony→postgres
returns 200.* Notes from that bring-up, now handled by the scripts:
1. The app's real DB config is the `fastcgi_param DATABASE_URL` in
   `etc/nginx/conf.d/default.conf` (Symfony Dotenv never overrides real env);
   `02_patch_sandbox.sh` patches it to `127.0.0.1:19991`.
2. The image's `daemon off;` and v4+v6 `listen` pairs in the nginx confs are
   stripped/deduped at patch time (fatal duplicates otherwise).
3. `02_patch_sandbox.sh` auto-detects the php-fpm pool dir and postgres data
   dir (records the latter in `sandbox/.wa_pgdata_path`); check its output.

**gitlab** — *verified end-to-end locally (WSL2 Hopper sim, 24G RAM): full
omnibus stack under runit, `/users/sign_in` -> 200.* Fixes baked in from that
bring-up: pg_hba `local peer map=gitlab` -> `trust` (single-uid peer auth can
never match the map), and the entry rewrites the nginx listen port per start.
1. If a service loops in `runsvdir`, check `$STATE/gitlab-log/<svc>/current`.
2. Startup is legitimately slow (5–15 min). The entry script waits up to 900 s
   for `/users/sign_in`.
3. Never run `gitlab-ctl reconfigure` inside the container.

**map** — *structure verified locally without external data: three pg
clusters, role/db init, full rails db:migrate, puma, apache on 3030 all come
up rootless; /api/0.6/* returns 200.* Fixes baked in: ssl=off + trust hba in
all cluster confs, pg_stat_tmp dirs pre-created, leftover apache port-80
Listens swept.
1. KNOWN ISSUE: `/` (homepage) returned 500 locally — Sprockets claims
   "index.js not present in the asset pipeline" although the compiled bundle
   and manifest exist in public/assets. Not containment-related. Retest on
   Hopper with real data; if it persists, a `rails assets:precompile` inside
   the sandbox (RAILS_ENV=production, any SECRET_KEY_BASE) is the lever.
2. Tile db / nominatim db / osrm data missing ⇒ entry logs a WARNING and
   keeps going: the API works, but tiles/geocoding/routing don't.
3. First start runs rails `db:migrate` — allow the full 600 s budget.

## Troubleshooting

- **Port already in use**: another user on the node, or a stale run. Override
  e.g. `SHOPPING_HTTP_PORT=27770` (then regenerate the config). For map the
  internal ports are not overridable — pick another node.
- **MySQL/postgres slow or flaky on scratch**: point live state at node-local
  disk for the job: `WA_STATE_DIR=$TMPDIR/wa-state` before
  `03_prepare_state.sh restore` + `wa_site.sh start` (seed stays put).
- **`apptainer build` OOM/tmp issues**: cache and tmp are already forced to
  scratch via `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` in `wa_common.sh`.
- **Wrong base URL after moving nodes**: just `wa_site.sh <site> start`
  again — every entry script re-applies the base URL with the current
  `WA_HOST` on each start.
- **SIF FUSE mounting broken on compute nodes**: known Hopper issue; the
  sandbox fallback in `wa_site.sh` covers it (`rm` the SIF or never build one).
