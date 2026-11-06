#!/usr/bin/env bash
# Add an SSH public key to a user's ~/.ssh/authorized_keys (idempotent).
#
# Target user: $1 > $SSH_USER > $(whoami)
#
# Usage:
#   ./add-ssh-key.sh                 # current user
#   sudo ./add-ssh-key.sh do         # another user (needs root)
#   curl -fsSL <raw-url>/add-ssh-key.sh | bash
#   curl -fsSL <raw-url>/add-ssh-key.sh | sudo bash -s -- do
#
# Override the key with SSH_KEY="ssh-ed25519 AAAA... comment".

set -euo pipefail

SSH_KEY="${SSH_KEY:-ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC2uCjp6sKsjU4aZwcC8SYalsnPzNwyL6rE8gp/1SpkmTgb9h3fGnhBkNMWAJRhyoeGCjH1/mqlkSMXkUHPsb1HOPr40HEZefbvNDjBBNrMkfAJS0tk6FqT28+YJZcO1tFdyOo2URC4nY5gbVanOu47PgJYtOVd2+INrFX1YogtfigR+DB6Pn8dB74DOmnAbo/EFtY+IbuSGP5da3BmlyruZgE/yO/OhcyEUREQRIXWfjU489q+6pwLTmJk1ls60XuNeYA2/vmlOCFJIWiJTR0KWhYbpB9SSZj8OjlEgmqZqp90ZaN+0aBKDkuwx8QizCBDHVfzQg9BObEe2hEx1ly/}"
TARGET_USER="${1:-${SSH_USER:-$(whoami)}}"

die() { echo "error: $*" >&2; exit 1; }

entry=$(getent passwd "$TARGET_USER") || die "user '$TARGET_USER' does not exist"
home=$(cut -d: -f6 <<<"$entry")
group=$(id -gn "$TARGET_USER")

if [[ $TARGET_USER != "$(whoami)" && $EUID -ne 0 ]]; then
  die "adding a key for '$TARGET_USER' requires root (use sudo)"
fi

ssh_dir="$home/.ssh"
auth="$ssh_dir/authorized_keys"

install -d -m 0700 "$ssh_dir"
[[ -f $auth ]] || install -m 0600 /dev/null "$auth"

# Compare by key type + key data (ignore the trailing comment)
key_id=$(awk '{print $1" "$2}' <<<"$SSH_KEY")
if awk '{print $1" "$2}' "$auth" | grep -qxF "$key_id"; then
  echo "Key already present in $auth — nothing to do."
else
  # Make sure the file ends with a newline before appending
  [[ -s $auth && -n $(tail -c1 "$auth") ]] && echo >>"$auth"
  echo "$SSH_KEY" >>"$auth"
  echo "Added key to $auth"
fi

chmod 0700 "$ssh_dir"
chmod 0600 "$auth"
[[ $EUID -eq 0 ]] && chown -R "$TARGET_USER:$group" "$ssh_dir"
exit 0
