#!/bin/bash
# Provision a brand-new static site for the Conan hub, end to end:
#   1. scaffold sites/<domain>/ in the private content repo from templates/blank
#   2. create its Cloudflare Pages project (<domain-with-hyphens>) and deploy it
#   3. register it in this repo's sites.json (with a random editor slug) so the
#      hub lists it and its 檔案 editor works immediately.
# Inputs (env): DOMAIN (e.g. newcustomer.com), TITLE (display name, optional),
# CONTENT_DEPLOY_KEY, CF_PAGES_TOKEN, CF_ACCOUNT_ID. GITHUB_TOKEN pushes sites.json.
set -uo pipefail
cd "${GITHUB_WORKSPACE:-$PWD}"
WS="$PWD"

[ -n "${DOMAIN:-}" ] || { echo "FATAL: DOMAIN not set"; exit 1; }
# Normalise: lowercase, keep only a-z 0-9 . -
DOMAIN=$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9.-' | sed 's/^[.-]*//; s/[.-]*$//')
[ -n "$DOMAIN" ] || { echo "FATAL: DOMAIN empty after sanitising"; exit 1; }
TITLE="${TITLE:-$DOMAIN}"
[ -n "$TITLE" ] || TITLE="$DOMAIN"
PROJ=$(printf '%s' "$DOMAIN" | tr '.' '-')
# Pages project names: <=58 chars, lowercase alnum + hyphen.
PROJ=$(printf '%s' "$PROJ" | cut -c1-58 | sed 's/[^a-z0-9-]/-/g; s/^-*//; s/-*$//')
SLUG=$(openssl rand -hex 16)
echo "domain=$DOMAIN  title=$TITLE  project=$PROJ  slug=$SLUG"

echo "::group::Scaffold content folder"
mkdir -p ~/.ssh
printf '%s\n' "$CONTENT_DEPLOY_KEY" > ~/.ssh/content_key
chmod 600 ~/.ssh/content_key
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/content_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
git clone --depth 1 git@github.com:ryx168/conan-static-sites.git /tmp/content 2>&1 | tail -1
SITEDIR="/tmp/content/sites/$DOMAIN"
if [ -d "$SITEDIR" ]; then
  echo "  sites/$DOMAIN already exists in the content repo - reusing it (no overwrite)"
else
  mkdir -p "$SITEDIR"
  cp -a "$WS/templates/blank/." "$SITEDIR/"
  # Fill placeholders. Use a non-/ sed delimiter so a domain is safe.
  sed -i "s|{{TITLE}}|$TITLE|g; s|{{DOMAIN}}|$DOMAIN|g" "$SITEDIR/index.html"
  ( cd /tmp/content
    git config user.email superesolutions@gmail.com
    git config user.name "conan editor"
    git add -A "sites/$DOMAIN"
    git commit -q -m "New site: $DOMAIN"
    git push -q origin HEAD:main && echo "  content pushed" || { echo "  content push FAILED"; exit 1; }
  ) || exit 1
fi
echo "::endgroup::"

echo "::group::Cloudflare Pages project + deploy"
sudo npm i -g wrangler@4.120.1 >/tmp/wi.log 2>&1 && wrangler --version || { echo "wrangler install failed"; tail -5 /tmp/wi.log; }
export CLOUDFLARE_API_TOKEN="$CF_PAGES_TOKEN" CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"
# Create the project (idempotent: ignore "already exists").
wrangler pages project create "$PROJ" --production-branch main >/tmp/create.log 2>&1 \
  && echo "  project created: $PROJ" \
  || { grep -qiE "already|exists|conflict" /tmp/create.log && echo "  project already exists: $PROJ" || { echo "  project create FAILED:"; tail -8 /tmp/create.log; }; }
# Deploy from a clean, runner-owned copy (SFTP/clone ownership quirks aside).
sudo rm -rf /tmp/pub; mkdir -p /tmp/pub
sudo cp -a "$SITEDIR/." /tmp/pub/ 2>/dev/null
sudo chown -R "$(id -un):$(id -gn)" /tmp/pub 2>/dev/null
rm -rf /tmp/pub/.git
if wrangler pages deploy /tmp/pub --project-name "$PROJ" --branch main --commit-dirty=true >/tmp/deploy.log 2>&1; then
  echo "  deployed to Pages ($PROJ)"
else
  echo "  deploy FAILED:"; tail -15 /tmp/deploy.log; exit 1
fi
PAGES_URL="https://$PROJ.pages.dev/"
echo "  live at $PAGES_URL"
echo "::endgroup::"

echo "::group::Register in sites.json"
cd "$WS"
[ -f sites.json ] || echo '[]' > sites.json
python3 - "$DOMAIN" "$SLUG" "$PAGES_URL" "$TITLE" <<'PY'
import json, sys, datetime
domain, slug, url, title = sys.argv[1:5]
try:
    data = json.load(open("sites.json"))
    if not isinstance(data, list): data = []
except Exception:
    data = []
data = [x for x in data if x.get("d") != domain]   # replace any prior entry
data.append({
    "d": domain, "slug": slug, "view": url, "title": title,
    "created": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
})
json.dump(data, open("sites.json", "w"), ensure_ascii=False, indent=2)
print("  sites.json entries:", len(data))
PY
git config user.email superesolutions@gmail.com
git config user.name "conan editor"
git add sites.json
git commit -q -m "Register new site: $DOMAIN" || echo "  nothing to commit"
git push -q origin HEAD:main && echo "  sites.json pushed" || echo "  sites.json push FAILED (check contents:write)"
echo "::endgroup::"

echo "DONE: $DOMAIN -> $PAGES_URL (slug $SLUG)"
