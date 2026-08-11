# gitlab-creds kit

A Docker Sandboxes kit that layers **two deliberately separate GitLab
credentials** onto the `claude-agy` sandbox:

| Service (`sbx secret set` name) | Env var in sandbox | Injected as | Used only for |
| :--- | :--- | :--- | :--- |
| `gitlab-config-repo` | `GITLAB_CONFIG_REPO_TOKEN` | `Authorization: Basic` (username from `spec.yaml`) on `gitlab.com` | Cloning/pulling the `claude-home` dotfiles repo on every start (`sync-claude-config.sh`) |
| `gitlab-cli` | `GITLAB_CLI_TOKEN` | `PRIVATE-TOKEN` header on `gitlab.com` | Authenticating the `glab` CLI (`glab-login.sh`) |

Different token, different scope, different blast radius. Both are
`proxyManaged: true`: the sandbox only ever sees placeholder sentinels;
the host-side proxy rewrites the real values into request headers on the
way out. The two credentials inject **different header names**, so they
coexist on the same domain without overwriting each other.

```text
my-kit/
├── spec.yaml.template          # commit-safe template with <placeholders>
├── spec.yaml                   # your real config — gitignored, copied from the template
├── README.md
└── files/home/.local/bin/
    ├── sync-claude-config.sh   # config repo only
    └── glab-login.sh           # glab auth only
```

## Configuration

`spec.yaml` is gitignored because it carries machine-/user-specific
values. Create yours from the template and fill in the placeholders —
the `extends` parent and the `environment.variables` below:

```bash
cp spec.yaml.template spec.yaml
sbx kit validate ./my-kit
```

Validation is schema-only — it does **not** catch unfilled
`<placeholders>` (verified: a pristine template copy validates). A
forgotten placeholder surfaces at first run instead, as a parent-image
resolution failure or a clone error.

Both scripts read their targets from environment variables.
`CLAUDE_CONFIG_REPO_URL` has no default and must be set;
`GITLAB_HOST` defaults to `gitlab.com`. Set them in `spec.yaml`:

```yaml
environment:
  variables:
    CLAUDE_CONFIG_REPO_URL: https://gitlab.com/<group>/<dotfiles-repo>.git
    GITLAB_HOST: gitlab.com
```

- `CLAUDE_CONFIG_REPO_URL` — **required**: the repo
  `sync-claude-config.sh` clones. The startup command fails with a clear
  error when it is unset. Prefixed rather than a bare `REPO_URL` so an
  unrelated variable in the sandbox environment can't silently redirect
  the config sync.
- `GITLAB_HOST` — the instance `glab-login.sh` authenticates against
  (default `gitlab.com`). glab honors the same variable itself, so later
  glab calls follow the override too.

Pointing either at a host other than gitlab.com also requires updating
the matching `inject[].domain` entries and `permissions.network.allow`
in `spec.yaml` — credential injection is domain-scoped.

## 1. Create the tokens in GitLab

### Credential 1 — deploy token for the config repo

In the `claude-home` project: **Settings → Repository → Deploy tokens**.

- **Name**: anything descriptive (e.g. `sandbox config sync`).
- **Username**: set it explicitly to `claude-config-sync` so it matches
  `inject[].username` in `spec.yaml`. If you let GitLab generate one
  (`gitlab+deploy-token-NNNN`), edit `spec.yaml` to match instead — the
  Basic auth pair is `<username>:<token>` and both halves must be right.
- **Scopes**: `read_repository` only.
- **Expiration**: set one; rotating a read-only deploy token is cheap.

### Credential 2 — token for the glab CLI

Type is still an open choice; `glab auth login` accepts all three and
`glab-login.sh` is identical for each:

- **Personal access token** — *User settings → Access tokens*. Acts as
  your full GitLab user across every project; broadest blast radius.
- **Group access token** — *Group → Settings → Access tokens*. Creates a
  bot user confined to the group; you pick the role (e.g. Developer).
  Narrower blast radius than a PAT while still covering all group
  projects.
- **Project access token** — *Project → Settings → Access tokens*.
  Narrowest: one project only.

Scopes: `api` for general read/write GitLab work; `read_api` if the
sandbox should stay read-only on the API. Add `write_repository` only if
you also want authenticated `git push` — but note the git-traffic caveat
in [Design notes](#design-notes) below.

## 2. Store the secrets on the host

One `sbx` secret per service, names matching `spec.yaml`:

```bash
# Prompts for the value (keeps it out of shell history):
sbx secret set gitlab-config-repo
sbx secret set gitlab-cli

# Or pipe from 1Password:
op read 'op://<vault>/<item>/<field>' | sbx secret set gitlab-config-repo
op read 'op://<vault>/<item>/<field>' | sbx secret set gitlab-cli
```

Confirm with `sbx secret ls`. If your `sbx` version only accepts its
built-in service names via `secret set`, provide the values at the
first-run credential prompt when the sandbox is created instead — kit
credentials can be sourced either way.

For `gitlab-config-repo`, the stored secret is the deploy token **value**
only; the username half of the Basic pair comes from `spec.yaml`.

## 3. Run

```bash
sbx run --kit ./my-kit/ claude
```

`--kit` only takes effect at sandbox creation; for an existing sandbox
use `sbx kit add` or recreate it.

> **Note on `extends`:** `spec.yaml` uses
> `extends: ghcr.io/bjurecska/ai-sandbox/claude-agy:1.2`. This passes
> `sbx kit validate`, but docs.docker.com specifies that `extends` must
> resolve to a sandbox *kit*, and CI publishes `claude-agy` as a plain
> container image. If the first real run fails to resolve the parent,
> switch to the mixin form, which layers onto the existing
> `--template` workflow:
>
> ```yaml
> kind: mixin
> requires:
>   agent: claude
> # (drop the `extends:` line; everything else unchanged)
> ```
>
> ```bash
> sbx run --template claude-code-agy:latest --kit ./my-kit/ \
>   --name sandboxed-claude-agy claude
> ```

## 4. Verify

Exec into the running sandbox:

```bash
sbx exec -it <sandbox-name> bash
```

Then check each concern independently:

1. **glab is authenticated** (credential 2, `PRIVATE-TOKEN` path):

   ```bash
   glab auth status --hostname gitlab.com   # expect: Logged in to gitlab.com
   glab api user                            # expect: your user (PAT) or the bot user (group/project token)
   ```

2. **~/.claude matches the repo** (credential 1, Basic auth path):

   ```bash
   git -C ~/.cache/claude-config-src log --oneline -1   # latest claude-home commit
   diff ~/.cache/claude-config-src/CLAUDE.md ~/.claude/CLAUDE.md
   ```

3. **Claude Code's own login survived the sync** — the rsync excludes
   `~/.claude/.credentials.json`, so `claude` should start without
   demanding a fresh `/login`. If you find additional auth/state files
   under `~/.claude` during this check, add them to `RSYNC_EXCLUDES` in
   `sync-claude-config.sh`.

4. **Sentinels, not secrets, in the sandbox**:

   ```bash
   echo "$GITLAB_CONFIG_REPO_TOKEN" "$GITLAB_CLI_TOKEN"
   ```

   Both should print placeholder values — seeing a real token here means
   proxy management is not active.

## Design notes

- **Same domain, two credentials.** The docs don't spell out behavior
  for two credentials injecting into one domain, but each `inject` rule
  names its own header — `Authorization` (Basic) vs `PRIVATE-TOKEN` — so
  neither overwrites the other. GitLab's API evaluates `PRIVATE-TOKEN`
  ahead of Basic auth, so glab API calls authenticate as credential 2
  even though git-style Basic auth rides along on the same requests.
  Verification step 1 is what proves this end to end.
- **All sandbox git traffic to gitlab.com authenticates as the deploy
  token.** Header injection is domain-wide with no path scoping, so a
  `git clone`/`git push` against any *other* gitlab.com repo also gets
  the deploy token's Basic header — and fails, because a deploy token is
  project-scoped and read-only. That is the intended containment for
  credential 1; do general GitLab work through `glab` (credential 2).
- **Startup scripts are invoked via `bash <path>`** rather than relying
  on the executable bit surviving the kit file copy, and both are safe
  to rerun on every start.
