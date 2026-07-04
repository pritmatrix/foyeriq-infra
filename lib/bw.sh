#!/usr/bin/env bash
# Shared Bitwarden CLI helpers. Source this file, don't execute it directly.
#
# All secrets for this repo (SSH key, OCI API key, Postgres/pgAdmin
# passwords) live in a Bitwarden vault instead of local files or plaintext
# env vars on the command line. Requires:
#   - the Bitwarden CLI installed (`brew install bitwarden-cli`)
#   - logged in (`bw login`, once)
#   - unlocked for the current shell: `export BW_SESSION=$(bw unlock --raw)`
#     (session tokens don't persist across shells/processes, so this is
#     needed once per terminal session, not just once ever)
#
# Vault items used by this repo's scripts (names configurable via
# BW_ITEM_SSH_KEY / BW_ITEM_OCI_KEY / BW_ITEM_POSTGRES in .env, see
# .env.example):
#   arm-vm-ssh-key       notes = SSH private key; field public_key
#   arm-vm-oci-api-key   notes = OCI API private key (PEM); fields user_ocid,
#                        fingerprint, tenancy_ocid, region
#   arm-vm-postgres      fields domain, pgadmin_domain, pg_superuser,
#                        pg_superuser_password, app_user, app_user_password,
#                        pgadmin_web_email, pgadmin_web_password

bw_require_session() {
  command -v bw >/dev/null || { echo "Bitwarden CLI (bw) not found. Install it: brew install bitwarden-cli" >&2; exit 1; }
  command -v jq >/dev/null || { echo "jq not found. Install it: brew install jq" >&2; exit 1; }
  [[ -n "${BW_SESSION:-}" ]] || { echo "BW_SESSION not set. Run: export BW_SESSION=\$(bw unlock --raw)" >&2; exit 1; }
  local status
  status=$(bw status --session "$BW_SESSION" | jq -r .status)
  [[ "$status" == "unlocked" ]] || { echo "Bitwarden vault isn't unlocked (status: $status). Run: export BW_SESSION=\$(bw unlock --raw)" >&2; exit 1; }
}

# bw_field <item-name> <field-name> -> prints a custom field's value
bw_field() {
  bw get item "$1" --session "$BW_SESSION" | jq -r --arg f "$2" '.fields[] | select(.name == $f) | .value'
}

# bw_notes <item-name> -> prints the notes field (used for private key material)
bw_notes() {
  bw get item "$1" --session "$BW_SESSION" | jq -r '.notes'
}

# bw_write_secret_file <item-name> <dest-path> -- writes notes to dest-path, chmod 600.
# Strips CR so keys stored/edited on Windows (CRLF) aren't rejected by
# OpenSSH/openssl ("error in libcrypto" / "invalid format"). PEM/OpenSSH key
# material is pure ASCII with LF newlines, so dropping CR is always safe.
bw_write_secret_file() {
  bw_notes "$1" | tr -d '\r' > "$2"
  chmod 600 "$2"
}
