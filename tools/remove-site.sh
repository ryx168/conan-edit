#!/bin/bash
# Remove a hub-created static site, reversing new-site.sh:
#   1. refuse unless the domain is registered in sites.json (never touch a
#      built-in / hand-managed site)
#   2. delete its Cloudflare Pages project
#   3. delete sites/<domain>/ from the private content repo
#   4. deregister it from sites.json
# Inputs (env): DOMAIN, CONTENT_DEPLOY_KEY, CF_PAGES_TOKEN, CF_ACCOUNT_ID.
set -uo pipefail
cd "${GITHUB_WORKSPACE:-$PWD}"
WS="$PWD"

[ -n "${DOMAIN:-}" ] || { echo "FATAL: DOMAIN not set"; exit 1; }
DOMAIN=$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9.-' | sed 's/^[.-]*//; s/[.-]*$//')
[ -n "$DOMAIN" ] || { echo "FATAL: DOMAIN empty"; exit 1; }
PROJ=$(printf '%s' "$DOMAIN" | tr '.' '-' | cut -c1-58 | sed 's/[^a-z0-9-]/-/g; s/^-*//; s/-*$//')
echo "removing domain=$DOMAIN project=$PROJ"

# Safety gate: only remove sites that this wizard created (present in sites.json).
[ -f sites.json ] || echo '[]' > sites.json
if ! python3 -c "import json,sys; d=json.load(open('sites.json')); sys.exit(0 if any(x.get('d')==sys.argv[1] for x in d) else 1)" "$DOMAIN"; then
  echo "FATAL: $DOMAIN is not a hub-created site (not in sites.json) - refusing to remove"; exit 1
fi

echo "::group::Delete Pages project"
sudo npm i -g wrangler@4.120.1 >/tmp/wi.log 2>&1 && wrangler --version || { echo "wrangler install failed"; tail -5 /tmp/wi.log; }
export CLOUDFLARE_API_TOKEN="$CF_PAGES_TOKEN" CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"
wrangler pages project delete "$PROJ" --yes >/tmp/del.log 2>&1 \
  && echo "  deleted project $PROJ" \
  || { grep -qiE "not found|does not exist|8000007|could not" /tmp/del.log && echo "  project already gone: $PROJ" || { echo "  project delete FAILED:"; tail -8 /tmp/del.log; }; }
echo "::endgroup::"

echo "::group::Remove content folder"
mkdir -p ~/.ssh
printf '%s\n' "$CONTENT_DEPLOY_KEY" > ~/.ssh/content_key
chmod 600 ~/.ssh/content_key
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/content_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
git clone --depth 1 git@github.com:ryx168/conan-static-sites.git /tmp/content 2>&1 | tail -1
if [ -d "/tmp/content/sites/$DOMAIN" ]; then
  ( cd /tmp/content
    git config user.email superesolutions@gmail.com
    git config user.name "conan editor"
    git rm -rq "sites/$DOMAIN"
    git commit -q -m "Remove site: $DOMAIN"
    git push -q origin HEAD:main && echo "  content folder removed" || echo "  content push FAILED"
  )
else
  echo "  no content folder for $DOMAIN"
fi
echo "::endgroup::"

echo "::group::Deregister from sites.json"
cd "$WS"
python3 - "$DOMAIN" <<'PY'
import json, sys
domain = sys.argv[1]
try:
    data = json.load(open("sites.json"))
    if not isinstance(data, list): data = []
except Exception:
    data = []
data = [x for x in data if x.get("d") != domain]
json.dump(data, open("sites.json", "w"), ensure_ascii=False, indent=2)
print("  remaining entries:", len(data))
PY
git config user.email superesolutions@gmail.com
git config user.name "conan editor"
git add sites.json
git commit -q -m "Deregister site: $DOMAIN" || echo "  nothing to commit"
git push -q origin HEAD:main && echo "  sites.json pushed" || echo "  sites.json push FAILED"
echo "::endgroup::"

echo "DONE: removed $DOMAIN"
