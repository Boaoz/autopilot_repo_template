#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$REPO_ROOT/agent/scripts/bin/agent-download-attachment"

if [[ ! -x "$HELPER" ]]; then
  echo "agent-download-attachment helper missing or not executable" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cred_file="$tmpdir/github_agent.txt"
printf '{"username":"agent","access_token":"ghp_fake_token"}\n' > "$cred_file"
chmod 600 "$cred_file"

fake_curl="$tmpdir/curl"
cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" > "$FAKE_CURL_ARGS"

out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    out="$arg"
    break
  fi
  prev="$arg"
done

if [[ -z "$out" ]]; then
  echo "missing -o output" >&2
  exit 1
fi

printf '%%PDF-1.5\nfake pdf\n' > "$out"
EOF
chmod +x "$fake_curl"

export AGENT_GITHUB_CREDENTIALS="$cred_file"
export FAKE_CURL_ARGS="$tmpdir/curl.args"
export AGENT_ATTACHMENT_CURL="$fake_curl"

out_pdf="$tmpdir/out.pdf"
"$HELPER" "https://github.com/user-attachments/files/123/example.pdf" "$out_pdf"

grep -Fq "Authorization: Bearer ghp_fake_token" "$FAKE_CURL_ARGS"
if grep -Fq '"access_token"' "$FAKE_CURL_ARGS"; then
  echo "helper leaked or used raw JSON credentials instead of parsed token" >&2
  exit 1
fi

head -c 5 "$out_pdf" | grep -Fq "%PDF-"

echo "agent attachment download checks OK"
