#!/usr/bin/env python3
"""Instalador de Quantum Linux: instala las apps elegidas en el paso «Tus apps».

Lee de Global Storage quantumApps (ids de Flathub separados por espacio),
quantumAppNames (nombres separados por «;») y quantumAppsWhen (now | later | none).
Con «now» instala cada app con el flatpak del sistema en vivo (que tiene internet)
dentro del disco nuevo, mostrando el avance en la barra. Se usa el modo «usuario»
apuntando a /var/lib/flatpak del disco nuevo (FLATPAK_USER_DIR): así flatpak crea solo
su repositorio, y el sistema instalado lo ve como instalación del sistema.
Lo que falle, tarde demasiado o se haya pedido «later» queda en
/var/lib/quantum/pending-apps para que el Centro Quantum lo instale al primer inicio.

Juegos gratis (quantumGames / quantumSteamGames, «id\tnombre» separados por «;»):
siempre quedan para después. Los de Flathub se suman a pending-apps (los instala el
Centro); los de Steam van a /var/lib/quantum/pending-games y Fotón los ofrece.
"""
import os
import re
import select
import subprocess
import time

import libcalamares

PER_APP_TIMEOUT = 15 * 60      # segundos por app antes de dejarla para el primer inicio
status = "Preparando tus apps"


def pretty_name():
    return "Instalando tus apps"


def pretty_status_message():
    return status


def used_bytes(path):
    st = os.statvfs(path)
    return (st.f_blocks - st.f_bfree) * st.f_frsize


def install_one(app_id, env, k, total):
    """Instala una app; devuelve True si quedó instalada."""
    global status
    cmd = ["flatpak", "install", "--user", "-y", "--noninteractive", "flathub", app_id]
    p = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    start, buf, pct = time.time(), b"", 0
    disk = env["FLATPAK_USER_DIR"]
    base = used_bytes(disk)
    while True:
        if time.time() - start > PER_APP_TIMEOUT:
            p.kill()
            libcalamares.utils.warning(f"quantumapps: {app_id} tardó demasiado; queda para el primer inicio")
            return False
        r, _, _ = select.select([p.stdout], [], [], 1.0)
        if r:
            chunk = os.read(p.stdout.fileno(), 4096)
            if not chunk:
                break
            buf = (buf + chunk)[-2048:]
            found = re.findall(rb"(\d{1,3})%", buf)
            if found:
                pct = min(100, int(found[-1]))
        elif p.poll() is not None:
            break
        name = names.get(app_id, app_id)
        mb = max(0, used_bytes(disk) - base) // (1024 * 1024)
        extra = f" · {pct} %" if pct else (f" · {mb} MB descargados" if mb else "")
        status = f"Instalando {name} ({k + 1} de {total}){extra}"
        libcalamares.job.setprogress((k + pct / 100.0) / total)
    p.wait()
    for line in buf.decode(errors="ignore").replace("\r", "\n").splitlines()[-6:]:
        libcalamares.utils.debug(f"quantumapps [{app_id}] {line}")
    return p.returncode == 0


names = {}


def install_ai(root, model, when):
    """Asistente Quantum: instala Ollama en el sistema nuevo (pacman en chroot) y deja
    anotado el modelo; con «now» además lo descarga. Nunca rompe la instalación."""
    global status
    try:
        status = "Instalando el asistente con IA"
        r = libcalamares.utils.target_env_call(["pacman", "-Sy", "--needed", "--noconfirm", "ollama"])
        if r != 0:
            libcalamares.utils.warning("quantumapps: no se pudo instalar ollama (sin internet?)")
        libcalamares.utils.target_env_call(["systemctl", "enable", "ollama.service"])
        os.makedirs(os.path.join(root, "var/lib/quantum"), exist_ok=True)
        with open(os.path.join(root, "var/lib/quantum/ai-model"), "w") as f:
            f.write(model + "\n")
        if when != "now" or r != 0:
            return
        # descarga el modelo con un servidor temporal del sistema en vivo, en la carpeta
        # de modelos del disco nuevo (/var/lib/ollama); al final se corrigen los permisos
        models = os.path.join(root, "var/lib/ollama")
        os.makedirs(models, exist_ok=True)
        ollama = os.path.join(root, "usr/bin/ollama")
        env = dict(os.environ, OLLAMA_MODELS=models, OLLAMA_HOST="127.0.0.1:11499", HOME="/tmp",
                   LD_LIBRARY_PATH=os.path.join(root, "usr/lib/ollama"))
        srv = subprocess.Popen([ollama, "serve"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(3)
            base = used_bytes(models)
            p = subprocess.Popen([ollama, "pull", model], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            start = time.time()
            while p.poll() is None:
                if time.time() - start > 40 * 60:
                    p.kill()
                    try:
                        p.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        pass
                    break
                mb = max(0, used_bytes(models) - base) // (1024 * 1024)
                status = f"Descargando la IA ({model}) · {mb} MB"
                time.sleep(1)
            p.poll()
            if p.returncode == 0:
                ai_model_file = os.path.join(root, "var/lib/quantum/ai-model")
                if os.path.exists(ai_model_file):
                    os.remove(ai_model_file)
        finally:
            srv.terminate()
            try:
                srv.wait(timeout=20)
            except subprocess.TimeoutExpired:
                srv.kill()
                srv.wait(timeout=5)
        libcalamares.utils.target_env_call(["chown", "-R", "ollama:ollama", "/var/lib/ollama"])
    except Exception as e:
        libcalamares.utils.warning(f"quantumapps: asistente: {e}")


def parse_games(value, pattern):
    out = []
    for item in str(value or "").split(";"):
        gid, _, name = item.partition("\t")
        if re.fullmatch(pattern, gid):
            out.append((gid, name.strip() or gid))
    return out


def save_games(root, pending_file):
    """Los juegos elegidos se instalan al primer inicio (no alargan la instalación)."""
    gs = libcalamares.globalstorage
    flathub = parse_games(gs.value("quantumGames"), r"[A-Za-z0-9._-]+")
    steam = parse_games(gs.value("quantumSteamGames"), r"[a-z0-9-]+")
    if flathub:
        with open(pending_file, "a") as f:
            for gid, name in flathub:
                f.write(f"{gid}\t{name}\n")
        os.chmod(pending_file, 0o644)
    if steam:
        path = os.path.join(root, "var/lib/quantum/pending-games")
        with open(path, "w") as f:
            for gid, name in steam:
                f.write(f"{gid}\t{name}\n")
        os.chmod(path, 0o644)


def run():
    global status
    gs = libcalamares.globalstorage
    when = str(gs.value("quantumAppsWhen") or "none")
    ids = [i for i in str(gs.value("quantumApps") or "").split() if re.fullmatch(r"[A-Za-z0-9._-]+", i)]
    labels = str(gs.value("quantumAppNames") or "").split(";")
    names.update({i: (labels[k] if k < len(labels) and labels[k] else i) for k, i in enumerate(ids)})
    root = gs.value("rootMountPoint")
    ai = str(gs.value("quantumAI") or "")
    if ai and re.fullmatch(r"[a-z0-9._:-]+", ai):
        install_ai(root, ai, when if when != "none" else "later")
    pending_file = os.path.join(root, "var/lib/quantum/pending-apps")
    os.makedirs(os.path.dirname(pending_file), exist_ok=True)
    save_games(root, pending_file)
    if when == "none" or not ids:
        return None
    pending = []

    if when == "now":
        env = dict(os.environ, FLATPAK_USER_DIR=os.path.join(root, "var/lib/flatpak"))
        os.makedirs(env["FLATPAK_USER_DIR"], exist_ok=True)
        status = "Conectando con Flathub"
        libcalamares.job.setprogress(0.0)
        subprocess.run(["flatpak", "remote-add", "--user", "--if-not-exists", "flathub",
                        "https://dl.flathub.org/repo/flathub.flatpakrepo"], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        for k, app_id in enumerate(ids):
            try:
                ok = install_one(app_id, env, k, len(ids))
            except Exception as e:  # nunca romper la instalación por una app
                libcalamares.utils.warning(f"quantumapps: {app_id}: {e}")
                ok = False
            if not ok:
                pending.append(app_id)
            libcalamares.job.setprogress((k + 1) / len(ids))
    else:
        pending = ids

    if pending:
        with open(pending_file, "a") as f:
            for app_id in pending:
                f.write(f"{app_id}\t{names[app_id]}\n")
        os.chmod(pending_file, 0o644)
    status = "Tus apps están listas" if not pending else "Algunas apps se instalarán al primer inicio"
    return None
