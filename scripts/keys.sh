#!/usr/bin/env bash
# Create the key file the cluster's Secret is built from. It lives OUTSIDE
# the repository and the keys are never printed. This is scripts/keys.ps1
# for Linux and macOS; see that file for what each value is for.
#
#   ./scripts/keys.sh           # create it (keeps an existing one)
#   ./scripts/keys.sh --force   # new keys, then run ./scripts/up.sh again
set -euo pipefail

path="${TS_KEYS_FILE:-$HOME/.tenantscaler/kind.env}"
force=0
while [ $# -gt 0 ]; do
	case "$1" in
	--force) force=1 ;;
	--path) shift; path="${1:?--path needs a file}" ;;
	*) echo "usage: keys.sh [--force] [--path <file>]" >&2; exit 2 ;;
	esac
	shift
done

if [ -e "$path" ] && [ "$force" -eq 0 ]; then
	echo "$path exists; keeping it (use --force for new keys)."
	exit 0
fi

newkey() {
	# 16 random bytes as hex. openssl is everywhere; /dev/urandom is the
	# fallback so this needs nothing installed.
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex 16
	else
		od -vN16 -An -tx1 /dev/urandom | tr -d ' \n'
	fi
}

mkdir -p "$(dirname "$path")"
a=$(newkey); b=$(newkey); c=$(newkey)
# Written with a umask so the file is readable only by you, and with LF
# endings so kubectl --from-env-file keeps no stray carriage return.
old=$(umask); umask 077
cat >"$path" <<EOF
TS_TENANT_KEYS=a:standard=$a,b:standard=$b,c:sheddable=$c
TS_ADMIN_KEY=$(newkey)
TS_KEY_A=$a
TS_KEY_B=$b
TS_KEY_C=$c
EOF
umask "$old"
echo "Wrote $path (keys not printed)."
