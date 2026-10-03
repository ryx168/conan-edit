#!/bin/bash
# Generic on-demand editor for one Conan static site.
# Runs in the PUBLIC tooling repo (conan-edit) so GitHub Actions minutes are
# available; the actual site content lives in the PRIVATE repo
# ryx168/conan-static-sites under sites/<domain>/. This session clones that
# private repo (via CONTENT_PAT), serves just the one site's folder through a
# web file manager (filebrowser) + SFTP over a throwaway cloudflared quick
# tunnel, auto-commits edits back to the private repo, and deploys the folder
# to the site's Cloudflare Pages project (account 2f32fa70) via CF_PAGES_TOKEN.
# Inputs (env): DOMAIN (e.g. cpholiday.ca), FB_PASS, CONTENT_PAT,
# CF_PAGES_TOKEN, CF_ACCOUNT_ID. GITHUB_TOKEN is the built-in token for pushing
# this repo's `session` branch (so the hub can find the live session URL).
set -uo pipefail
cd "${GITHUB_WORKSPACE:-$PWD}"

[ -n "${DOMAIN:-}" ] || { echo "FATAL: DOMAIN not set"; exit 1; }
PROJ=$(echo "$DOMAIN" | tr '.' '-')     # Pages project name convention
SITEDIR="/tmp/content/sites/$DOMAIN"

echo "::group::Clone private content repo"
mkdir -p ~/.ssh
printf '%s\n' "$CONTENT_DEPLOY_KEY" > ~/.ssh/content_key
chmod 600 ~/.ssh/content_key
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/content_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
git clone --depth 1 git@github.com:ryx168/conan-static-sites.git /tmp/content 2>&1 | tail -1
if [ ! -d "$SITEDIR" ]; then echo "FATAL: sites/$DOMAIN not found in content repo"; exit 1; fi
echo "  editing: $SITEDIR"
echo "::endgroup::"

echo "::group::Install filebrowser + cloudflared"
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
command -v filebrowser >/dev/null || { for p in /usr/local/bin/filebrowser ./filebrowser; do [ -x "$p" ] && sudo ln -sf "$(realpath "$p")" /usr/local/bin/filebrowser && break; done; }
command -v filebrowser >/dev/null || { echo "FATAL: filebrowser missing"; exit 1; }
curl -fsSL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /tmp/cloudflared
echo "::endgroup::"

echo "::group::Start filebrowser + SFTP"
FB_DB=/tmp/filebrowser.db
filebrowser config init -d "$FB_DB" --root "$SITEDIR" >/tmp/fb-init.log 2>&1
filebrowser users add -d "$FB_DB" "${FB_USER:-conan}" "$FB_PASS" --perm.admin >/tmp/fb-user.log 2>&1
filebrowser -d "$FB_DB" -a 127.0.0.1 -p 8080 --root "$SITEDIR" >/tmp/filebrowser.log 2>&1 &
FB_PID=$!
# SFTP (conan@bore.pub) scoped to the site folder
sudo apt-get install -y -qq openssh-server acl >/dev/null 2>&1 || true
ssh-keygen -q -t ed25519 -f /tmp/ssh_host_ed25519_key -N "" >/dev/null 2>&1 || true
id conan >/dev/null 2>&1 || sudo useradd -M -d "$SITEDIR" -s /bin/bash conan
sudo usermod -d "$SITEDIR" conan 2>/dev/null || true
echo "conan:$FB_PASS" | sudo chpasswd
sudo setfacl -R -m u:conan:rwX "$SITEDIR" 2>/dev/null || true
sudo setfacl -R -d -m u:conan:rwX "$SITEDIR" 2>/dev/null || true
d="$SITEDIR"; while [ "$d" != "/" ]; do sudo chmod o+x "$d" 2>/dev/null || true; d=$(dirname "$d"); done
sudo tee /tmp/sshd_config >/dev/null <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey /tmp/ssh_host_ed25519_key
PidFile /tmp/sshd.pid
PasswordAuthentication yes
UsePAM yes
PermitRootLogin no
AllowUsers conan
Subsystem sftp internal-sftp
Match User conan
    ForceCommand internal-sftp
    AllowTcpForwarding no
EOF
sudo /usr/sbin/sshd -f /tmp/sshd_config -E /tmp/sshd.log && echo "  sshd on :2222" || echo "  sshd failed"
echo "::endgroup::"

echo "::group::Tunnels"
/tmp/cloudflared tunnel --url http://127.0.0.1:8080 --no-autoupdate >/tmp/cf.log 2>&1 &
WEB_URL=""
for i in $(seq 1 20); do sleep 2; WEB_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cf.log | head -1 || true); [ -n "$WEB_URL" ] && break; done
curl -fsSL -o /tmp/bore.tgz https://github.com/ekzhang/bore/releases/download/v0.5.1/bore-v0.5.1-x86_64-unknown-linux-musl.tar.gz 2>/dev/null && tar xzf /tmp/bore.tgz -C /tmp 2>/dev/null
SFTP_PORT=""
if [ -x /tmp/bore ]; then /tmp/bore local 2222 --to bore.pub >/tmp/bore.log 2>&1 & for i in $(seq 1 15); do sleep 2; SFTP_PORT=$(grep -oE 'bore\.pub:[0-9]+' /tmp/bore.log | head -1 | cut -d: -f2 || true); [ -n "$SFTP_PORT" ] && break; done; fi
[ -n "$WEB_URL" ] || { echo "FATAL: no web tunnel"; cat /tmp/cf.log; exit 1; }
echo "  web:  $WEB_URL"
echo "  sftp: bore.pub:${SFTP_PORT:-N/A}"
echo "::endgroup::"

# publish session for the hub on a per-domain branch session-<domain>, file session.json
SESS_BRANCH="session-$DOMAIN"
publish() {
  local json blob tree commit
  json=$(printf '{"domain":"%s","url":"%s","sftp_host":"bore.pub","sftp_port":"%s","since":"%s"}\n' "$DOMAIN" "$WEB_URL" "${SFTP_PORT:-}" "$(date -u +%FT%TZ)")
  blob=$(printf '%s' "$json" | git hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tsession.json\n' "$blob" | git mktree)
  commit=$(git -c user.email=superesolutions@gmail.com -c user.name="conan editor" commit-tree "$tree" -m "session $DOMAIN $(date -u +%FT%TZ)")
  git push -q -f origin "$commit:refs/heads/$SESS_BRANCH" 2>/dev/null && echo "  session published ($SESS_BRANCH)" || echo "  session publish failed"
}
publish

cd /tmp/content
git config user.email "superesolutions@gmail.com"; git config user.name "conan editor"
deploy() {
  CLOUDFLARE_API_TOKEN="$CF_PAGES_TOKEN" CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID" \
    npx -y wrangler@4 pages deploy "sites/$DOMAIN" --project-name "$PROJ" --branch main --commit-dirty=true >/tmp/deploy.log 2>&1 \
    && echo "  [$(date -u +%H:%M:%S)] deployed to Pages ($PROJ)" || { echo "  deploy FAILED:"; tail -3 /tmp/deploy.log; }
}
commit_and_deploy() {
  if [ -n "$(git status --porcelain "sites/$DOMAIN")" ]; then
    git add -A "sites/$DOMAIN"
    git commit -q -m "Edit $DOMAIN: $(date -u +%FT%TZ)" 2>/dev/null || return 0
    git push -q origin HEAD:main 2>/tmp/cpush.log || { echo "  content push failed:"; tail -2 /tmp/cpush.log; }
    deploy
  fi
}

IDLE_MIN="${IDLE_MINUTES:-15}"; idle_limit=$(( IDLE_MIN * 60 ))
last_active=$(date +%s); last_cd=$(date +%s); CD_EVERY=120
MAX=$(( 340 * 60 )); start=$(date +%s)
echo "watching for idle (${IDLE_MIN} min)"
while true; do
  sleep 15; now=$(date +%s)
  kill -0 "$FB_PID" 2>/dev/null || { echo "filebrowser died"; break; }
  if find "$SITEDIR" -type f -newermt "@$last_active" ! -path '*/.git/*' -print -quit 2>/dev/null | grep -q .; then last_active=$now; fi
  if grep -qE "\" (GET|POST|PUT|DELETE) " /tmp/filebrowser.log 2>/dev/null; then :; fi
  if [ $(( now - last_cd )) -ge $CD_EVERY ]; then commit_and_deploy; last_cd=$now; fi
  [ $(( now - last_active )) -ge $idle_limit ] && { echo "idle - stopping"; break; }
  [ $(( now - start )) -ge $MAX ] && { echo "max time - stopping"; break; }
done

echo "::group::Final commit + deploy"
commit_and_deploy
echo "::endgroup::"
git -C "$GITHUB_WORKSPACE" push -q origin --delete "$SESS_BRANCH" 2>/dev/null || true
echo "session ended for $DOMAIN"
