pragma Singleton

import QtQuick
import Quickshell

// Asistente con IA local: habla con Ollama (en tu PC, sin internet ni cuentas).
// status: checking | missing (Ollama no está) | nomodel (sin modelos) | ready
Singleton {
    id: root

    readonly property string host: Quickshell.env("QUANTUM_OLLAMA_HOST") || "http://127.0.0.1:11434"
    property string status: "checking"
    property var models: []
    readonly property string model: models.indexOf(Settings.ai.model) >= 0 ? Settings.ai.model : (models[0] ?? "")
    property var messages: []            // [{ role, content }]
    property bool busy: false
    property var _xhr: null

    readonly property string systemPrompt:
        "Eres el Asistente de Quantum Linux, una distribución basada en Arch Linux pensada para quienes vienen de Windows y para jugar. " +
        "Respondes siempre en español neutro, con tuteo, de forma clara, amable y breve, para personas sin experiencia en Linux. " +
        "Usa pasos numerados cuando expliques cómo hacer algo y evita la terminal salvo que sea necesario (si la usas, explica cada comando). " +
        "Datos de Quantum: escritorio Quantum Shell sobre Wayfire. Atajos: Super+Espacio abre el menú de apps, Super+P abre Personalizar " +
        "(estilos, colores, fondo, barra, ventanas, pantalla de bloqueo), Super+W cambia el fondo, Super+N abre el centro de control, " +
        "Super+L bloquea, Super+H abre este asistente, Super+G activa el modo juego, Impr Pant toma capturas. " +
        "Apps: Quantum Store (instala apps de Arch, Flathub y AUR con un clic), Fotón (biblioteca de juegos de Steam, Epic y GOG), " +
        "Centro Quantum (bienvenida, ajustes, modo rendimiento, sección «Vengo de Windows»). Steam con Proton ya viene instalado. " +
        "Las actualizaciones aparecen como un ícono en la barra superior y se instalan con un clic. " +
        "No uses emojis. Si no sabes algo, dilo con honestidad y sugiere preguntar en el Discord de Quantum: discord.gg/qWmEb9xHkZ.";

    function check(): void {
        status = "checking";
        const x = new XMLHttpRequest();
        x.onreadystatechange = () => {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            if (x.status !== 200) { status = "missing"; return; }
            try {
                models = JSON.parse(x.responseText).models.map(m => m.name);
            } catch (e) { models = []; }
            status = models.length ? "ready" : "nomodel";
        };
        x.open("GET", host + "/api/tags");
        x.send();
    }

    function newChat(): void {
        stop();
        messages = [];
    }

    function stop(): void {
        if (_xhr) { _xhr.abort(); _xhr = null; }
        busy = false;
    }

    function send(text: string): void {
        text = text.trim();
        if (!text || busy || status !== "ready") return;
        const history = messages.concat([{ role: "user", content: text }]);
        messages = history.concat([{ role: "assistant", content: "" }]);
        busy = true;

        const x = new XMLHttpRequest();
        _xhr = x;
        let seen = 0;
        const consume = () => {
            const t = x.responseText;
            const end = t.lastIndexOf("\n");
            if (end < seen) return;
            for (const line of t.substring(seen, end).split("\n")) {
                if (!line.trim()) continue;
                try {
                    const j = JSON.parse(line);
                    if (j.message?.content) {
                        const m = messages.slice();
                        if (m.length > 0) {
                            m[m.length - 1] = { role: "assistant", content: (m[m.length - 1]?.content ?? "") + j.message.content };
                            messages = m;
                        }
                    }
                    if (j.error) {
                        const m = messages.slice();
                        if (m.length > 0) {
                            m[m.length - 1] = { role: "assistant", content: "No pude responder: " + j.error };
                            messages = m;
                        }
                    }
                } catch (e) {}
            }
            seen = end + 1;
        };
        x.onreadystatechange = () => {
            if (x.readyState === XMLHttpRequest.LOADING) consume();
            if (x.readyState === XMLHttpRequest.DONE) {
                consume();
                if (x.status !== 200 && messages.length > 0 && !messages[messages.length - 1]?.content) {
                    const m = messages.slice();
                    m[m.length - 1] = { role: "assistant", content: "No pude conectarme con la IA. ¿Está encendido el servicio de Ollama?" };
                    messages = m;
                }
                busy = false;
                _xhr = null;
            }
        };
        x.open("POST", host + "/api/chat");
        x.setRequestHeader("Content-Type", "application/json");
        x.send(JSON.stringify({
            model: model,
            stream: true,
            think: false,
            messages: [{ role: "system", content: systemPrompt }].concat(history)
        }));
    }
}
