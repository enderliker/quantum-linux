#!/usr/bin/env bash
# Compila los paquetes de Quantum Linux (y los de AUR que necesita) y arma el
# repositorio local repo/x86_64/quantum.db que usa el ISO.
#
# Uso: scripts/build-packages.sh [--force]
#   --force  recompila aunque el paquete ya exista en el repositorio
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$ROOT/repo/x86_64"
BUILD="$ROOT/build/makepkg"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# Orden importante: ckbcomp antes que calamares, branding antes que el resto.
PACKAGES=(
    aur/ckbcomp
    aur/calamares
    aur/yay-bin
    quantum-keyring
    quantum-branding
    quantum-settings
    quantum-shell
    quantum-wayfire-decor
    quantum-desktop
    quantum-center
    quantum-store
    quantum-foton
    quantum-calamares-config
)

mkdir -p "$REPO" "$BUILD"

msg() { printf '\e[1;38;2;255;106;61m==>\e[0m \e[1m%s\e[0m\n' "$*"; }

# calamares depende de ckbcomp, que no está en los repos oficiales: se instala
# el que acabamos de compilar para que makepkg -s no lo busque en otro lado.
install_ckbcomp() {
    if [[ "$p" == aur/ckbcomp ]] && ! pacman -Q ckbcomp &>/dev/null; then
        sudo pacman -U --noconfirm "${outputs[@]}"
    fi
}

for p in "${PACKAGES[@]}"; do
    dir="$ROOT/packages/$p"
    cd "$dir"
    # Se ignoran los paquetes -debug (si makepkg.conf tiene la opción debug).
    mapfile -t outputs < <(PKGDEST="$REPO" makepkg --packagelist | grep -v -- '-debug-')
    if (( ! FORCE )) && [[ -f "${outputs[0]}" ]]; then
        msg "$p: ya está compilado ($(basename "${outputs[0]}"))"
        install_ckbcomp
        continue
    fi
    msg "Compilando $p"
    # -s instala dependencias de compilación (pide sudo si faltan).
    # -d en los paquetes quantum: sus dependencias de ejecución están en el repo
    # local, no hace falta tenerlas instaladas en esta máquina.
    flags=(-f -s --needed --noconfirm --cleanbuild)
    [[ "$p" == quantum-* ]] && flags=(-f -d --noconfirm --cleanbuild)
    # el plugin de ventanas se compila contra Wayfire: necesita sus cabeceras
    [[ "$p" == quantum-wayfire-decor ]] && flags=(-f -s --needed --noconfirm --cleanbuild)
    BUILDDIR="$BUILD" PKGDEST="$REPO" SRCDEST="$BUILD/sources" makepkg "${flags[@]}"
    install_ckbcomp
done

msg "Actualizando el índice del repositorio"
cd "$REPO"
rm -f quantum.db* quantum.files* ./*-debug-*.pkg.tar.zst
repo-add -q quantum.db.tar.gz ./*.pkg.tar.zst
msg "Repositorio listo en $REPO"
