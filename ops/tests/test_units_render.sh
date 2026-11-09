#!/bin/bash
# glm53-units.sh: the lab hosts.conf renders each unit byte for byte as committed before the templates
# (tests/golden/), a fixture fills every field, and a missing name or file refuses.
# Usage: bash tests/test_units_render.sh -> PASS/FAIL per check, exit = FAILs
# shellcheck disable=SC2016,SC2034  # check() evals its single-quoted conditions on purpose
set -u
H="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
F=0; pass(){ echo "PASS $*"; }; fail(){ echo "FAIL $*"; F=$((F+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1"; fi; }
R(){ env -i PATH="$PATH" HOME="$HOME" bash "$H/glm53-units.sh" "$@"; }

# 1. the lab golden copies (skipped where there is no lab hosts.conf: the published tree)
if [ -r "$H/hosts.conf" ] && [ -d "$H/tests/golden" ]; then
  R render "$T/lab" "$H/hosts.conf" >/dev/null
  for g in "$H"/tests/golden/*.service; do
    n=$(basename "$g")
    check "lab $n is byte-identical to tests/golden/$n" 'cmp -s "$g" "$T/lab/$n"'
  done
else
  echo "SKIP the lab golden check (no $H/hosts.conf or $H/tests/golden)"
fi

# 2. a fixture fills every field
cat > "$T/fixture.conf" <<'X'
GLM_USER=svc
GLM_USER_HOME=/srv/svc
GLM_HOME=/srv/svc/glm
GLM_WORKER=svc@192.0.2.2
GLM_WORKER2=svc@192.0.2.3
X
R render "$T/fx" "$T/fixture.conf" >/dev/null
u="$T/fx/glm53-serve.service"; w="$T/fx/glm53-watchdog.service"
check "fixture: no field is left" '[ -s "$u" ] && [ -s "$w" ] && ! grep -q "@GLM_" "$u" "$w"'
check "fixture: serve User, Group, HOME, WorkingDirectory" 'grep -qx "User=svc" "$u" && grep -qx "Group=svc" "$u" && grep -qx "Environment=HOME=/srv/svc" "$u" && grep -qx "WorkingDirectory=/srv/svc/glm/kit" "$u"'
check "fixture: serve pre-steps under GLM_HOME/bin" 'grep -qx "ExecStartPre=/bin/bash /srv/svc/glm/bin/glm53-prestart.sh" "$u" && grep -qx "ExecStartPre=/bin/bash /srv/svc/glm/bin/glm53-memguard.sh start" "$u"'
check "fixture: serve stops both workers" '[ "$(grep -c "^ExecStopPost=-/usr/bin/ssh .* svc@192.0.2.[23] " "$u")" = 2 ]'
check "fixture: serve Description names the worker host" 'grep -q "^Description=.* 192.0.2.2 over ssh$" "$u"'
check "fixture: watchdog unit" 'grep -qx "User=svc" "$w" && grep -qx "ExecStart=/bin/bash /srv/svc/glm/bin/glm53-watchdog.sh" "$w"'
check "fixture: a % stays as written (systemd needs %%s)" 'grep -q "date +%%s" "$u"'

# 3. refusals
grep -v '^GLM_WORKER2=' "$T/fixture.conf" > "$T/short.conf"
check "a name hosts.conf does not set refuses" '! R render "$T/x1" "$T/short.conf" 2>/dev/null && R render "$T/x2" "$T/short.conf" 2>&1 | grep -q "does not set GLM_WORKER2"'
check "a hosts.conf that cannot be read refuses" '! R render "$T/x3" "$T/none.conf" 2>/dev/null && R render "$T/x4" "$T/none.conf" 2>&1 | grep -q "cannot read"'
check "no arguments: usage, exit 2" 'R >/dev/null 2>&1; [ $? = 2 ]'

# 4. a template field no value fills: exit 2 and no unit file written (a copy of the renderer, so its templates are ours)
mkdir -p "$T/bogus"
cp "$H/glm53-units.sh" "$T/bogus/"
printf '[Unit]\nDescription=@GLM_BOGUS@\n' > "$T/bogus/x.service.in"
env -i PATH="$PATH" HOME="$HOME" bash "$T/bogus/glm53-units.sh" render "$T/bo" "$T/fixture.conf" >/dev/null 2>"$T/bo.err"; rc=$?
check "an unknown field in a template: exit 2, names the field" '[ "$rc" = 2 ] && grep -q "@GLM_BOGUS@" "$T/bo.err"'
check "an unknown field in a template: no .service file is written" '[ -z "$(find "$T/bo" -name "*.service" 2>/dev/null)" ]'

# 5. a value a unit line cannot carry refuses
sed 's#^GLM_USER=svc$#GLM_USER="svc x"#' "$T/fixture.conf" > "$T/space.conf"
check "a value with a space refuses" '! R render "$T/s1" "$T/space.conf" >/dev/null 2>&1 && R render "$T/s2" "$T/space.conf" 2>&1 | grep -q "GLM_USER has a space"'
{ grep -v '^GLM_HOME=' "$T/fixture.conf"; printf '%s\n' "GLM_HOME=\$'/srv/svc/glm\nExecStartPre=/bin/evil'"; } > "$T/nl.conf"
check "a value with an embedded newline refuses" '! R render "$T/n1" "$T/nl.conf" >/dev/null 2>&1 && R render "$T/n2" "$T/nl.conf" 2>&1 | grep -q "GLM_HOME has a space" && [ -z "$(find "$T/n1" -name "*.service" 2>/dev/null)" ]'
echo "RESULT: $F failed"
exit "$F"
