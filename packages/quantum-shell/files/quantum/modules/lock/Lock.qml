import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam
import Quickshell.Io
import qs.services

// Pantalla de bloqueo (protocolo seguro de Wayland + PAM).
Scope {
    id: root

    property string password: ""
    // al volver a escribir, se quita el aviso de error
    onPasswordChanged: if (password.length && error) error = ""
    property bool busy: false
    property string error: ""
    // animación de salida: la pantalla se despide y recién entonces se desbloquea
    property bool leaving: false
    property bool success: false

    Timer {
        id: demo
        property string left: ""
        interval: 110; repeat: true
        onTriggered: {
            if (!left.length) { stop(); return; }
            root.password += left.charAt(0);
            left = left.substring(1);
        }
    }
    Timer {
        id: leaveTimer
        interval: 650
        onTriggered: {
            if (root.previewOpen) root.previewOpen = false;
            else lock.locked = false;
            root.leaving = false;
            root.success = false;
        }
    }
    function leave(): void {
        if (leaving) return;
        leaving = true;
        if (success) Sounds.play("unlock");
        leaveTimer.start();
    }

    function tryUnlock(): void {
        if (busy || password === "")
            return;
        busy = true;
        error = "";
        pam.start();
    }

    Connections {
        target: Shell
        function onLockRequested() {
            root.password = "";
            root.error = "";
            root.leaving = false;
            lock.locked = true;
            Sounds.play("lock");
        }
    }

    PamContext {
        id: pam
        configDirectory: Quickshell.shellDir + "/pam"
        config: "password.conf"

        onPamMessage: {
            if (responseRequired)
                respond(root.password);
        }
        onCompleted: result => {
            root.busy = false;
            if (result === PamResult.Success) {
                root.success = true;
                root.password = "";
                root.leave();
            } else {
                root.error = "Contraseña incorrecta";
                root.password = "";
                Sounds.play("error");
            }
        }
        onError: {
            root.busy = false;
            root.error = "No se pudo verificar la contraseña";
        }
    }

    WlSessionLock {
        id: lock

        Variants {
            model: Quickshell.screens

            WlSessionLockSurface {
                required property ShellScreen modelData
                screen: modelData
                color: Theme.surface
                LockSurface { lock: root }
            }
        }
    }

    // Vista previa (Personalizar → Bloqueo): la misma pantalla en una capa normal,
    // sin bloquear la sesión. Se cierra con Esc o Enter.
    property bool previewOpen: false
    LazyLoader {
        active: root.previewOpen
        PanelWindow {
            screen: Wm.screen
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "quantum-lock-preview"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: Theme.surface
            LockSurface { lock: root; preview: true; onClosePreview: { root.password = ""; root.leave(); } }
        }
    }

    IpcHandler {
        target: "lock"
        function lock(): void { Shell.lock(); }
        function preview(): void { root.previewOpen = true; Sounds.play("lock"); }
        function closePreview(): void { root.leave(); }
        // solo en la vista previa (para videos y pruebas): escribe letras de a una
        function demoType(text: string): void {
            if (!root.previewOpen) return;
            demo.left = text;
            demo.start();
        }
        function demoError(): void { if (root.previewOpen) { root.password = ""; root.error = ""; root.error = "Contraseña incorrecta"; Sounds.play("error"); } }
        function demoUnlock(): void { if (root.previewOpen) { root.success = true; root.password = ""; root.leave(); } }
    }
}
