# gitlab-creds kit

A Docker Sandboxes kit that layers **two deliberately separate GitLab
credentials** onto the `claude-agy` sandbox:

| Credential | Provided via | Env var in sandbox | Used only for |
| :--- | :--- | :--- | :--- |
| Read-only deploy token | **Custom secret** (`sbx secret set-custom`), stored as base64 `<user>:<token>` | `GITLAB_CONFIG_REPO_B64` (a unique placeholder) | Cloning/pulling the dotfiles repo on every start (`sync-claude-config.sh`) |
| glab CLI token | **Kit credential** `gitlab-cli` (`sbx secret set gitlab-cli`) | `GITLAB_CLI_TOKEN` (the `proxy-managed` sentinel) | Authenticating the `glab` CLI (`glab-login.sh`) |

Different token, different scope, different blast radius — and in both
cases the sandbox only ever sees a placeholder; the host-side proxy
substitutes the real value into request headers on the way out. The
deploy token is a custom secret rather than a kit credential because
kit `scheme: basic` injection cannot authenticate git (see
[Design notes](#design-notes)).

It also brings the sandbox's Claude Code up to a working state on every
start: the dotfiles sync, `glab` login, and the `agy-delegate` plugin
install (see [Plugins](#plugins)). MCP servers are attached from the
host rather than installed here — see [MCP servers](#mcp-servers).

```text
my-kit/
├── spec.yaml.template            # commit-safe template with <placeholders>
├── spec.yaml                     # your real config — gitignored, copied from the template
├── README.md
└── files/home/.local/bin/
    ├── sync-claude-config.sh     # config repo only
    ├── glab-login.sh             # glab auth only
    └── setup-claude-plugins.sh   # plugin marketplace + agy-delegate only
```

## Configuration

`spec.yaml` is gitignored because it carries machine-/user-specific
values. Create yours from the template and fill in the placeholders in
`environment.variables`:

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
- **Username**: note the exact username of the created token (custom if
  you filled the optional field, else generated
  `gitlab+deploy-token-NNNN`) — it goes inside the stored secret pair
  below, and a mismatched (or mistyped) username 401s even with a valid
  token. The **Name** field is not the username.
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

**glab CLI token** — a kit credential, name matching `spec.yaml`:

```bash
# Prompts for the value, or pipe from 1Password:
sbx secret set gitlab-cli
op read 'op://<vault>/<item>/<field>' | sbx secret set gitlab-cli
```

**Deploy token** — a custom secret whose stored value is the base64 of
the full `<username>:<token>` Basic pair:

```bash
sbx secret set-custom --host gitlab.com --env GITLAB_CONFIG_REPO_B64 \
  --value "$(printf '%s' "<deploy-token-username>:$(op read 'op://<vault>/<item>/<field>')" | base64 | tr -d '\n')"
```

Confirm both with `sbx secret ls`. To update the custom secret later
(rotation, username fix): `sbx secret rm GITLAB_CONFIG_REPO_B64 -f`,
then re-run `set-custom` **adding
`--placeholder <the-placeholder-shown-by-sbx-secret-ls>`** — reusing
the placeholder keeps existing sandboxes' env valid, so they pick up
the new value without being recreated.

## 3. Register the MCP servers on the host

Do this **before** the first run: a sandbox's static MCP set is fixed
when it is created.

```bash
sbx mcp add GitLab --url https://gitlab.com/api/v4/mcp
sbx mcp add qmd    --command "$HOME/.local/bin/qmd" --args mcp
sbx mcp auth GitLab            # OAuth servers only; interactive
sbx mcp ls                     # confirm
```

`sbx-up.sh` refuses to create the sandbox if a requested server is
unregistered, and warns if an OAuth one is unauthorized.

## 4. Run

The kit is a mixin: the sandbox image comes from `--template`, and the
kit layers the credentials, environment, and startup scripts onto it.
`sbx-up.sh` in the repo root composes creation, MCP attachment, network
policy and attach into one command:

```bash
./sbx-up.sh --name sandboxed-claude-agy
```

which is equivalent to:

```bash
sbx create --template ghcr.io/bjurecska/ai-sandbox/claude-agy:1.3 \
  --kit ./my-kit/ --static-mcp GitLab,qmd --name sandboxed-claude-agy claude .
./apply_policy.sh claude-agy --sandbox sandboxed-claude-agy
sbx run --name sandboxed-claude-agy
```

(A locally loaded template like `claude-code-agy:latest` works in
`--template` too.)

`--kit` and `--static-mcp` only take effect at sandbox creation; for an
existing sandbox use `sbx kit add` / `sbx mcp load <name> --sandbox
<sandbox>`, or recreate it. Re-running `sbx-up.sh` against a sandbox
that already exists skips creation, so it will **not** pick up a changed
`--mcp`.

> **Why not `extends`?** `extends: <image-ref>` passes
> `sbx kit validate` but fails at sandbox creation with
> `agentkits: invalid agent name` — `extends` accepts built-in agent
> kit names only, and `claude-agy` is published as a plain container
> image, not a kit artifact.

## 5. Verify

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
   echo "$GITLAB_CLI_TOKEN" "$GITLAB_CONFIG_REPO_B64"
   ```

   These should print `proxy-managed` and an `sbx-cs-…` placeholder —
   seeing a real token here means proxy substitution is not active.

5. **MCP servers reachable**:

   ```bash
   claude mcp list                          # expect mcp-gateway ✓ connected
   ```

   The host's servers arrive *through* that gateway, so they do not
   appear as separate entries. Confirm the tools themselves in a session:
   gateway-provided tools carry the `mcp__mcp-gateway__` prefix, because
   the gateway flattens tool names without embedding the originating
   server.

6. **Plugin installed and its launcher pinned**:

   ```bash
   claude plugin list --json | jq '.[] | select(.id=="agy-delegate@ai-plugins")'
   agy-bridge --types
   cat ~/.cache/setup-claude-plugins.log
   ```

   Expect `"enabled": true` and an `installPath` under
   `~/.claude/plugins/cache/`. If the plugin is installed but *not*
   enabled, the config sync overwrote `settings.json` after the install —
   check the ordering in the log.

## MCP servers

MCP servers are registered **on the host** and attached to the sandbox
through the gateway that sbx's built-in `claude` kit already wires up.
They are not registered inside the sandbox, and this is not a
preference:

- `sbx mcp add --command` runs the server binary **on the host**, outside
  the sandbox.
- The sandbox image has no `qmd`, no `op` and no `1password-mcp`, so a
  sandbox-local `claude mcp add` would register servers that can never
  start.
- `qmd`'s collections index host paths the sandbox cannot see, so even a
  qmd installed into the image would search nothing.

The attachment is a host-side flag (`--static-mcp`), fixed at creation
and **not expressible in a kit spec** — which is why `sbx-up.sh` exists.

> **1Password does not work, and renaming it does not help.** Loading it
> fails with:
>
> ```text
> ERROR: add "1password" to sandbox "<name>": add MCP gateway server:
> request failed: 500 Internal Server Error:
> parse "1password://docs/getting-started": first path segment in URL cannot contain colon
> ```
>
> The server publishes its own docs resources under the scheme
> `1password://`. RFC 3986 requires a URI scheme to start with a letter,
> so Go's `net/url` rejects it and the gateway 500s while enumerating
> resources. The leading digit is the cause, but it is in the server's
> resource URIs, not in the sbx registration name — registering an alias
> `onepassword` pointing at the same binary reproduces the identical
> error (tested on sbx v0.38.0). Nothing in this repo can fix it; it
> needs a scheme change from 1Password or a tolerant parse from sbx.
> `qmd` and `GitLab` load cleanly, so this is specific to that server.

## Plugins

`setup-claude-plugins.sh` registers the
[`ai-plugins`](https://github.com/bjurecska/ai-plugins) marketplace,
installs `agy-delegate`, and runs the plugin's own `scripts/install.sh`
to pin the `~/.local/bin/agy-bridge` launcher. It runs on every start and
is idempotent — re-running repins the launcher, which is required
because the pin is an absolute path containing the plugin version, and
`~/.claude/plugins` is not on a persisted volume.

Ordering against the config sync is the whole difficulty, and is handled
in two places:

- The two scripts are **chained in a single startup entry** rather than
  listed as two, because startup entries have no guaranteed order and
  the sync rsyncs over `~/.claude/settings.json` — the file holding
  `enabledPlugins` and `extraKnownMarketplaces`.
- `setup-claude-plugins.sh` additionally **takes the sync's flock as a
  blocking barrier** before doing any work. sbx can fire one startup
  entry several times concurrently; the losing instances' syncs exit
  immediately on their non-blocking lock, so without the barrier their
  plugin installs would race ahead of the winner's still-running rsync.

This is also why the script calls `claude plugin enable` explicitly:
after a sync has dropped `enabledPlugins`, `claude plugin install` sees
the plugin already present in `installed_plugins.json` and will not
re-enable it on its own.

The marketplace is added by **git URL**, not by the
`bjurecska/ai-plugins` shorthand (which resolves via `api.github.com`)
and not as a directory (which would only resolve in a sandbox whose
workspace happens to be the plugin repo).

## Design notes

- **The proxy substitutes placeholders, it doesn't add credentials.**
  Substitution happens only on placeholder values the client actually
  sends in a header — a credential-less request passes through untouched
  and gets a 401 (verified empirically). That's why glab stores and
  sends its sentinel token, and why `sync-claude-config.sh` sends
  `Authorization: Basic <placeholder>` itself via `http.extraHeader`.
- **Why the deploy token can't be a kit credential.** Kit
  `scheme: basic` injection never authenticates git: git base64-encodes
  Basic credentials, hiding the sentinel from the proxy's string
  substitution, and `proxyManaged: false` sets no env var at all
  (both verified empirically). The working pattern is a custom secret
  whose stored value is the *pre-encoded* `base64(<user>:<token>)`
  pair — git sends the unique placeholder visibly, the proxy swaps in
  the encoded pair, and the token still never enters the sandbox.
- **No ambient git credentials.** Only requests carrying a placeholder
  get authenticated; any other `git` operation against gitlab.com from
  inside the sandbox is anonymous and fails on private repos. Config
  syncing rides the read-only deploy token; general GitLab work goes
  through `glab`.
- **Startup scripts are invoked via `bash <path>`** rather than relying
  on the executable bit surviving the kit file copy, and all three are
  safe to rerun on every start.
- **The GitHub allowlist entries are load-bearing beyond the plugin.**
  The synced `settings.json` already declares marketplaces hosted on
  GitHub, so without `github.com` in `permissions.network.allow` they
  cannot resolve on a fresh sandbox either. Those entries mirror the
  GitHub section of `claude-agy/sbx-policy.yaml` so a sandbox works
  before `apply_policy.sh` has run.
