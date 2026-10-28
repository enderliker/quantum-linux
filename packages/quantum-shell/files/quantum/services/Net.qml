pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking

// Estado de la red: dispositivos, Wi-Fi y lista de redes visibles.
// Las redes las da NetworkManager a través de Quickshell (el mismo origen que
// usa el resto del shell), así que no hace falta nmcli ni analizar texto.
Singleton {
    id: root

    readonly property var devices: Networking.devices.values
    readonly property var wifiDevice: devices.find(d => d.type === DeviceType.Wifi) ?? null
    readonly property bool wired: devices.some(d => d.type === DeviceType.Wired && d.connected)
    readonly property bool wifiEnabled: Networking.wifiEnabled
    readonly property var wifi: wifiDevice?.networks.values.find(n => n.connected) ?? null
    readonly property real strength: wifi?.signalStrength ?? 0
    readonly property bool online: wired || wifi !== null
    readonly property bool hasDevice: wifiDevice !== null
    readonly property string connectedName: demo ? demoConnected : (wifi?.name ?? "")

    // QUANTUM_DEMO_WIFI reemplaza el nombre de la red en capturas y videos
    readonly property string demoName: Quickshell.env("QUANTUM_DEMO_WIFI") ?? ""
    readonly property string label: {
        if (wired)
            return "Cable";
        if (demo)
            return demoConnected || demoName || "Sin conexión";
        if (wifi)
            return demoName || wifi.name;
        return wifiEnabled ? "Sin conexión" : "Wi-Fi apagado";
    }
    readonly property string icon: {
        if (wired)
            return "lan";
        if (!wifiEnabled)
            return "wifi_off";
        if (!wifi)
            return "wifi_find";
        // signalStrength puede venir en 0..1 o 0..100 según el backend
        const s = strength > 1 ? strength / 100 : strength;
        return s > 0.66 ? "wifi" : s > 0.33 ? "wifi_2_bar" : "wifi_1_bar";
    }

    function toggleWifi(): void {
        Networking.wifiEnabled = !Networking.wifiEnabled;
    }

    // ------------------------------------------------------------------
    // Lista de redes
    // ------------------------------------------------------------------

    // Modo demo (solo pruebas y capturas): QUANTUM_DEMO_WIFI_LIST=<archivo> con
    // una red por línea: "SSID | señal | seguridad | conectada". Con esto se
    // puede probar la lista sin tocar la red real del equipo.
    readonly property string demoPath: Quickshell.env("QUANTUM_DEMO_WIFI_LIST") ?? ""
    readonly property bool demo: demoPath !== ""
    property var demoNetworks: []
    property string demoConnected: ""

    // Redes que ve NetworkManager. Solo aparecen mientras el escáner está activo.
    readonly property var networks: demo ? demoNetworks : (wifiDevice?.networks.values ?? [])

    property bool scanning: false
    property bool connecting: false
    property string pendingSsid: ""     // red que espera la contraseña
    property string password: ""
    property string status: ""          // mensaje para el usuario
    property bool statusError: false
    property var tracked: null          // red con la que se está conectando

    // Tipo de seguridad: "open", "psk", "enterprise", "wep" o "unknown".
    function securityKind(net: var): string {
        const sec = net?.security ?? WifiSecurityType.Unknown;
        if (sec === WifiSecurityType.Open || sec === WifiSecurityType.Owe)
            return "open";
        if (sec === WifiSecurityType.WpaPsk || sec === WifiSecurityType.Wpa2Psk || sec === WifiSecurityType.Sae)
            return "psk";
        if (sec === WifiSecurityType.Wpa2Eap || sec === WifiSecurityType.WpaEap || sec === WifiSecurityType.Leap)
            return "enterprise";
        if (sec === WifiSecurityType.StaticWep || sec === WifiSecurityType.DynamicWep)
            return "wep";
        return "unknown";
    }

    // Señal de la red en 0..100 (NetworkManager la da en 0..1).
    function signalOf(net: var): int {
        const s = net?.signalStrength ?? 0;
        return Math.round(s > 1 ? s : s * 100);
    }

    function find(ssid: string): var {
        for (const n of networks) {
            if (n.name === ssid)
                return n;
        }
        return null;
    }

    function setStatus(msg: string, error: bool): void {
        status = msg;
        statusError = error;
    }

    // ------------------------------------------------------------------
    // Escáner
    // ------------------------------------------------------------------

    // Enciende el escáner: es lo que hace que NetworkManager liste las redes.
    function startScan(): void {
        if (demo) {
            if (demoNetworks.length === 0) {
                demoProc.command = ["cat", demoPath];
                demoProc.running = true;
            }
            return;
        }
        const dev = wifiDevice;
        if (!dev)
            return;
        dev.scannerEnabled = true;
        scanning = true;
    }

    function stopScan(): void {
        const dev = wifiDevice;
        if (!dev || demo)
            return;
        dev.scannerEnabled = false;
        scanning = false;
    }

    // ------------------------------------------------------------------
    // Conexión
    // ------------------------------------------------------------------

    // Clic en una red: se conecta si se puede; si pide contraseña, la espera.
    function select(ssid: string): void {
        const net = find(ssid);
        if (!net) {
            setStatus("La red ya no está disponible", true);
            return;
        }
        if (net.connected === true) {
            disconnect(ssid);
            return;
        }
        const kind = securityKind(net);
        if (kind === "open" || net.known === true) {
            connect(net);
            return;
        }
        if (kind === "psk") {
            pendingSsid = ssid;
            password = "";
            setStatus("", false);
            return;
        }
        setStatus(kind === "enterprise"
            ? "Las redes empresariales se configuran en el editor de conexiones"
            : "Esta red no se puede conectar desde aquí", true);
    }

    // Conecta con la contraseña escrita.
    function connectPending(): void {
        const net = find(pendingSsid);
        if (!net) {
            pendingSsid = "";
            return;
        }
        if (password.trim() === "") {
            setStatus("Escribe la contraseña de la red", true);
            return;
        }
        if (demo) {
            demoConnect(net.name);
            return;
        }
        const psk = password;
        password = "";
        tracked = net;
        connecting = true;
        setStatus("Conectando a " + net.name + "…", false);
        net.connectWithPsk(psk);
    }

    function cancelPending(): void {
        pendingSsid = "";
        password = "";
    }

    function connect(net: var): void {
        if (demo) {
            demoConnect(net.name);
            return;
        }
        tracked = net;
        connecting = true;
        setStatus("Conectando a " + net.name + "…", false);
        net.connect();
    }

    function disconnect(ssid: string): void {
        const net = find(ssid);
        if (!net)
            return;
        if (demo) {
            demoDisconnect(net.name);
            return;
        }
        net.disconnect();
        setStatus("Desconectado de " + net.name, false);
    }

    // NetworkManager avisó de que la conexión falló.
    function onFailed(reason: int): void {
        connecting = false;
        const net = tracked;
        const ssid = net?.name ?? pendingSsid;
        switch (reason) {
        case ConnectionFailReason.NoSecrets:
            pendingSsid = ssid;
            password = "";
            setStatus("Escribe la contraseña para conectarte", false);
            return;
        case ConnectionFailReason.WifiAuthTimeout:
            setStatus("La contraseña no es correcta o la señal es muy débil", true);
            break;
        case ConnectionFailReason.WifiNetworkLost:
            setStatus("La red ya no está disponible", true);
            break;
        case ConnectionFailReason.WifiClientDisconnected:
            setStatus("Se perdió la conexión con la red", true);
            break;
        case ConnectionFailReason.WifiClientFailed:
            setStatus("No se pudo conectar a la red", true);
            break;
        default:
            setStatus("No se pudo conectar a " + ssid, true);
        }
        // Si la red pide contraseña, la dejamos lista para reintentar.
        if (net && securityKind(net) === "psk")
            pendingSsid = ssid;
    }

    // ------------------------------------------------------------------
    // Modo demo
    // ------------------------------------------------------------------

    // Formato del archivo: "SSID | señal | seguridad | conectada" (una por línea).
    function parseDemo(text: string): var {
        const out = [];
        for (const raw of text.split("\n")) {
            const line = raw.trim();
            if (!line || line.startsWith("#"))
                continue;
            const f = line.split("|").map(s => s.trim());
            const name = f[0] ?? "";
            if (!name)
                continue;
            const signal = Math.max(0, Math.min(100, parseInt(f[1]) || 0));
            const sec = (f[2] ?? "").toUpperCase();
            const active = (f[3] ?? "").toLowerCase().startsWith("s");
            out.push({
                name: name,
                signalStrength: signal / 100,
                security: sec === "" ? WifiSecurityType.Open
                    : (sec === "WPA3" ? WifiSecurityType.Sae : WifiSecurityType.Wpa2Psk),
                connected: active,
                known: active,
                connect: function() { root.demoConnect(this.name); },
                connectWithPsk: function() { root.demoConnect(this.name); }
            });
        }
        return out;
    }

    function demoConnect(ssid: string): void {
        demoConnected = ssid;
        demoNetworks = demoNetworks.map(n => {
            const copy = Object.assign({}, n);
            copy.connected = n.name === ssid;
            copy.known = copy.connected;
            return copy;
        });
        pendingSsid = "";
        password = "";
        setStatus("Conectado a " + ssid, false);
    }

    function demoDisconnect(ssid: string): void {
        demoConnected = "";
        demoNetworks = demoNetworks.map(n => {
            const copy = Object.assign({}, n);
            copy.connected = false;
            copy.known = false;
            return copy;
        });
        setStatus("Desconectado de " + ssid, false);
    }

    // ------------------------------------------------------------------

    // El escáner solo funciona mientras la página de Wi-Fi está abierta.
    Connections {
        target: Shell
        function onWifiPageChanged(): void {
            if (Shell.wifiPage)
                root.startScan();
            else
                root.stopScan();
        }
    }

    // Avisos de la red con la que se está conectando
    Connections {
        target: root.tracked
        function onStateChanged(): void {
            const net = root.tracked;
            if (!net)
                return;
            if (net.state === ConnectionState.Connected) {
                root.connecting = false;
                root.pendingSsid = "";
                root.setStatus("Conectado a " + net.name, false);
            } else if (net.state === ConnectionState.Disconnected) {
                root.connecting = false;
            }
        }
        function onConnectionFailed(reason: int): void {
            root.onFailed(reason);
        }
    }

    // Lectura de la lista de demostración
    Process {
        id: demoProc
        stdout: StdioCollector {
            id: demoOut
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: demoErr
            waitForEnd: true
        }
        onExited: code => {
            if (code !== 0) {
                root.demoNetworks = [];
                root.setStatus("No se pudo leer la lista de redes de prueba", true);
                return;
            }
            root.demoNetworks = root.parseDemo(demoOut.text);
        }
    }

    // Automatización y pruebas: qs -c quantum ipc call net <función>
    IpcHandler {
        target: "net"
        function scan(): void { root.startScan(); }
        function stop(): void { root.stopScan(); }
        function select(ssid: string): void { root.select(ssid); }
        function password(text: string): void { root.password = text; }
        function connect(): void { root.connectPending(); }
        function cancel(): void { root.cancelPending(); }
        function count(): int { return root.networks.length; }
        function status(): string { return root.status; }
    }
}
