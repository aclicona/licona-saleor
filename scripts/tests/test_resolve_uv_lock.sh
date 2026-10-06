#!/bin/sh
# test_resolve_uv_lock.sh — pruebas de scripts/resolve-uv-lock.sh (B-567).
# Repos git desechables con `*.lock -merge` y un uv falso. Uso: sh scripts/tests/test_resolve_uv_lock.sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
GUION="$DIR/../resolve-uv-lock.sh"
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT HUP INT TERM

cat >"$T/fakeuv" <<'FAKE'
#!/bin/sh
echo llamado >>"$T/uv_llamadas"
[ "${FAKE_UV_FALLA:-0}" = 1 ] && exit 1
{ cat uv.lock; echo "dep-del-fork"; } >uv.lock.new && mv uv.lock.new uv.lock
FAKE
chmod +x "$T/fakeuv"

# repo <dir> <archivos que también conflictúan, p.ej. "pyproject.toml"> : deja un merge en curso.
repo() {
  mkdir -p "$1" && cd "$1" || exit 2
  git init -q . && git config user.email t@t && git config user.name t
  printf '*.lock -merge\n' >.gitattributes
  echo base >uv.lock; echo base >pyproject.toml; echo base >otro.py
  printf 'FROM x\nCOPY --from=ghcr.io/astral-sh/uv:9.8.7@sha256:abc /uv /bin/\n' >Dockerfile
  git add -A && git commit -qm base
  git checkout -q -b up
  echo upstream >uv.lock
  for F in $2; do echo upstream >"$F"; done
  git add -A && git commit -qm up && git tag 3.99.0
  git checkout -q -b fork HEAD~1 2>/dev/null || git checkout -q -b fork master
  echo fork >uv.lock
  for F in $2; do echo fork >"$F"; done
  git add -A && git commit -qm fork
  git merge --no-commit --no-ff refs/tags/3.99.0 >/dev/null 2>&1
  cd - >/dev/null
}

FALLOS=0
verifica() { # nombre cond
  if eval "$2"; then echo "ok   - $1"; else echo "FALLA - $1"; FALLOS=$((FALLOS + 1)); fi
}

# 1: solo uv.lock en conflicto
repo "$T/r1" ""
( cd "$T/r1" && T="$T" UV_CMD="$T/fakeuv" sh "$GUION" 3.99.0 >"$T/o1" 2>&1; echo $? >"$T/c1" )
verifica "solo uv.lock: sale 0" '[ "$(cat $T/c1)" = 0 ]'
verifica "solo uv.lock: sin conflictos restantes" '[ -z "$(git -C $T/r1 diff --name-only --diff-filter=U)" ]'
verifica "solo uv.lock: parte del lock de upstream + uv" '[ "$(cat $T/r1/uv.lock)" = "upstream
dep-del-fork" ]'
rm -f "$T/uv_llamadas"

# 2: uv.lock + otro archivo
repo "$T/r2" "otro.py"
( cd "$T/r2" && T="$T" UV_CMD="$T/fakeuv" sh "$GUION" 3.99.0 >/dev/null 2>&1; echo $? >"$T/c2" )
verifica "uv.lock + otro: sale 0" '[ "$(cat $T/c2)" = 0 ]'
verifica "uv.lock + otro: solo otro.py sigue en conflicto" '[ "$(git -C $T/r2 diff --name-only --diff-filter=U)" = "otro.py" ]'

# 3: pyproject.toml en conflicto: no se toca, uv no se llama
rm -f "$T/uv_llamadas"
repo "$T/r3" "pyproject.toml"
( cd "$T/r3" && T="$T" UV_CMD="$T/fakeuv" sh "$GUION" 3.99.0 >/dev/null 2>&1; echo $? >"$T/c3" )
verifica "pyproject en conflicto: sale 1" '[ "$(cat $T/c3)" = 1 ]'
verifica "pyproject en conflicto: uv no se llamó" '[ ! -f $T/uv_llamadas ]'
verifica "pyproject en conflicto: uv.lock sigue en conflicto" 'git -C $T/r3 diff --name-only --diff-filter=U | grep -qx uv.lock'

# 4: uv falla: restaura y sale 1
repo "$T/r4" ""
( cd "$T/r4" && T="$T" FAKE_UV_FALLA=1 UV_CMD="$T/fakeuv" sh "$GUION" 3.99.0 >/dev/null 2>&1; echo $? >"$T/c4" )
verifica "uv falla: sale 1" '[ "$(cat $T/c4)" = 1 ]'
verifica "uv falla: uv.lock conserva su conflicto" 'git -C $T/r4 diff --name-only --diff-filter=U | grep -qx uv.lock'
verifica "uv falla: contenido restaurado (lado fork)" '[ "$(cat $T/r4/uv.lock)" = fork ]'

# 5: sin conflicto de uv.lock
mkdir "$T/r5" && ( cd "$T/r5" && git init -q . && T="$T" UV_CMD="$T/fakeuv" sh "$GUION" 3.99.0 >"$T/o5" 2>&1; echo $? >"$T/c5" )
verifica "sin conflicto de uv.lock: sale 0" '[ "$(cat $T/c5)" = 0 ]'

# 6: versión de uv leída del Dockerfile
cat >"$T/uvstub" <<'S'
#!/bin/sh
echo "ARGS: $*" >"$T/uvargs"
{ cat uv.lock; echo x; } >uv.lock.new && mv uv.lock.new uv.lock
S
chmod +x "$T/uvstub"; mkdir -p "$T/bin"; cp "$T/uvstub" "$T/bin/uv"
repo "$T/r6" ""
( cd "$T/r6" && T="$T" PATH="$T/bin:$PATH" sh "$GUION" 3.99.0 >/dev/null 2>&1 )
verifica "versión de uv leída del Dockerfile" 'grep -q "uv@9.8.7 lock" $T/uvargs'

echo
if [ "$FALLOS" -eq 0 ]; then echo "todo verde"; exit 0; fi
echo "$FALLOS fallo(s)"; exit 1
