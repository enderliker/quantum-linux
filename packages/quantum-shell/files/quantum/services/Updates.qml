pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Avisa cuando hay actualizaciones. Usa checkupdates (copia aparte de la base de
// pacman: no toca el sistema ni pide contraseña) y revisa cada 3 horas.
Singleton {
    id: root

    property int count: 0
    property int quantumCount: 0        // de ellas, cuántas son de Quantum
    property var list: []               // [{ name, from, to, quantum }]
    property bool checking: false
    property int notifiedFor: 0

    function check(): void {
        if (!proc.running) {
            checking = true;
            proc.running = true;
        }
    }

    // Abre una terminal que actualiza todo (con instantánea previa gracias a snap-pac)
    function update(): void {
        Quickshell.execDetached(["quantum-update"]);
    }

    // primera revisión 2 min después de iniciar sesión, luego cada 3 horas
    Timer { interval: 120000; running: true; onTriggered: root.check() }
    Timer { interval: 3 * 3600 * 1000; running: true; repeat: true; onTriggered: root.check() }

    // quantum-update avisa al terminar: qs -c quantum ipc call updates check
    IpcHandler {
        target: "updates"
        function check(): void { root.check(); }
    }

    Process {
        id: proc
        command: ["sh", "-c", "checkupdates 2>/dev/null; pacman -Sl quantum 2>/dev/null | awk '{print \"#\" $2}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                const quantum = {};
                const items = [];
                for (const line of text.split("\n")) {
                    if (line.startsWith("#")) { quantum[line.slice(1)] = true; continue; }
                    const m = line.match(/^(\S+) (\S+) -> (\S+)/);
                    if (m) items.push({ name: m[1], from: m[2], to: m[3] });
                }
                for (const it of items) it.quantum = !!quantum[it.name];
                items.sort((a, b) => (b.quantum - a.quantum) || a.name.localeCompare(b.name));
                root.list = items;
                root.count = items.length;
                root.quantumCount = items.filter(i => i.quantum).length;
                root.checking = false;
                if (root.count > 0 && root.count !== root.notifiedFor) {
                    root.notifiedFor = root.count;
                    const extra = root.quantumCount > 0 ? ", con " + root.quantumCount + " mejoras de Quantum" : "";
                    Quickshell.execDetached(["notify-send", "-a", "Quantum Linux", "-i", "system-software-update",
                                             "Hay " + root.count + " actualizaciones" + extra,
                                             "Toca el ícono de actualizaciones en la barra para instalarlas."]);
                } else if (root.count === 0) {
                    root.notifiedFor = 0;
                }
            }
        }
    }
}
