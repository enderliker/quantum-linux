"""Quantum Store: la tienda de apps de Quantum Linux (PyQt6 + QML).

Uso: quantum-store [--apk ARCHIVO.apk] [--page inicio|juegos|android|instaladas]
Variables para desarrollo:
  QUANTUM_STORE_DRYRUN=1   no instala nada: solo muestra los comandos
  QUANTUM_STORE_SCREENSHOT=archivo.png  guarda capturas de cada página y sale
"""
import argparse
import hashlib
import urllib.parse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

from PyQt6.QtCore import (Qt, QObject, QProcess, QSize, QThreadPool, QTimer, QUrl, pyqtProperty, pyqtSignal, pyqtSlot)
from PyQt6.QtGui import QFont, QFontDatabase, QGuiApplication, QIcon, QImage
from PyQt6.QtQml import QQmlApplicationEngine
from PyQt6.QtQuick import (QQuickAsyncImageProvider, QQuickImageProvider, QQuickImageResponse, QQuickTextureFactory)

from .backends import CACHE, SOURCES, UA, item

HERE = Path(__file__).resolve().parent
DRYRUN = bool(os.environ.get("QUANTUM_STORE_DRYRUN"))
STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "quantum"

# Destacados de la portada (Flathub): apps que más piden quienes vienen de Windows
HERO = [
    {"id": "com.valvesoftware.Steam", "title": "Steam", "text": "Tus juegos de Windows, aquí. Proton incluido.",
     "a": "#1B2838", "b": "#2A475E"},
    {"id": "com.discordapp.Discord", "title": "Discord", "text": "Habla con tus amigos mientras juegas.",
     "a": "#404EED", "b": "#5865F2"},
    {"id": "com.spotify.Client", "title": "Spotify", "text": "Toda tu música, en tu PC.",
     "a": "#0B6B30", "b": "#1DB954"},
    {"id": "com.obsproject.Studio", "title": "OBS Studio", "text": "Graba y transmite tus partidas.",
     "a": "#1E1F26", "b": "#4B4D5C"},
]


class IconProvider(QQuickImageProvider):
    """image://icon/<nombre> → ícono del tema (Papirus), con respaldo genérico."""

    def __init__(self):
        super().__init__(QQuickImageProvider.ImageType.Image)

    def requestImage(self, name, requested):
        s = requested if requested.width() > 0 else QSize(128, 128)
        icon = QIcon.fromTheme(name)
        if icon.isNull():
            icon = QIcon.fromTheme(name.split(".")[-1].lower())
        if icon.isNull():
            icon = QIcon.fromTheme("package-x-generic")
        img = icon.pixmap(s).toImage()
        return img, img.size()


class WebImageResponse(QQuickImageResponse):
    """Descarga o lee de caché la imagen en un hilo de fondo para no congelar la interfaz."""

    def __init__(self, url_str, requested):
        super().__init__()
        self._url = url_str
        self._requested = requested
        self._img = QImage()
        QThreadPool.globalInstance().start(self._fetch)

    def _fetch(self):
        try:
            url = urllib.parse.unquote(self._url)
            path = CACHE / "images" / hashlib.sha1(url.encode()).hexdigest()
            if not path.exists():
                try:
                    req = urllib.request.Request(url, headers={"User-Agent": UA})
                    with urllib.request.urlopen(req, timeout=15) as r:
                        data = r.read()
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                except OSError:
                    pass
            if path.exists():
                img = QImage(str(path))
                if self._requested.width() > 0 and self._requested.height() > 0 and not img.isNull():
                    img = img.scaled(self._requested, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
                self._img = img
        finally:
            self.finished.emit()

    def textureFactory(self):
        return QQuickTextureFactory.textureFactoryForImage(self._img)


class WebImageProvider(QQuickAsyncImageProvider):
    """image://web/<url> → íconos y capturas de internet descargados asíncronamente y guardados en disco."""

    def __init__(self):
        super().__init__()

    def requestImageResponse(self, url, requested):
        return WebImageResponse(url, requested)


class Store(QObject):
    homeChanged = pyqtSignal()
    resultsChanged = pyqtSignal()
    detailsChanged = pyqtSignal()
    jobsChanged = pyqtSignal()
    androidChanged = pyqtSignal()
    installedChanged = pyqtSignal()
    busyChanged = pyqtSignal()
    colorsChanged = pyqtSignal()
    toast = pyqtSignal(str)
    _done = pyqtSignal(str, object)       # resultados desde hilos de fondo

    def __init__(self):
        super().__init__()
        self._home, self._results, self._details = {}, {}, {}
        self._jobs, self._android, self._installed = [], {}, []
        self._busy = set()
        self._colors = {}
        self._procs = {}
        self._search_gen = 0
        self._fake = set()      # instaladas en modo simulación
        self._done.connect(self._on_done)
        self._load_colors()
        self.colors_timer = QTimer(self, interval=1500, timeout=self._load_colors)
        self.colors_timer.start()

    # ---------------------------------------------------------- propiedades
    @pyqtProperty("QVariant", notify=homeChanged)
    def home(self): return self._home

    @pyqtProperty("QVariant", notify=resultsChanged)
    def results(self): return self._results

    @pyqtProperty("QVariant", notify=detailsChanged)
    def details(self): return self._details

    @pyqtProperty("QVariant", notify=jobsChanged)
    def jobs(self): return self._jobs

    @pyqtProperty("QVariant", notify=androidChanged)
    def android(self): return self._android

    @pyqtProperty("QVariant", notify=installedChanged)
    def installed(self): return self._installed

    @pyqtProperty("QVariant", notify=busyChanged)
    def busy(self): return sorted(self._busy)

    @pyqtProperty("QVariant", notify=colorsChanged)
    def colors(self): return self._colors

    @pyqtProperty(bool, constant=True)
    def dryrun(self): return DRYRUN

    def _load_colors(self):
        try:
            c = json.loads((STATE / "colors.json").read_text())
        except (OSError, ValueError):
            c = {}
        if c != self._colors:
            self._colors = c
            self.colorsChanged.emit()

    # -------------------------------------------------------- trabajo de fondo
    def _bg(self, tag, fn, *args):
        self._busy.add(tag)
        self.busyChanged.emit()

        def work():
            try:
                res = fn(*args)
            except Exception as e:  # sin internet, API caída, etc.
                res = e
            self._done.emit(tag, res)
        threading.Thread(target=work, daemon=True).start()

    def _on_done(self, tag, res):
        self._busy.discard(tag)
        self.busyChanged.emit()
        if isinstance(res, Exception):
            if not tag.startswith("search"):
                self.toast.emit("No pude conectarme. Revisa tu internet.")
            res = None
        kind = tag.split(":", 1)[0]
        if kind == "home" and res is not None:
            self._home = res
            self.homeChanged.emit()
        elif kind == "search":
            gen, src = tag.split(":")[1:3]
            if int(gen) == self._search_gen:
                self._results = {**self._results, src: res or []}
                self.resultsChanged.emit()
        elif kind == "details" and res is not None:
            if DRYRUN and res.get("key") in self._fake:
                res = {**res, "installed": True}
            self._details = res
            self.detailsChanged.emit()
        elif kind == "android":
            self._android = res or {"status": "missing"}
            self.androidChanged.emit()
        elif kind == "installed":
            self._installed = res or []
            self.installedChanged.emit()
        elif kind == "catalog":
            self.refreshAndroid()

    # ---------------------------------------------------------------- portada
    @pyqtSlot()
    def loadHome(self):
        def build():
            fh = SOURCES["flathub"]
            hero = []
            for h in HERO:
                try:
                    d = fh.details(h["id"])
                    hero.append({**h, "icon": d["icon"], "key": d["key"], "installed": d["installed"],
                                 "shot": (d["screenshots"] or [""])[0]})
                except Exception:
                    continue
            return {
                "hero": hero,
                "popular": fh.collection("popular", 18),
                "games": fh.collection("category/Game", 18),
                "create": fh.collection("category/AudioVideo", 18),
                "office": fh.collection("category/Office", 12),
                "trending": fh.collection("trending", 12),
            }
        self._bg("home", build)

    # ---------------------------------------------------------------- búsqueda
    @pyqtSlot(str)
    def search(self, q):
        self._search_gen += 1
        self._results = {"query": q}
        self.resultsChanged.emit()
        q = q.strip()
        if len(q) < 2:
            return
        for src in ("flathub", "arch", "aur", "android"):
            self._bg(f"search:{self._search_gen}:{src}", SOURCES[src].search, q)

    # ---------------------------------------------------------------- detalles
    @pyqtSlot(str)
    def openDetails(self, key):
        src, id_ = key.split(":", 1)
        self._details = {"key": key, "loading": True}
        self.detailsChanged.emit()
        self._bg(f"details:{key}", SOURCES[src].details, id_)

    # --------------------------------------------------------------- acciones
    def _job(self, key, name, kind, cmd, then=None):
        if key in self._procs:
            return
        job = {"key": key, "name": name, "kind": kind, "progress": -1, "line": "Preparando…", "state": "running"}
        self._jobs = [j for j in self._jobs if j["key"] != key] + [job]
        self.jobsChanged.emit()
        if DRYRUN:
            cmd = ["sh", "-c", "echo " + json.dumps("[simulación] " + " ".join(cmd)) + "; for i in 10 30 55 80 100; do echo \"$i%\"; sleep 0.4; done"]
        p = QProcess(self)
        p.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        self._procs[key] = p

        def out():
            text = bytes(p.readAll()).decode(errors="ignore")
            for line in re.split(r"[\r\n]+", text):
                line = line.strip()
                if not line:
                    continue
                m = re.findall(r"(\d{1,3})(?:\.\d+)?%", line)
                if m:
                    job["progress"] = min(100, int(m[-1])) / 100
                job["line"] = line[-90:]
            self.jobsChanged.emit()

        def finished(code, _status):
            self._procs.pop(key, None)
            job["state"] = "done" if code == 0 else "error"
            job["progress"] = 1 if code == 0 else job["progress"]
            if code in (126, 127) or (code != 0 and "dismissed" in job["line"].lower()):
                job["line"] = "Cancelado: no se aceptó la contraseña"
            self.jobsChanged.emit()
            self.toast.emit(f"{name}: {'listo' if code == 0 else 'algo falló'}")
            if code == 0 and DRYRUN:
                (self._fake.add if kind == "install" else self._fake.discard)(key)
            if code == 0 and then:
                then()
            if self._details.get("key") == key:
                self.openDetails(key)
            self.refreshInstalled()
            QTimer.singleShot(6000, lambda: self._clear_job(key))

        p.readyRead.connect(out)
        p.finished.connect(finished)
        p.start(cmd[0], cmd[1:])

    @pyqtSlot(result=bool)
    def busyJobs(self):
        return bool(self._procs)

    @pyqtSlot()
    def quitWhenIdle(self):
        # se cerró la ventana: no cortar pacman/flatpak a medias
        if not self._procs:
            QGuiApplication.quit()
            return
        self.toast.emit("Terminando en segundo plano…")
        QTimer.singleShot(1000, self.quitWhenIdle)

    @pyqtSlot(str)
    def mark(self, name):
        # marcas de tiempo de la demo guiada (para montar el video)
        path = os.environ.get("QUANTUM_STORE_MARKS")
        if path:
            with open(path, "a") as f:
                f.write(f"{time.time():.3f} {name}\n")

    def _clear_job(self, key):
        self._jobs = [j for j in self._jobs if not (j["key"] == key and j["state"] != "running")]
        self.jobsChanged.emit()

    @pyqtSlot(str, str)
    def install(self, key, name):
        src, id_ = key.split(":", 1)
        if src == "android":
            return self.installAndroid(id_, name)
        if src == "aur" and not shutil.which("yay") and not DRYRUN:
            self.toast.emit("Falta yay para instalar desde AUR")
            return
        self._job(key, name, "install", SOURCES[src].install_cmd(id_))

    @pyqtSlot(str, str)
    def remove(self, key, name):
        src, id_ = key.split(":", 1)
        if src == "android":
            self._job(key, name, "remove", ["waydroid", "app", "remove", id_])
        else:
            self._job(key, name, "remove", SOURCES[src].remove_cmd(id_))

    @pyqtSlot(str)
    def launch(self, key):
        src, id_ = key.split(":", 1)
        if DRYRUN:
            self.toast.emit(f"[simulación] abrir {id_}")
            return
        if src == "flathub":
            QProcess.startDetached("flatpak", ["run", id_])
        elif src == "android":
            QProcess.startDetached("waydroid", ["app", "launch", id_])
        else:
            # repos/AUR: buscar su .desktop por nombre de paquete
            desktop = None
            try:
                res = subprocess.run(["pacman", "-Qlq", id_], capture_output=True, text=True, check=False)
                if res.returncode == 0:
                    for line in res.stdout.splitlines():
                        if line.startswith("/usr/share/applications/") and line.endswith(".desktop"):
                            desktop = os.path.basename(line)
                            break
            except Exception:
                pass
            if desktop:
                QProcess.startDetached("gtk-launch", [desktop])

    @pyqtSlot(str)
    def cancel(self, key):
        p = self._procs.get(key)
        if p:
            p.kill()

    # ----------------------------------------------------------------- Android
    @pyqtSlot()
    def refreshAndroid(self):
        a = SOURCES["android"]

        def state():
            st = a.status()
            apps = a.installed_apps() if st == "running" else {}
            return {"status": st, "catalog": a.catalog_ready(),
                    "apps": [item("android", k, v, "", "theme:android", True) for k, v in sorted(apps.items(), key=lambda x: x[1])],
                    "games": a.featured("games", 18) if a.catalog_ready() else [],
                    "newest": a.featured(None, 18) if a.catalog_ready() else []}
        self._bg("android", state)

    @pyqtSlot()
    def downloadCatalog(self):
        a = SOURCES["android"]
        job = {"key": "android:catalog", "name": "Catálogo de F-Droid", "kind": "download",
               "progress": 0, "line": "Descargando el catálogo (66 MB)…", "state": "running"}
        self._jobs = self._jobs + [job]
        self.jobsChanged.emit()

        def prog(x):
            job["progress"] = x
            QTimer.singleShot(0, self.jobsChanged.emit)

        def build():
            n = a.build_catalog(prog)
            job.update(state="done", progress=1, line=f"{n} apps listas")
            return n
        self._bg("catalog", build)

    @pyqtSlot()
    def setupAndroid(self):
        a = SOURCES["android"]
        if a.status() == "missing" and not DRYRUN:
            self.toast.emit("Falta Waydroid en el sistema")
            return
        self._job("android:setup", "Activar Android", "setup", a.setup_cmd(), then=self.startAndroid)

    @pyqtSlot()
    def startAndroid(self):
        if not DRYRUN:
            # sesión en segundo plano + ventanas separadas para cada app (como apps nativas)
            QProcess.startDetached("sh", ["-c", "waydroid session start >/dev/null 2>&1 & sleep 12; "
                                          "waydroid prop set persist.waydroid.multi_windows true"])
        QTimer.singleShot(15000, self.refreshAndroid)
        self.toast.emit("Iniciando Android…")

    def installAndroid(self, id_, name):
        d = SOURCES["android"].details(id_)
        url, path = d.get("apk"), SOURCES["android"].apk_path(id_)
        if not url:
            self.toast.emit("No encontré el APK")
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        key = f"android:{id_}"
        if DRYRUN:
            return self._job(key, name, "install", ["waydroid", "app", "install", str(path)])
        job = {"key": key, "name": name, "kind": "install", "progress": 0, "line": "Descargando APK…", "state": "running"}
        self._jobs = [j for j in self._jobs if j["key"] != key] + [job]
        self.jobsChanged.emit()

        def download():
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r, open(path, "wb") as f:
                total, done = int(r.headers.get("Content-Length") or 0), 0
                while chunk := r.read(1 << 16):
                    f.write(chunk)
                    done += len(chunk)
                    if total:
                        job["progress"] = done / total * 0.8
                        QTimer.singleShot(0, self.jobsChanged.emit)
            return str(path)

        def after(tag, res):
            if tag != f"apk:{id_}":
                return
            self._done.disconnect(after)
            self._jobs = [j for j in self._jobs if j["key"] != key]
            if isinstance(res, Exception):
                self.toast.emit("No pude descargar el APK")
                self.jobsChanged.emit()
                return
            self._job(key, name, "install", ["waydroid", "app", "install", res])
        self._done.connect(after)
        self._bg(f"apk:{id_}", download)

    @pyqtSlot(str)
    def openApk(self, path):
        path = path.replace("file://", "")
        if not Path(path).is_file():
            return
        name = Path(path).stem
        self._job(f"android:local-{name}", name, "install", ["waydroid", "app", "install", path])

    # -------------------------------------------------------------- instaladas
    @pyqtSlot()
    def refreshInstalled(self):
        def collect():
            out = []
            fh = SOURCES["flathub"]
            from .backends import run
            for line in run(["flatpak", "list", "--app", "--columns=application,name,version"]).splitlines():
                parts = line.split("\t")
                if len(parts) >= 2:
                    out.append(item("flathub", parts[0], parts[1], "", f"theme:{parts[0]}", True,
                                    parts[2] if len(parts) > 2 else "", "Flathub"))
            for name in sorted(SOURCES["aur"].installed()):
                out.append(item("aur", name, name, "", f"theme:{name}", True, badge="Comunidad"))
            return out
        self._bg("installed", collect)


def main():
    ap = argparse.ArgumentParser(description="Quantum Store")
    ap.add_argument("--apk", help="instala un APK con Waydroid")
    ap.add_argument("--page", default="inicio")
    ap.add_argument("--search", help="abre la búsqueda con este texto")
    ap.add_argument("--app", help="abre la ficha de una app (p. ej. flathub:com.heroicgameslauncher.hgl)")
    args, qt_args = ap.parse_known_args()

    app = QGuiApplication([sys.argv[0]] + qt_args)
    app.setApplicationName("quantum-store")
    app.setDesktopFileName("quantum-store")
    app.setQuitOnLastWindowClosed(False)
    app.setWindowIcon(QIcon.fromTheme("quantum-store", QIcon.fromTheme("system-software-install")))
    QIcon.setThemeName(os.environ.get("QUANTUM_ICON_THEME", "Papirus-Dark"))
    if "Inter" in QFontDatabase.families():
        app.setFont(QFont("Inter", 10))
    for f in [Path("/usr/share/fonts/quantum/MaterialSymbolsRounded.ttf"),
              Path(os.environ.get("QUANTUM_ICON_FONT", "/nonexistent"))]:
        if f.exists():
            QFontDatabase.addApplicationFont(str(f))

    store = Store()
    engine = QQmlApplicationEngine()
    engine.addImageProvider("icon", IconProvider())
    engine.addImageProvider("web", WebImageProvider())
    engine.rootContext().setContextProperty("store", store)
    engine.rootContext().setContextProperty("startPage", args.page)
    engine.rootContext().setContextProperty("demoMode", bool(os.environ.get("QUANTUM_STORE_DEMO")))
    engine.warnings.connect(lambda ws: [print("QML:", w.toString(), file=sys.stderr) for w in ws])
    engine.load(QUrl.fromLocalFile(str(HERE / "qml" / "Main.qml")))
    if not engine.rootObjects():
        return 1
    store.loadHome()
    store.refreshAndroid()
    store.refreshInstalled()
    if args.apk:
        store.openApk(args.apk)
    win = engine.rootObjects()[0]
    if args.search:
        store.search(args.search)
        win.setProperty("page", "buscar")
    elif args.app:
        store.openDetails(args.app)
        win.setProperty("page", "detalle")

    shot = os.environ.get("QUANTUM_STORE_SCREENSHOT")
    if shot:
        win = engine.rootObjects()[0]
        pages = os.environ.get("QUANTUM_STORE_PAGES", "inicio").split(",")
        state = {"i": 0}

        def snap():
            if state["i"] > 0:
                win.grabWindow().save(shot.replace(".png", f"-{pages[state['i'] - 1]}.png"))
            if state["i"] >= len(pages):
                app.quit()
                return
            page = pages[state["i"]]
            if page.startswith("buscar="):
                win.setProperty("page", "buscar")
                store.search(page.split("=", 1)[1])
            elif page.startswith("instalar="):
                store.openDetails(page.split("=", 1)[1])
                store.install(page.split("=", 1)[1], "Prueba")
                win.setProperty("page", "detalle")
            elif page.startswith("app="):
                store.openDetails(page.split("=", 1)[1])
                win.setProperty("page", "detalle")
            else:
                win.setProperty("page", page)
            state["i"] += 1
            QTimer.singleShot(int(os.environ.get("QUANTUM_STORE_WAIT", "6000")), snap)
        QTimer.singleShot(4000, snap)
    return app.exec()
