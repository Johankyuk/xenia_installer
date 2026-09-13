#!/usr/bin/env bash
# install-xenia.sh — Xenia Canary (build Windows) sobre umu + proton-cachyos
#
# Reproduce el setup completo:
#   - verifica dependencias del host
#   - descarga el release Windows más reciente de Xenia Canary
#   - genera el runner con offload a la dGPU (prime-run)
#   - primer arranque para materializar el config portable
#   - aplica config afinado (d3d12, 2x2, FXAA, idioma ES)
#   - descarga y activa los parches de Banjo-Kazooie: Nuts & Bolts
#   - registra el .desktop para el launcher de Noctalia
#
# Idempotente: se puede volver a correr sin romper nada.
# Sin `set -e` a propósito — cada paso aborta explícitamente.

# ---------------------------------------------------------------- parámetros

XENIA_ROOT="${XENIA_ROOT:-$HOME/Games/xenia}"
PROTONPATH="${PROTONPATH:-/usr/share/steam/compatibilitytools.d/proton-cachyos-slr}"
TITLE_ID="4D5307ED"
PATCH_NAME="${TITLE_ID} - Banjo-Kazooie Nuts & Bolts.patch.toml"
PATCH_URL="https://raw.githubusercontent.com/xenia-canary/game-patches/main/patches/${TITLE_ID}%20-%20Banjo-Kazooie%20Nuts%20%26%20Bolts.patch.toml"
ICON_URL="https://raw.githubusercontent.com/xenia-canary/xenia-canary/refs/heads/canary_experimental/assets/icon/256.png"
RELEASE_API="https://api.github.com/repos/xenia-canary/xenia-canary-releases/releases/latest"

# parches a activar (nombre exacto del campo `name` en el .patch.toml)
PATCHES_ON=("16x Anisotropic Filtering" "Disable Motion Blur")

FIRSTRUN_TIMEOUT=180
DO_FIRSTRUN=1
DO_POWERD=1
FORCE_DOWNLOAD=0

# ------------------------------------------------------------------- helpers

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32mOK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mAVISO\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFALLO\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "falta el comando '$1'${2:+ — instala: $2}"
}

usage() {
    cat <<'USAGE'
Uso: install-xenia.sh [opciones]

  --root DIR          raíz de instalación (default: ~/Games/xenia)
  --no-firstrun       no lanzar Xenia para generar el config
  --skip-powerd       no tocar nvidia-powerd
  --force-download    rebajar el .exe aunque ya exista
  -h, --help          esta ayuda
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --root)           XENIA_ROOT="$2"; shift 2 ;;
        --no-firstrun)    DO_FIRSTRUN=0; shift ;;
        --skip-powerd)    DO_POWERD=0; shift ;;
        --force-download) FORCE_DOWNLOAD=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "opción desconocida: $1" ;;
    esac
done

WIN_DIR="$XENIA_ROOT/win"
XENIA_EXE="$WIN_DIR/xenia_canary.exe"
XENIA_CONFIG="$WIN_DIR/xenia-canary.config.toml"
PATCH_DIR="$WIN_DIR/patches"
PATCH_FILE="$PATCH_DIR/$PATCH_NAME"
RUNNER="$XENIA_ROOT/run-xenia.sh"
DESKTOP_FILE="$HOME/.local/share/applications/xenia-canary.desktop"
ICON_FILE="$HOME/.local/share/icons/hicolor/256x256/apps/xenia-canary.png"

# --------------------------------------------------------- 1. dependencias

info "verificando dependencias del host"

need_cmd python3
need_cmd curl
need_cmd unzip
need_cmd prime-run "nvidia-prime / nvidia-utils"
need_cmd umu-run   "pacman -S umu-launcher"

[ -d "$PROTONPATH" ] || die "PROTONPATH inexistente: $PROTONPATH (pacman -S proton-cachyos-slr)"

if [ "$XDG_SESSION_TYPE" = "wayland" ]; then
    pgrep -af xwayland-satellite >/dev/null 2>&1 \
        || warn "xwayland-satellite no está corriendo — Xenia es X11 y no abrirá bajo niri"
fi

command -v nvidia-smi >/dev/null 2>&1 \
    && nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 \
    || warn "nvidia-smi no disponible — no puedo confirmar la dGPU"

ok "dependencias"

# -------------------------------------------------------- 2. nvidia-powerd

if [ "$DO_POWERD" -eq 1 ]; then
    if systemctl list-unit-files nvidia-powerd.service >/dev/null 2>&1; then
        if [ "$(systemctl is-active nvidia-powerd)" != "active" ]; then
            info "activando nvidia-powerd (Dynamic Boost)"
            sudo systemctl enable --now nvidia-powerd \
                || warn "no se pudo activar nvidia-powerd — la dGPU correrá sin los +25W"
        fi
        ok "nvidia-powerd: $(systemctl is-active nvidia-powerd)"
    else
        warn "nvidia-powerd.service no existe en este sistema"
    fi
fi

# ------------------------------------------------------------ 3. descarga

mkdir -p "$WIN_DIR" || die "no pude crear $WIN_DIR"

if [ -f "$XENIA_EXE" ] && [ "$FORCE_DOWNLOAD" -eq 0 ]; then
    ok "xenia_canary.exe ya presente (usa --force-download para rebajarlo)"
else
    info "descargando el release Windows más reciente"
    XENIA_ROOT="$XENIA_ROOT" RELEASE_API="$RELEASE_API" python3 - <<'PY' || die "descarga fallida"
import json, os, pathlib, sys, urllib.request

root = pathlib.Path(os.environ["XENIA_ROOT"])
api = os.environ["RELEASE_API"]

with urllib.request.urlopen(api, timeout=30) as r:
    data = json.load(r)

asset = next((a for a in data["assets"] if "windows" in a["name"].lower()), None)
if asset is None:
    print("sin asset windows en el release", data.get("tag_name"), file=sys.stderr)
    sys.exit(1)

dest = root / "xenia_canary_windows.zip"
urllib.request.urlretrieve(asset["browser_download_url"], dest)
print(f"tag {data['tag_name']} — {dest.name} {dest.stat().st_size // 1024} KB")
PY

    unzip -o "$XENIA_ROOT/xenia_canary_windows.zip" -d "$WIN_DIR/" >/dev/null \
        || die "unzip falló"
    [ -f "$XENIA_EXE" ] || die "el zip no contenía xenia_canary.exe"
    ok "xenia_canary.exe extraído"
fi

# -------------------------------------------------------------- 4. runner

info "generando el runner"

XENIA_ROOT="$XENIA_ROOT" RUNNER="$RUNNER" PROTONPATH="$PROTONPATH" python3 - <<'PY' || die "no pude escribir el runner"
import os, pathlib

runner = pathlib.Path(os.environ["RUNNER"])
root = os.environ["XENIA_ROOT"]
proton = os.environ["PROTONPATH"]

lines = [
    "#!/usr/bin/env bash",
    "# Xenia Canary (build Windows) via umu + proton-cachyos, offload a la dGPU",
    "# Generado por install-xenia.sh — no editar a mano.",
    "",
    f'XENIA_ROOT="{root}"',
    'XENIA_EXE="$XENIA_ROOT/win/xenia_canary.exe"',
    "",
    '[ -f "$XENIA_EXE" ] || { echo "FALLO: no existe $XENIA_EXE" >&2; exit 1; }',
    "",
    'export WINEPREFIX="$XENIA_ROOT/prefix"',
    "export GAMEID=0",
    f'export PROTONPATH="{proton}"',
    "export PROTON_ENABLE_NVAPI=1",
    "export SDL_VIDEODRIVER=x11",
    "",
    '[ -d "$PROTONPATH" ] || { echo "FALLO: PROTONPATH inexistente: $PROTONPATH" >&2; exit 1; }',
    "",
    'exec prime-run umu-run "$XENIA_EXE" "$@"',
]

runner.parent.mkdir(parents=True, exist_ok=True)
runner.write_text("\n".join(lines) + "\n")
runner.chmod(0o755)
print("escrito:", runner)
PY

bash -n "$RUNNER" || die "el runner tiene error de sintaxis"
ok "runner"

# ------------------------------------------------- 5. primer arranque

if [ ! -f "$XENIA_CONFIG" ]; then
    if [ "$DO_FIRSTRUN" -eq 0 ]; then
        die "no hay config y --no-firstrun está activo — lanza $RUNNER, ciérralo y vuelve a correr este script"
    fi

    info "primer arranque para generar el config (hasta ${FIRSTRUN_TIMEOUT}s, se creará el prefix)"
    "$RUNNER" >/dev/null 2>&1 &
    RUN_PID=$!

    elapsed=0
    while [ ! -f "$XENIA_CONFIG" ] && [ "$elapsed" -lt "$FIRSTRUN_TIMEOUT" ]; do
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ -f "$XENIA_CONFIG" ]; then
        sleep 3
        pkill -f xenia_canary.exe >/dev/null 2>&1
        kill "$RUN_PID" >/dev/null 2>&1
        wait "$RUN_PID" 2>/dev/null
        sleep 2
        ok "config generado tras ${elapsed}s"
    else
        pkill -f xenia_canary.exe >/dev/null 2>&1
        kill "$RUN_PID" >/dev/null 2>&1
        die "el config no apareció en ${FIRSTRUN_TIMEOUT}s — lanza $RUNNER a mano y revisa $WIN_DIR/xenia.log"
    fi
else
    ok "config ya existe"
fi

pgrep -f xenia_canary.exe >/dev/null 2>&1 \
    && die "Xenia está corriendo — ciérralo antes de continuar (reescribe el config al salir)"

# -------------------------------------------------------------- 6. config

info "aplicando config"

cp -n "$XENIA_CONFIG" "${XENIA_CONFIG}.bak" 2>/dev/null

XENIA_CONFIG="$XENIA_CONFIG" python3 - <<'PY' || die "no pude aplicar el config"
import os, pathlib, re, sys

p = pathlib.Path(os.environ["XENIA_CONFIG"])
s = p.read_text()

cambios = {
    "gpu":                        '"d3d12"',    # backend maduro, via vkd3d-proton
    "draw_resolution_scale_x":    "2",          # 3x3 no cabe en 6 GB de VRAM
    "draw_resolution_scale_y":    "2",
    "postprocess_antialiasing":   '"fxaa"',
    "vsync":                      "true",       # sin vsync N&B cambia velocidad de lógica
    "apply_patches":              "true",
    "user_language":              "5",          # 5 = español
}

faltantes = []
for k, v in cambios.items():
    pat = re.compile(rf'^({re.escape(k)}\s*=\s*)(\S+)', re.M)
    if not pat.search(s):
        faltantes.append(k)
        continue
    s = pat.sub(lambda m: m.group(1) + v, s, count=1)

if faltantes:
    print("claves no encontradas en el config:", faltantes, file=sys.stderr)
    sys.exit(1)

p.write_text(s)
print("config aplicado:", ", ".join(cambios))
PY

ok "config"

# ------------------------------------------------------------- 7. parches

info "instalando parches de Nuts & Bolts"

mkdir -p "$PATCH_DIR" || die "no pude crear $PATCH_DIR"

curl -sfL -o "$PATCH_FILE" "$PATCH_URL" || die "no pude descargar el parche $TITLE_ID"
[ -s "$PATCH_FILE" ] || die "el parche descargado está vacío"

PATCH_FILE="$PATCH_FILE" PATCHES_ON="$(printf '%s\n' "${PATCHES_ON[@]}")" python3 - <<'PY' || die "no pude activar los parches"
import os, pathlib, sys

p = pathlib.Path(os.environ["PATCH_FILE"])
objetivo = {x for x in os.environ["PATCHES_ON"].split("\n") if x.strip()}

lines = p.read_text().split("\n")
actual, activados = None, set()

for i, l in enumerate(lines):
    if 'name = "' in l:
        actual = l.split('"')[1]
    if "is_enabled" in l and actual in objetivo:
        lines[i] = l.replace("false", "true")
        activados.add(actual)

faltantes = objetivo - activados
if faltantes:
    print("parches no encontrados en el .toml:", sorted(faltantes), file=sys.stderr)
    sys.exit(1)

p.write_text("\n".join(lines))
print("parches activados:", ", ".join(sorted(activados)))
PY

ok "parches"

# ------------------------------------------------------------- 8. .desktop

info "registrando el .desktop"

mkdir -p "$(dirname "$ICON_FILE")" "$(dirname "$DESKTOP_FILE")"
curl -sfL -o "$ICON_FILE" "$ICON_URL" || warn "sin icono — el lanzador funcionará igual"

RUNNER="$RUNNER" DESKTOP_FILE="$DESKTOP_FILE" python3 - <<'PY' || die "no pude escribir el .desktop"
import os, pathlib, sys

runner = os.environ["RUNNER"]
if not os.access(runner, os.X_OK):
    print(f"{runner} no es ejecutable", file=sys.stderr)
    sys.exit(1)

# Exec no expande $HOME ni ~ — tiene que ser ruta absoluta literal.
# greetd lanza niri por PAM y ~/.local/bin no está en PATH.
if not runner.startswith("/"):
    print(f"Exec debe ser absoluto, recibí: {runner}", file=sys.stderr)
    sys.exit(1)

lines = [
    "[Desktop Entry]",
    "Type=Application",
    "Name=Xenia Canary",
    "GenericName=Emulador Xbox 360",
    "Comment=Xenia Canary via umu + proton-cachyos (offload a la dGPU)",
    f"Exec={runner}",
    "Icon=xenia-canary",
    "Terminal=false",
    "Categories=Game;Emulator;",
    "Keywords=xbox;360;xenia;emulator;",
    "StartupNotify=false",
    "StartupWMClass=xenia_canary.exe",
]

p = pathlib.Path(os.environ["DESKTOP_FILE"])
p.write_text("\n".join(lines) + "\n")
print("escrito:", p)
PY

command -v desktop-file-validate >/dev/null 2>&1 \
    && { desktop-file-validate "$DESKTOP_FILE" || die ".desktop inválido"; }
command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$(dirname "$DESKTOP_FILE")"

ok ".desktop"

# -------------------------------------------------- 9. verificación final

info "verificación final (releyendo del disco)"

fail=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        printf '  \033[1;32m✓\033[0m %s\n' "$1"
    else
        printf '  \033[1;31m✗\033[0m %s\n' "$1"
        fail=1
    fi
}

check "runner ejecutable"        "[ -x '$RUNNER' ]"
check "runner: prime-run umu-run" "grep -q 'exec prime-run umu-run' '$RUNNER'"
check "runner: sin gamemoderun"  "! grep -q gamemoderun '$RUNNER'"
check "xenia_canary.exe"         "[ -f '$XENIA_EXE' ]"
check "gpu = d3d12"              "grep -qE '^gpu = \"d3d12\"' '$XENIA_CONFIG'"
check "scale x = 2"              "grep -qE '^draw_resolution_scale_x = 2' '$XENIA_CONFIG'"
check "scale y = 2"              "grep -qE '^draw_resolution_scale_y = 2' '$XENIA_CONFIG'"
check "fxaa"                     "grep -qE '^postprocess_antialiasing = \"fxaa\"' '$XENIA_CONFIG'"
check "apply_patches = true"     "grep -qE '^apply_patches = true' '$XENIA_CONFIG'"
check "user_language = 5"        "grep -qE '^user_language = 5' '$XENIA_CONFIG'"
check "2 parches activos"        "[ \"\$(grep -c 'is_enabled = true' '$PATCH_FILE')\" -eq 2 ]"
check ".desktop presente"        "[ -f '$DESKTOP_FILE' ]"
check ".desktop Exec absoluto"   "grep -qE '^Exec=/' '$DESKTOP_FILE'"

echo
[ "$fail" -eq 0 ] || die "la verificación encontró problemas — revisa los ✗ de arriba"

cat <<EOF
$(ok "instalación completa")

  runner    $RUNNER
  config    $XENIA_CONFIG
  parches   $PATCH_DIR
  launcher  Xenia Canary

Lanza desde el launcher de Noctalia, o:  $RUNNER
Luego File → Open → tu ISO de Nuts & Bolts.

La primera carga compila shaders a $WIN_DIR/cache* — va con tirones.
A partir de la segunda sesión arranca suave.
EOF
