#!/usr/bin/env bash
# Mint short-lived (1h) GitHub App installation tokens, each scoped to a single
# repo, using the App private key on the host. Three modes:
#
#   mint-github-token                     mint for every running dev container,
#                                         writing each to its
#                                         /etc/secrets/github_token
#                                         (this is what github-token.timer runs)
#   mint-github-token <container>         mint for just that container
#                                         (devenv.sh create/rebuild)
#   mint-github-token --print-token <repo>
#                                         print a token scoped to <repo> to stdout
#                                         (devenv.sh uses this to authenticate the
#                                         host-side `git clone`, since the repo may
#                                         be reachable only via the App, not the
#                                         host PAT)
#
# The App private key never leaves the host. Container modes skip cleanly for
# containers that are stopped or have no origin remote.
set -euo pipefail

app_id_file="/run/secrets/gh_app_id"
pem_file="/run/secrets/gh_app_private_key"

# Parse mode.
print_repo=""
targets=()
if [ "${1:-}" = "--print-token" ]; then
  print_repo=${2:?usage: mint-github-token --print-token <repo>}
elif [ $# -ge 1 ]; then
  targets=("$1")
else
  mapfile -t targets < <(
    systemctl list-units 'container@*.service' --no-legend --plain --state=active \
      | sed -n 's/^container@\([^ ]*\)\.service.*/\1/p'
  )
fi

if [ -z "$print_repo" ] && [ "${#targets[@]}" -eq 0 ]; then
  echo "no running containers; nothing to mint"
  exit 0
fi

# base64url without padding, as required for JWT segments.
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# One App-authenticating JWT is reused for every repo below (valid ~9 min). iat is
# backdated 60s to tolerate clock skew against GitHub.
app_id=$(cat "$app_id_file")
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$app_id" | b64)
signature=$(printf '%s' "${header}.${payload}" | openssl dgst -sha256 -sign "$pem_file" | b64)
jwt="${header}.${payload}.${signature}"

gh_api() {
  curl -fsS \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

# The App is installed on a single account, so the first installation is ours.
install_id=$(gh_api https://api.github.com/app/installations | jq -r '.[0].id')
if [ -z "$install_id" ] || [ "$install_id" = "null" ]; then
  echo "could not resolve App installation id (is the App installed on the account?)" >&2
  exit 1
fi

# Mint a token scoped to a single repo and echo it (empty on failure). This is the
# single place the granted permission set is defined.
mint_token() {
  local repo=$1
  gh_api -X POST \
    "https://api.github.com/app/installations/${install_id}/access_tokens" \
    -d "{\"repositories\":[\"${repo}\"],\"permissions\":{\"contents\":\"write\",\"pull_requests\":\"write\",\"metadata\":\"read\",\"workflows\":\"write\",\"actions\":\"write\",\"checks\":\"read\",\"statuses\":\"read\"}}" \
    2>/dev/null | jq -r '.token' 2>/dev/null || true
}

# --print-token mode: emit a token for one repo and exit.
if [ -n "$print_repo" ]; then
  token=$(mint_token "$print_repo")
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "failed to mint token for repo '$print_repo' (is the App installed on it?)" >&2
    exit 1
  fi
  printf '%s\n' "$token"
  exit 0
fi

# Container mode: mint one repo-scoped token and write it into the container.
# Called in an `|| rc=1` context below, so a single failure never aborts the run.
mint_one() {
  local name=$1
  local project_dir="/home/claw/projects/${name}"
  local token_file="/var/lib/nixos-containers/${name}/etc/secrets/github_token"

  # Only running containers have /etc/secrets mounted.
  if ! systemctl is-active --quiet "container@${name}.service"; then
    echo "skip ${name}: not running"
    return 0
  fi

  # Scope the token to the project's origin repo. A brand-new `devenv new`
  # container has no remote yet -> nothing to scope to, so skip until one exists.
  local origin repo
  origin=$(git -c safe.directory='*' -C "$project_dir" remote get-url origin 2>/dev/null || true)
  if [ -z "$origin" ]; then
    echo "skip ${name}: no origin remote"
    return 0
  fi
  repo=$(basename "${origin%.git}")

  local token
  token=$(mint_token "$repo")
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "FAILED ${name}: could not mint for repo '${repo}' (is the App installed on it?)" >&2
    return 1
  fi

  # Write atomically, readable only by the container's dev user. Own it to whoever
  # owns the container's /home/dev rather than hardcoding a uid, so it stays correct
  # regardless of how NixOS allocated the dev user's uid/gid.
  local dev_home="/var/lib/nixos-containers/${name}/home/dev"
  local uid gid
  uid=$(stat -c %u "$dev_home" 2>/dev/null || echo 1000)
  gid=$(stat -c %g "$dev_home" 2>/dev/null || echo 100)
  printf '%s\n' "$token" | install -m 0400 -o "$uid" -g "$gid" /dev/stdin "${token_file}.tmp"
  mv -f "${token_file}.tmp" "$token_file"
  echo "minted ${name} (repo '${repo}')"
}

rc=0
for name in "${targets[@]}"; do
  mint_one "$name" || rc=1
done
exit "$rc"
