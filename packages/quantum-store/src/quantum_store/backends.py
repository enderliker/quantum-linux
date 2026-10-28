"""Fuentes de apps de Quantum Store: repos de Arch, Flathub, AUR y Android (F-Droid).

Cada fuente devuelve elementos con la misma forma:
    {key, source, id, name, summary, icon, installed, version, badge}
`icon` es una URL (http…) o "theme:<nombre>" para íconos del tema del sistema.
"""
import gzip
import json
import os
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path

CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "quantum-store"
UA = "QuantumStore/1.0 (+https://github.com/quantum-linux)"
C_ENV = {**os.environ, "LANG": "C", "LC_ALL": "C"}


def run(cmd, timeout=60):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=C_ENV)
        return out.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def http_json(url, data=None, ttl=3600, cache_name=None):
    """GET/POST JSON con caché en disco (ttl en segundos)."""
    path = CACHE / "http" / cache_name if cache_name else None
    if path and path.exists() and time.time() - path.stat().st_mtime < ttl:
        try:
            return json.loads(path.read_text())
        except ValueError:
            pass
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, headers={"User-Agent": UA, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            obj = json.load(r)
    except (OSError, ValueError):
        # sin internet: se usa la copia vieja si existe
        if path and path.exists():
            return json.loads(path.read_text())
        raise
    if path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(obj))
    return obj


def safe_name(s):
    return re.sub(r"[^A-Za-z0-9._-]", "_", s)


def item(source, id_, name, summary="", icon="", installed=False, version="", badge=""):
    return {"key": f"{source}:{id_}", "source": source, "id": id_, "name": name or id_,
            "summary": summary or "", "icon": icon or "theme:package-x-generic",
            "installed": bool(installed), "version": version or "", "badge": badge}


# ------------------------------------------------------------------ Arch

class Arch:
    label = "Arch"

    def installed(self):
        return set(run(["pacman", "-Qq"]).split())

    def search(self, q, limit=40):
        out = run(["pacman", "-Ss", "--", q])
        inst = self.installed()
        res, lines = [], out.splitlines()
        for i in range(0, len(lines) - 1, 2):
            head, desc = lines[i], lines[i + 1].strip()
            m = re.match(r"(\S+)/(\S+) (\S+)", head)
            if not m:
                continue
            repo, name, ver = m.groups()
            if repo not in ("core", "extra", "multilib"):
                continue
            res.append(item("arch", name, name, desc, f"theme:{name}", name in inst, ver, repo))
        # primero las coincidencias exactas o que empiezan igual
        ql = q.lower()
        res.sort(key=lambda x: (x["id"] != ql, not x["id"].startswith(ql), len(x["id"])))
        return res[:limit]

    def details(self, id_):
        info = {}
        key = None
        for line in run(["pacman", "-Si", "--", id_]).splitlines():
            if ":" in line and not line.startswith(" "):
                key, val = line.split(":", 1)
                key = key.strip()
                info[key] = val.strip()
            elif key:
                info[key] += " " + line.strip()
        inst = id_ in self.installed()
        return {**item("arch", id_, id_, info.get("Description", ""), f"theme:{id_}", inst,
                       info.get("Version", ""), info.get("Repository", "")),
                "description": info.get("Description", ""),
                "facts": [["Repositorio", info.get("Repository", "")], ["Versión", info.get("Version", "")],
                          ["Tamaño", info.get("Installed Size", "")], ["Licencia", info.get("Licenses", "")],
                          ["Web", info.get("URL", "")]],
                "screenshots": []}

    def install_cmd(self, id_):
        # -Syu: Arch no admite actualizaciones parciales (instalar con listas nuevas
        # sobre un sistema viejo puede romper bibliotecas)
        return ["pkexec", "pacman", "-Syu", "--needed", "--noconfirm", id_]

    def remove_cmd(self, id_):
        return ["pkexec", "pacman", "-Rns", "--noconfirm", id_]


# ---------------------------------------------------------------- Flathub

class Flathub:
    label = "Flathub"
    API = "https://flathub.org/api/v2"

    def installed(self):
        return set(run(["flatpak", "list", "--app", "--columns=application"]).split())

    def _from_hit(self, h, inst):
        return item("flathub", h["app_id"], h.get("name"), h.get("summary"), h.get("icon"),
                    h["app_id"] in inst, badge="Flathub")

    def search(self, q, limit=40):
        d = http_json(f"{self.API}/search", {"query": q}, ttl=1800, cache_name=f"fh-search-{safe_name(q)}.json")
        inst = self.installed()
        return [self._from_hit(h, inst) for h in d.get("hits", [])[:limit] if h.get("type", "desktop-application") != "runtime"]

    def collection(self, name, limit=18):
        d = http_json(f"{self.API}/collection/{name}?page=1&per_page={limit}", ttl=6 * 3600,
                      cache_name=f"fh-{safe_name(name)}.json")
        inst = self.installed()
        return [self._from_hit(h, inst) for h in d.get("hits", [])]

    def details(self, id_):
        d = http_json(f"{self.API}/appstream/{id_}", ttl=6 * 3600, cache_name=f"fh-app-{safe_name(id_)}.json")
        shots = []
        for s in d.get("screenshots", [])[:6]:
            sizes = [z for z in s.get("sizes", []) if isinstance(z, dict) and z.get("src")]
            # la más cercana a 750 px de ancho (nítida y liviana)
            sizes.sort(key=lambda z: abs(int(z.get("width") or 0) - 750))
            if sizes:
                shots.append(sizes[0]["src"])
        desc = re.sub(r"<[^>]+>", " ", d.get("description", "")).strip()
        desc = re.sub(r"\s+", " ", desc)
        rel = (d.get("releases") or [{}])[0]
        return {**item("flathub", id_, d.get("name"), d.get("summary"), d.get("icon"),
                       id_ in self.installed(), rel.get("version", ""), "Flathub"),
                "description": desc,
                "facts": [["Desarrollador", d.get("developer_name", "")], ["Versión", rel.get("version", "")],
                          ["Licencia", d.get("project_license", "")], ["Fuente", "Flathub"]],
                "screenshots": shots}

    def install_cmd(self, id_):
        return ["flatpak", "install", "--system", "-y", "--noninteractive", "flathub", id_]

    def remove_cmd(self, id_):
        return ["flatpak", "uninstall", "--system", "-y", "--noninteractive", id_]

    def launch_cmd(self, id_):
        return ["flatpak", "run", id_]


# -------------------------------------------------------------------- AUR

class Aur:
    label = "AUR"
    API = "https://aur.archlinux.org/rpc/v5"

    def installed(self):
        return set(run(["pacman", "-Qmq"]).split())

    def search(self, q, limit=30):
        if len(q) < 2:
            return []
        d = http_json(f"{self.API}/search/{urllib.parse.quote(q)}?by=name-desc", ttl=1800,
                      cache_name=f"aur-{safe_name(q)}.json")
        inst = self.installed()
        rs = sorted(d.get("results", []), key=lambda r: -float(r.get("Popularity") or 0))[:limit]
        return [item("aur", r["Name"], r["Name"], r.get("Description"), f"theme:{r['Name']}",
                     r["Name"] in inst, r.get("Version"), "Comunidad") for r in rs]

    def details(self, id_):
        d = http_json(f"{self.API}/info?arg[]={urllib.parse.quote(id_)}", ttl=1800, cache_name=f"aur-info-{safe_name(id_)}.json")
        r = (d.get("results") or [{}])[0]
        return {**item("aur", id_, id_, r.get("Description"), f"theme:{id_}", id_ in self.installed(),
                       r.get("Version"), "Comunidad"),
                "description": r.get("Description", ""),
                "facts": [["Mantenedor", r.get("Maintainer") or "Sin mantenedor"], ["Votos", str(r.get("NumVotes", ""))],
                          ["Versión", r.get("Version", "")],
                          ["Desactualizado", "Sí" if r.get("OutOfDate") else "No"], ["Web", r.get("URL") or ""]],
                "warning": "Este paquete lo publica la comunidad en AUR: no está revisado por Arch. "
                           "Se compila en tu PC y puede tardar varios minutos.",
                "screenshots": []}

    def install_cmd(self, id_):
        # yay compila con makepkg como usuario y usa pkexec solo para instalar
        return ["yay", "-S", "--noconfirm", "--answerdiff", "None", "--answerclean", "None",
                "--removemake", "--sudo", "pkexec", "--sudoflags", "", id_]

    def remove_cmd(self, id_):
        return ["pkexec", "pacman", "-Rns", "--noconfirm", id_]


# ---------------------------------------------------------------- Android

class Android:
    """Apps Android con Waydroid; catálogo de F-Droid (apps libres)."""
    label = "Android"
    REPO = "https://f-droid.org/repo"
    INDEX = CACHE / "fdroid-catalog.json"
    # juegos conocidos que van primero en la fila de juegos
    TOP_GAMES = ["io.anuke.mindustry", "net.minetest.minetest", "org.supertuxkart.stk",
                 "com.shatteredpixel.shatteredpixeldungeon", "com.unciv.app", "dev.lucanlm.antimine",
                 "name.boyle.chris.sgtpuzzles", "com.gitlab.ardash.appleflinger.android"]

    # ---- estado de Waydroid
    def status(self):
        if not shutil.which("waydroid"):
            return "missing"
        out = run(["waydroid", "status"], timeout=10)
        if "not initialized" in out.lower() or not out.strip():
            return "uninitialized"
        if re.search(r"Session:\s*RUNNING", out):
            return "running"
        return "stopped"

    def installed_apps(self):
        out = run(["waydroid", "app", "list"], timeout=20)
        apps, cur = [], {}
        for line in out.splitlines():
            if line.startswith("Name:"):
                cur = {"name": line.split(":", 1)[1].strip()}
            elif line.startswith("packageName:"):
                cur["id"] = line.split(":", 1)[1].strip()
                apps.append(cur)
        return {a["id"]: a["name"] for a in apps}

    # ---- catálogo F-Droid
    def catalog_ready(self):
        return self.INDEX.exists()

    def build_catalog(self, progress=None):
        """Descarga el índice de F-Droid (~66 MB) y guarda una versión compacta."""
        CACHE.mkdir(parents=True, exist_ok=True)
        raw = CACHE / "fdroid-index-v2.json"
        req = urllib.request.Request(f"{self.REPO}/index-v2.json", headers={"User-Agent": UA, "Accept-Encoding": "gzip"})
        with urllib.request.urlopen(req, timeout=60) as r:
            total = int(r.headers.get("Content-Length") or 0)
            is_gzip = r.headers.get("Content-Encoding") == "gzip"
            target = raw.with_suffix(".tmp.gz") if is_gzip else raw.with_suffix(".tmp")
            done = 0
            with open(target, "wb") as f:
                while chunk := r.read(1 << 16):
                    f.write(chunk)
                    done += len(chunk)
                    if progress and total:
                        progress(min(0.95, done / total))
        if is_gzip:
            if progress:
                progress(0.96)
            with gzip.open(target, "rb") as gz_in, open(raw, "wb") as f_out:
                shutil.copyfileobj(gz_in, f_out)
            target.unlink(missing_ok=True)
        else:
            target.replace(raw)
        if progress:
            progress(1.0)
        idx = json.loads(raw.read_text())
        apps = []
        for pkg, p in idx.get("packages", {}).items():
            md = p.get("metadata", {})
            best = None
            for v in p.get("versions", {}).values():
                man = v.get("manifest", {})
                native = man.get("nativecode") or []
                if native and "x86_64" not in native:
                    continue  # Waydroid en PC necesita x86_64 o apps sin código nativo
                if best is None or man.get("versionCode", 0) > best["manifest"].get("versionCode", 0):
                    best = v
            if not best:
                continue
            loc = lambda d: (d or {}).get("es") or (d or {}).get("es-ES") or (d or {}).get("en-US") or next(iter((d or {}).values()), "")
            icon = loc(md.get("icon"))
            apps.append({
                "id": pkg, "name": loc(md.get("name")) or pkg, "summary": loc(md.get("summary")),
                "icon": f"{self.REPO}{icon['name']}" if isinstance(icon, dict) and icon.get("name") else "",
                "apk": f"{self.REPO}{best['file']['name']}", "version": best["manifest"].get("versionName", ""),
                "categories": md.get("categories", []), "added": md.get("added", 0),
                "updated": md.get("lastUpdated", 0),
                "description": re.sub(r"<[^>]+>", " ", loc(md.get("description")) or "")[:1200],
            })
        apps.sort(key=lambda a: -a["updated"])
        self.INDEX.write_text(json.dumps(apps))
        raw.unlink(missing_ok=True)
        return len(apps)

    def _catalog(self):
        try:
            return json.loads(self.INDEX.read_text())
        except (OSError, ValueError):
            return []

    def _as_item(self, a, inst):
        return item("android", a["id"], a["name"], a["summary"], a["icon"] or "theme:android",
                    a["id"] in inst, a["version"], "Android")

    def search(self, q, limit=40):
        ql = q.lower()
        inst = self.installed_apps() if self.status() == "running" else {}
        hits = [a for a in self._catalog() if ql in a["name"].lower() or ql in (a["summary"] or "").lower()]
        hits.sort(key=lambda a: (not a["name"].lower().startswith(ql), a["name"].lower()))
        return [self._as_item(a, inst) for a in hits[:limit]]

    def featured(self, category=None, limit=18):
        inst = self.installed_apps() if self.status() == "running" else {}
        cat = self._catalog()
        if category is None:
            cat = sorted(cat, key=lambda a: -a.get("added", 0))
        if category == "games":
            cat = [a for a in cat if any(c.endswith("Game") for c in a["categories"])]
            top = {k: i for i, k in enumerate(self.TOP_GAMES)}
            cat.sort(key=lambda a: top.get(a["id"], len(top)))
        elif category:
            cat = [a for a in cat if category in a["categories"]]
        # una app por autor/ícono para que la fila sea variada
        seen, out = set(), []
        for a in cat:
            tag = a["icon"] or a["id"].rsplit(".", 1)[0]
            if tag in seen or a["id"].rsplit(".", 1)[0] in seen:
                continue
            seen.update((tag, a["id"].rsplit(".", 1)[0]))
            out.append(self._as_item(a, inst))
            if len(out) >= limit:
                break
        return out

    def details(self, id_):
        a = next((x for x in self._catalog() if x["id"] == id_), None) or {"id": id_, "name": id_, "summary": "",
                                                                          "icon": "", "version": "", "description": ""}
        inst = self.installed_apps() if self.status() == "running" else {}
        return {**self._as_item(a, inst), "description": a.get("description", ""),
                "facts": [["Fuente", "F-Droid (apps libres)"], ["Versión", a.get("version", "")],
                          ["Paquete", id_]],
                "apk": a.get("apk", ""), "screenshots": []}

    def apk_path(self, id_):
        return CACHE / "apk" / f"{safe_name(id_)}.apk"

    def setup_cmd(self):
        # Descarga Android (LineageOS, ~1 GB) y activa el servicio del contenedor
        return ["pkexec", "/usr/lib/quantum-store/android-setup"]


SOURCES = {"arch": Arch(), "flathub": Flathub(), "aur": Aur(), "android": Android()}
