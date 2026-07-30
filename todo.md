# TODO

## Secrets not accessible to `dev` user in containers

`/etc/secrets/` has `drwxr-x--x` (751) — `others` only have `--x`, so `dev` can't list it.
`ts_auth_key` is root:root `-r--------` (400) — only root can read.

This means `devenv exec stashui-2 tailscale up ...` fails because the `dev` user can't read the auth key.

Fix: either:
- Change ownership/permissions so `dev` (or a `secrets` group) can read the key
- Or have `devenv` run the tailscale auth as root automatically on start