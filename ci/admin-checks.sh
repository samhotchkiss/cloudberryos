#!/usr/bin/env bash
# M4 acceptance gate (docs/packaging-goal.md "M4 -- Admin panel", Acceptance
# section) -- the plain-Docker parts: auth/CSRF/round-trip against a
# directly-run cloudberryos-admin, and the mocked-tailscale serve/degrade
# invocation test. No systemd or NET_ADMIN needed here (the child-UID
# firewall-refusal assertion is Block C, ci/services-checks-admin.sh, in the
# systemd container).
#
# Runs INSIDE a single ubuntu:26.04 container already apt-get installed with:
#   python3 python3-pytest squid nftables adduser sudo libglib2.0-bin dbus \
#   xdg-utils curl iproute2
#
# Like ci/setup-stage.sh, this "fake installs" the repo's proposed package
# layout onto real filesystem paths (see docs/packaging-goal.md "Package
# layout") so cloudberryos-setup/cloudberryos-admin resolve exactly as they
# will from the real .deb. Destructive to the container's /usr, /etc, /var,
# /home -- never run outside a throwaway container.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

step() { echo; echo "=== admin-checks step: $1 ==="; }
fail() { echo "FAIL: $1" >&2; exit 1; }

ADMIN_SERVER_PID=""
cleanup() {
  if [[ -n "$ADMIN_SERVER_PID" ]] && kill -0 "$ADMIN_SERVER_PID" 2>/dev/null; then
    kill "$ADMIN_SERVER_PID" 2>/dev/null || true
    wait "$ADMIN_SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fake-install the proposed package layout (same set as ci/setup-stage.sh,
# plus cloudberryos-admin + its unit).
# ---------------------------------------------------------------------------
step "stage the proposed package layout onto real filesystem paths"
install -d /usr/bin /usr/sbin /usr/libexec/cloudberryos /usr/lib/systemd/system \
  /usr/share/cloudberryos/tools /usr/share/cloudberryos/config /usr/share/cloudberryos/assets/icons \
  /usr/share/applications /usr/share/doc/cloudberryos /usr/share/backgrounds \
  /usr/share/icons/hicolor/scalable/apps

install -m 0755 usr/bin/cloudberryos-setup /usr/bin/cloudberryos-setup
install -m 0755 usr/bin/cloudberryos-browser /usr/bin/cloudberryos-browser
install -m 0755 usr/bin/cloudberryos-admin /usr/bin/cloudberryos-admin
install -m 0755 tools/cloudberryos-resource.py /usr/bin/cloudberryos-resource
install -m 0755 usr/sbin/cloudberryos-apply /usr/sbin/cloudberryos-apply
install -m 0755 usr/libexec/cloudberryos/cloudberryos-firewall-apply /usr/libexec/cloudberryos/cloudberryos-firewall-apply
install -m 0644 usr/lib/systemd/system/cloudberryos-firewall.service /usr/lib/systemd/system/cloudberryos-firewall.service
install -m 0644 "usr/lib/systemd/system/cloudberryos-home@.service" "/usr/lib/systemd/system/cloudberryos-home@.service"
install -m 0644 usr/lib/systemd/system/cloudberryos-admin.service /usr/lib/systemd/system/cloudberryos-admin.service
install -m 0644 usr/share/applications/cloudberryos-browser.desktop /usr/share/applications/cloudberryos-browser.desktop
install -m 0644 usr/share/applications/cloudberryos-home.desktop /usr/share/applications/cloudberryos-home.desktop

install -m 0755 tools/build.py /usr/share/cloudberryos/tools/build.py
install -m 0755 tools/cloudberryos-resource.py /usr/share/cloudberryos/tools/cloudberryos-resource.py
install -m 0644 tools/cloudberryos_common.py /usr/share/cloudberryos/tools/cloudberryos_common.py
install -m 0755 tools/polish_user.sh /usr/share/cloudberryos/tools/polish_user.sh
install -m 0644 config/resources.json /usr/share/cloudberryos/config/resources.json

install -m 0644 assets/cloudberryos-home.css /usr/share/cloudberryos/assets/cloudberryos-home.css
install -m 0644 assets/cloudberryos-wallpaper-3840.png /usr/share/cloudberryos/assets/cloudberryos-wallpaper-3840.png
install -m 0644 assets/icons/*.svg /usr/share/cloudberryos/assets/icons/
ln -sf /usr/share/cloudberryos/assets/cloudberryos-wallpaper-3840.png /usr/share/backgrounds/cloudberryos.png
for icon in assets/icons/*.svg; do
  install -m 0644 "$icon" "/usr/share/icons/hicolor/scalable/apps/$(basename "$icon")"
done
install -m 0644 docs/apps.md /usr/share/cloudberryos/apps.md

# ---------------------------------------------------------------------------
# Non-interactive setup with the admin panel on (local -- no real tailscale
# here). systemd is unavailable in plain Docker, so service enable/start is
# deferred, but admin-token creation happens regardless (see
# cloudberryos-setup's admin-panel block, which is NOT gated on `deferred`).
# ---------------------------------------------------------------------------
step "non-interactive cloudberryos-setup --admin-panel local"
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel local

test -f /etc/cloudberryos/admin-token || fail "admin-token was not created"
mode="$(stat -c '%a' /etc/cloudberryos/admin-token)"
[[ "$mode" == "600" ]] || fail "expected /etc/cloudberryos/admin-token mode 600, got $mode"
echo "confirmed: /etc/cloudberryos/admin-token exists, mode 600"

# ---------------------------------------------------------------------------
# Start cloudberryos-admin directly (no systemd here) and wait for it.
# ---------------------------------------------------------------------------
step "start cloudberryos-admin serve"
cloudberryos-admin serve > /tmp/cloudberryos-admin.log 2>&1 &
ADMIN_SERVER_PID=$!
ready=0
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null http://127.0.0.1:8766/admin 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.3
done
[[ "$ready" -eq 1 ]] || { cat /tmp/cloudberryos-admin.log >&2; fail "cloudberryos-admin never answered on 127.0.0.1:8766"; }
echo "confirmed: cloudberryos-admin is listening on 127.0.0.1:8766"

# ---------------------------------------------------------------------------
# Every API endpoint (including GET /api/status) rejects unauthenticated
# requests with 401. GET /admin itself is exempt (it must serve the login
# form to an unauthenticated visitor).
# ---------------------------------------------------------------------------
step "every /api/* endpoint rejects unauthenticated requests with 401"
admin_page_status="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8766/admin)"
[[ "$admin_page_status" == "200" ]] || fail "expected GET /admin (no session) to serve the login form (200), got $admin_page_status"

for path in "/api/status" "/api/resources" "/api/blocked?n=5" "/api/export"; do
  status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8766${path}")"
  [[ "$status" == "401" ]] || fail "expected 401 for unauthenticated GET $path, got $status"
done
for path_method in "POST /api/resources" "PUT /api/resources" "DELETE /api/resources" "POST /api/resources/reorder" "POST /api/videos" "POST /api/apply" "POST /api/import"; do
  method="${path_method%% *}"
  path="${path_method#* }"
  status="$(curl -s -o /dev/null -w '%{http_code}' -X "$method" -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:8766${path}")"
  [[ "$status" == "401" ]] || fail "expected 401 for unauthenticated $method $path, got $status"
done
echo "confirmed: every /api/* endpoint (GET and state-changing) rejects unauthenticated requests with 401"

# ---------------------------------------------------------------------------
# Login: wrong token rejected; correct token (constant-time compare) issues
# an HttpOnly SameSite=Strict session cookie.
# ---------------------------------------------------------------------------
step "login: wrong token rejected (401), correct token issues a session cookie"
TOKEN="$(cat /etc/cloudberryos/admin-token)"
COOKIEJAR="$(mktemp)"

wrong_status="$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "token=not-the-real-token" http://127.0.0.1:8766/admin)"
[[ "$wrong_status" == "401" ]] || fail "expected 401 for a wrong token, got $wrong_status"

login_headers="$(curl -s -D - -o /dev/null -c "$COOKIEJAR" -X POST -d "token=${TOKEN}" http://127.0.0.1:8766/admin)"
grep -qi '^HTTP/1.1 303' <<<"$login_headers" || fail "expected 303 redirect after a correct login; headers were: $login_headers"
grep -qi 'Set-Cookie:.*cb_session=.*HttpOnly.*SameSite=Strict' <<<"$login_headers" || fail "session cookie missing HttpOnly/SameSite=Strict: $login_headers"
grep -q cb_session "$COOKIEJAR" || fail "no cb_session cookie recorded in the cookie jar after login"
echo "confirmed: wrong token -> 401; correct token -> 303 + HttpOnly SameSite=Strict cb_session cookie"

step "extract the CSRF token embedded in the authenticated /admin page"
APP_PAGE="$(curl -s -b "$COOKIEJAR" http://127.0.0.1:8766/admin)"
CSRF="$(grep -oE 'name="csrf-token" content="[^"]*"' <<<"$APP_PAGE" | sed -E 's/.*content="([^"]*)".*/\1/')"
[[ -n "$CSRF" ]] || fail "could not extract a CSRF token from the authenticated /admin page"
echo "confirmed: authenticated /admin page embeds a CSRF token"

step "a state-changing request without a CSRF token is rejected (403)"
csrf_missing_status="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIEJAR" -X POST -H 'Content-Type: application/json' \
  -d '{"title":"Should Not Be Added"}' http://127.0.0.1:8766/api/resources)"
[[ "$csrf_missing_status" == "403" ]] || fail "expected 403 for a state-changing request with a valid session but no CSRF token, got $csrf_missing_status"
grep -q "Should Not Be Added" /etc/cloudberryos/resources.json && fail "the CSRF-less request should NOT have been applied"
echo "confirmed: state-changing request without CSRF token -> 403, and nothing was written"

step "authenticated GET now succeeds (e.g. GET /api/status)"
status_code="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIEJAR" http://127.0.0.1:8766/api/status)"
[[ "$status_code" == "200" ]] || fail "expected 200 for authenticated GET /api/status, got $status_code"
echo "confirmed: authenticated GET /api/status -> 200"

# ---------------------------------------------------------------------------
# Full authenticated round trip: add-site -> edit-by-title (PUT) -> apply ->
# regenerated allowed-domains.txt reflects the change.
# ---------------------------------------------------------------------------
step "authenticated round trip: add-site -> edit-by-title (PUT) -> apply -> allowed-domains.txt updated"
add_status="$(curl -s -o /tmp/admin-add.json -w '%{http_code}' -b "$COOKIEJAR" -X POST \
  -H 'Content-Type: application/json' -H "X-CSRF-Token: ${CSRF}" \
  -d '{"title":"CI Marker Site","url":"https://ci-marker.example.org/","category":"Explore","summary":"Added by ci/admin-checks.sh","allow_domains":["ci-marker.example.org"]}' \
  http://127.0.0.1:8766/api/resources)"
[[ "$add_status" == "201" ]] || fail "add-site (POST /api/resources) expected 201, got $add_status: $(cat /tmp/admin-add.json)"
grep -q "CI Marker Site" /etc/cloudberryos/resources.json || fail "add-site did not persist to resources.json"

edit_status="$(curl -s -o /tmp/admin-edit.json -w '%{http_code}' -b "$COOKIEJAR" -X PUT \
  -H 'Content-Type: application/json' -H "X-CSRF-Token: ${CSRF}" \
  -d '{"title":"CI Marker Site","summary":"Edited by ci/admin-checks.sh","allow_domains":["ci-marker.example.org","ci-marker-2.example.org"]}' \
  http://127.0.0.1:8766/api/resources)"
[[ "$edit_status" == "200" ]] || fail "edit-by-title (PUT /api/resources) expected 200, got $edit_status: $(cat /tmp/admin-edit.json)"
grep -q "ci-marker-2.example.org" /etc/cloudberryos/resources.json || fail "PUT edit did not persist the new allow_domains entry"

apply_status="$(curl -s -o /tmp/admin-apply.json -w '%{http_code}' -b "$COOKIEJAR" -X POST \
  -H 'Content-Type: application/json' -H "X-CSRF-Token: ${CSRF}" -d '{}' \
  http://127.0.0.1:8766/api/apply)"
[[ "$apply_status" == "200" ]] || fail "POST /api/apply expected 200, got $apply_status: $(cat /tmp/admin-apply.json)"
grep -q "ci-marker-2.example.org" /etc/cloudberryos/allowed-domains.txt || fail "regenerated allowed-domains.txt does not reflect the PUT-edited allow_domains"
echo "confirmed: add-site -> PUT edit-by-title -> apply -> allowed-domains.txt reflects the change"

# ---------------------------------------------------------------------------
# No non-loopback listener.
# ---------------------------------------------------------------------------
step "assert: no non-loopback listener on port 8766"
listeners="$(ss -tln 2>/dev/null | awk '$4 ~ /:8766$/')"
echo "listeners on :8766 -> ${listeners:-<none>}"
grep -q '127\.0\.0\.1:8766' <<<"$listeners" || fail "expected a 127.0.0.1:8766 listener, found none: $listeners"
non_loopback="$(grep -v '127\.0\.0\.1:8766' <<<"$listeners" || true)"
[[ -z "$non_loopback" ]] || fail "found a non-loopback listener on port 8766: $non_loopback"
echo "confirmed: cloudberryos-admin listens only on 127.0.0.1:8766"

step "stop cloudberryos-admin"
kill "$ADMIN_SERVER_PID"
wait "$ADMIN_SERVER_PID" 2>/dev/null || true
ADMIN_SERVER_PID=""

# ---------------------------------------------------------------------------
# Tailnet invocation with a mocked tailscale binary: assert the exact
# recorded serve command; then assert clean degrade-to-local when tailscale
# is down, and when it is absent entirely.
# ---------------------------------------------------------------------------
step "tailnet: mocked tailscale up -> setup invokes 'tailscale serve --bg 8766'"
MOCK_TAILSCALE="$REPO_ROOT/tests/fixtures/mock-tailscale"
TAILSCALE_LOG="$(mktemp)"
rm -f "$TAILSCALE_LOG"
CLOUDBERRYOS_TAILSCALE_BIN="$MOCK_TAILSCALE" CLOUDBERRYOS_TAILSCALE_LOG="$TAILSCALE_LOG" MOCK_TAILSCALE_UP=1 MOCK_TAILSCALE_MAGICDNS=1 \
  cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
    --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel tailnet
grep -qx "serve --bg 8766" "$TAILSCALE_LOG" || fail "expected 'tailscale serve --bg 8766' to have been invoked; log was: $(cat "$TAILSCALE_LOG")"
python3 - <<'PY'
import json
profile = json.load(open("/etc/cloudberryos/profile.json"))
assert profile.get("admin_panel") == "tailnet", profile
print("confirmed: profile.json admin_panel == tailnet, and the mock recorded the exact serve invocation")
PY

step "tailnet degrade: mocked tailscale DOWN -> setup falls back to local (no failure)"
rm -f "$TAILSCALE_LOG"
CLOUDBERRYOS_TAILSCALE_BIN="$MOCK_TAILSCALE" CLOUDBERRYOS_TAILSCALE_LOG="$TAILSCALE_LOG" MOCK_TAILSCALE_UP=0 \
  cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
    --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel tailnet
if grep -qx "serve --bg 8766" "$TAILSCALE_LOG"; then
  fail "'tailscale serve' should NOT have been invoked when tailscale is down"
fi
python3 - <<'PY'
import json
profile = json.load(open("/etc/cloudberryos/profile.json"))
assert profile.get("admin_panel") == "local", profile
print("confirmed: tailscale down -> setup degraded to admin_panel == local, no failure")
PY

step "tailnet degrade: tailscale ABSENT (no mock, nothing on PATH) -> setup falls back to local (no failure)"
command -v tailscale >/dev/null 2>&1 && fail "a real 'tailscale' binary is unexpectedly on PATH in this container -- test assumption violated"
unset CLOUDBERRYOS_TAILSCALE_BIN
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel tailnet
python3 - <<'PY'
import json
profile = json.load(open("/etc/cloudberryos/profile.json"))
assert profile.get("admin_panel") == "local", profile
print("confirmed: tailscale absent -> setup degraded to admin_panel == local, no failure")
PY

echo
echo "=== M4 acceptance gate (plain Docker: auth/CSRF/round-trip + tailscale mock/degrade): ALL STEPS PASSED ==="
