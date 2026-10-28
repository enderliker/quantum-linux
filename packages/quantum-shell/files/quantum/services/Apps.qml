pragma Singleton

import QtQuick
import Quickshell

// Lista de apps y búsqueda tolerante (sin tildes, por nombre, descripción y palabras clave).
Singleton {
    id: root

    property var lastLaunch: ({})
    property int launchCooldown: 500

    readonly property var all: DesktopEntries.applications.values
        .filter(a => !a.noDisplay)
        .slice()
        .sort((a, b) => a.name.localeCompare(b.name, "es"))

    function normalize(s: var): string {
        if (s === undefined || s === null)
            return "";
        if (Array.isArray(s))
            return s.map(item => normalize(item)).join(" ");
        return String(s).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
    }

    function search(query: string): var {
        const q = normalize(query.trim());
        if (!q)
            return all;
        const scored = [];
        for (let i = 0; i < all.length; i++) {
            const app = all[i];
            const name = normalize(app.name);
            let score = -1;
            if (name.startsWith(q))
                score = 0;
            else if (name.indexOf(" ") >= 0 && name.split(/\s+/).some(w => w.startsWith(q)))
                score = 1;
            else if (name.includes(q))
                score = 2;
            else if (normalize(app.genericName).includes(q) || normalize(app.keywords).includes(q))
                score = 3;
            else if (normalize(app.comment).includes(q) || normalize(app.categories).includes(q))
                score = 4;
            if (score >= 0)
                scored.push({ app: app, score: score });
        }
        scored.sort((a, b) => {
            if (a.score !== b.score)
                return a.score - b.score;
            return a.app.name.localeCompare(b.app.name, "es");
        });
        const out = [];
        for (let i = 0; i < scored.length; i++)
            out.push(scored[i].app);
        return out;
    }

    function launch(app: DesktopEntry): void {
        if (!app)
            return;
        const key = app.id || app.name || "";
        const now = Date.now();
        if (key && root.lastLaunch[key] && (now - root.lastLaunch[key]) < root.launchCooldown)
            return;
        root.lastLaunch[key] = now;
        if (app.runInTerminal) {
            if (app.command && app.command.length > 0)
                Quickshell.execDetached(["kitty", "-e", ...app.command]);
            else
                Quickshell.execDetached(["kitty", "-e", app.exec || ""]);
        } else {
            try {
                app.execute();
            } catch (e) {
                if (app.command && app.command.length > 0)
                    Quickshell.execDetached(app.command);
                else if (app.exec)
                    Quickshell.execDetached(app.exec.split(/\s+/));
            }
        }
    }
}
