import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import qs.services
import qs.components
import "cards"

// Pantalla de bloqueo: un panel de vidrio con la hora, tu foto y la contraseña al
// centro, y tarjetas a los lados (se eligen y ordenan en Personalizar → Bloqueo).
// Animaciones: entrada escalonada, reloj que rueda, órbitas de Quantum alrededor de
// la foto, puntos de contraseña que aparecen, sacudida al fallar y salida al entrar.
Item {
    id: root

    required property var lock
    property bool preview: false          // vista previa desde Personalizar (no bloquea)
    signal closePreview
    anchors.fill: parent

    // Sin animaciones (Personalizar → Ventanas): todo aparece quieto
    readonly property bool still: Settings.windows.animations === "none"
    readonly property real k: Theme.animMult > 0 ? Theme.animMult : 0.001

    // reloj de animación continuo (fondo, órbitas, resplandor)
    property real time: 0
    readonly property bool lowPower: !!Quickshell.env("QUANTUM_SOFTWARE_GL")
    FrameAnimation {
        running: !root.still && !root.lowPower
        onTriggered: root.time += frameTime
    }
    Timer {
        running: !root.still && root.lowPower
        interval: 50; repeat: true
        onTriggered: root.time += 0.05
    }

    // entrada (0 → 1) y salida al desbloquear (0 → 1)
    property real appear: 0
    NumberAnimation on appear { from: 0; to: 1; duration: 1400 * root.k; easing.type: Easing.Linear }
    property real out: root.lock.leaving ? 1 : 0
    Behavior on out { NumberAnimation { duration: 600 * root.k; easing.type: Easing.InOutCubic } }

    // avance (0..1) de un elemento que entra `delay` ms después y dura `len` ms
    function stage(delay: real, len: real): real {
        return Math.max(0, Math.min(1, (appear * 1400 - delay) / len));
    }
    function back(x: real): real { const c = 1.7; return 1 + (c + 1) * Math.pow(x - 1, 3) + c * Math.pow(x - 1, 2); }
    function ease(x: real): real { return 1 - Math.pow(1 - x, 3); }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }
    readonly property bool h24: Settings.clock.format24h

    // Tarjetas disponibles: clave → componente
    readonly property var cards: ({
        weather: weatherC, fetch: fetchC, media: mediaC, stats: statsC, notifs: notifsC, calendar: calendarC
    })
    Component { id: weatherC; WeatherCard {} }
    Component { id: fetchC; FetchCard {} }
    Component { id: mediaC; MediaCard {} }
    Component { id: statsC; StatsCard {} }
    Component { id: notifsC; NotifsCard {} }
    Component { id: calendarC; CalendarCard {} }

    // ---------------------------------------------------------- fondo vivo
    Item {
        anchors.fill: parent
        opacity: 1 - 0.6 * root.out
        Image {
            anchors.fill: parent
            visible: Settings.appearance.wallpaper !== "quantum:live"
            source: visible && Settings.appearance.wallpaper ? "file://" + Settings.appearance.wallpaper : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize: Qt.size(root.width / 2, root.height / 2)
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.anim } }
            // acercamiento lento (efecto «Ken Burns»)
            scale: 1.12 - 0.07 * root.ease(root.appear) + 0.025 * Math.sin(root.time * 0.08)
            layer.enabled: true
            layer.effect: MultiEffect { blurEnabled: true; blur: 0.4 + 0.6 * root.ease(root.stage(0, 700)); blurMax: 64 }
        }
        LiveWallpaper {
            anchors.fill: parent
            visible: Settings.appearance.wallpaper === "quantum:live"
            running: visible && !root.still
            scale: 1.12 - 0.07 * root.ease(root.appear)
        }
        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.38 * root.stage(0, 700)) }

        // manchas de luz de colores que flotan detrás del panel
        Repeater {
            model: [
                { c: Theme.primary, x: 0.22, y: 0.3, r: 520, s: 0.11 },
                { c: Theme.brandViolet, x: 0.78, y: 0.7, r: 600, s: 0.08 },
                { c: Theme.brandCyan, x: 0.55, y: 0.18, r: 420, s: 0.13 },
            ]
            Rectangle {
                required property var modelData
                required property int index
                width: modelData.r; height: width; radius: width / 2
                x: root.width * modelData.x - width / 2 + Math.sin(root.time * modelData.s + index * 2) * 90
                y: root.height * modelData.y - height / 2 + Math.cos(root.time * modelData.s * 0.8 + index) * 70
                color: modelData.c
                opacity: 0.22 * root.stage(0, 900)
                layer.enabled: true
                layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 64 }
            }
        }
    }

    // ------------------------------------------------------------- panel
    Rectangle {
        id: panel
        readonly property bool sides: Settings.lock.left.length + Settings.lock.right.length > 0 && root.width > 1100
        anchors.centerIn: parent
        width: sides ? Math.min(root.width - 120, 1560) : 560
        height: Math.min(root.height - 140, 860)
        radius: 40
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.78)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.07)
        // entra creciendo con rebote; al desbloquear se agranda y se desvanece
        scale: (0.9 + 0.1 * root.back(root.stage(0, 650))) * (1 + 0.06 * root.out)
        opacity: root.stage(0, 400) * (1 - root.out)

        // borde con el degradado de Quantum girando lento
        Item {
            anchors.fill: parent
            opacity: 0.6
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: ringMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
            }
            Rectangle {
                anchors.centerIn: parent
                width: Math.hypot(parent.width, parent.height); height: width
                rotation: root.time * 18
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.35; color: Theme.brandCyan }
                    GradientStop { position: 0.5; color: Theme.brandIndigo }
                    GradientStop { position: 0.65; color: Theme.brandViolet }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
        }
        Item {
            id: ringMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle {
                anchors.fill: parent
                radius: panel.radius
                color: "transparent"
                border.width: 2
                border.color: "white"
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 18
            spacing: 18

            // columnas de tarjetas (izquierda y derecha usan esta plantilla)
            component Side: ColumnLayout {
                id: side
                property var keys: []
                property int dir: -1                 // -1 entra desde la izquierda, 1 desde la derecha
                Layout.preferredWidth: 430
                Layout.minimumWidth: 430
                Layout.maximumWidth: 430
                Layout.fillHeight: true
                spacing: 16
                Repeater {
                    model: side.keys
                    Loader {
                        id: ld
                        required property string modelData
                        required property int index
                        readonly property real e: root.ease(root.stage(220 + index * 120, 650))
                        Layout.fillWidth: true
                        Layout.fillHeight: index === side.keys.length - 1
                        Layout.preferredHeight: item ? item.implicitHeight : 0
                        sourceComponent: root.cards[modelData] ?? null
                        opacity: e * (1 - root.out)
                        transform: Translate { x: side.dir * ((1 - ld.e) * 90 + root.out * 70) }
                    }
                }
            }

            Side {
                visible: panel.sides && Settings.lock.left.length > 0
                keys: Settings.lock.left
                dir: -1
            }

            // centro: hora, foto y contraseña
            Item {
                Layout.fillWidth: true
                Layout.minimumWidth: 520
                Layout.fillHeight: true

                Column {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -10
                    spacing: 0

                    // hora: horas gigantes y minutos al lado; cada dígito rueda al cambiar
                    Row {
                        id: clockRow
                        readonly property real e: root.ease(root.stage(120, 700))
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 18
                        opacity: e
                        transform: Translate { y: (1 - clockRow.e) * -40 }
                        Row {
                            Repeater {
                                model: 2
                                RollDigit {
                                    required property int index
                                    ch: Qt.formatDateTime(clock.date, root.h24 ? "HH" : "hh").charAt(index)
                                    color: Theme.primary
                                    font.family: Theme.font
                                    font.pixelSize: 210
                                    font.weight: Font.Black
                                    font.letterSpacing: -6
                                    font.features: { "tnum": 1 }
                                }
                            }
                        }
                        Column {
                            anchors.top: parent.top
                            anchors.topMargin: 30
                            spacing: 8
                            Row {
                                Repeater {
                                    model: 2
                                    RollDigit {
                                        required property int index
                                        ch: Qt.formatDateTime(clock.date, "mm").charAt(index)
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 104
                                        font.weight: Font.Black
                                        font.letterSpacing: -3
                                        font.features: { "tnum": 1 }
                                    }
                                }
                            }
                            Rectangle {
                                visible: !root.h24
                                width: ap.implicitWidth + 22; height: 56; radius: 16
                                color: Theme.surfaceHighest
                                Txt { id: ap; anchors.centerIn: parent; text: clock.date.getHours() < 12 ? "AM" : "PM"; font.pixelSize: 34; font.weight: Font.Black; color: Theme.fg }
                            }
                        }
                    }
                    Txt {
                        readonly property real e: root.ease(root.stage(260, 600))
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: clock.date.toLocaleDateString(Qt.locale(), "dddd • d MMM").toUpperCase()
                        font.pixelSize: 22; font.weight: Font.Bold
                        font.letterSpacing: 1 + 8 * (1 - e)
                        color: Theme.fg
                        opacity: e
                    }

                    Item { width: 1; height: 36 }

                    // foto de perfil en hexágono, con las órbitas de Quantum girando detrás
                    Item {
                        id: avatarBox
                        readonly property real e: root.stage(380, 800)
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 330; height: 230
                        scale: root.back(e) * (1 - 0.15 * root.out)
                        rotation: (1 - root.ease(e)) * -12
                        opacity: Math.min(1, e * 2)

                        // resplandor que respira (rojo al fallar, verde al entrar)
                        Rectangle {
                            anchors.centerIn: parent
                            width: 300; height: 300; radius: 150
                            color: root.lock.error ? Theme.error : root.lock.success ? "#3DDC84" : Theme.primary
                            Behavior on color { ColorAnimation { duration: 300 } }
                            opacity: 0.32 + 0.1 * Math.sin(root.time * 1.6)
                            scale: 1 + 0.06 * Math.sin(root.time * 1.6)
                            layer.enabled: true
                            layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 64 }
                        }
                        // órbitas con electrones
                        Item {
                            anchors.centerIn: parent
                            width: 490; height: 490
                            rotation: Math.sin(root.time * 0.35) * 8
                            Repeater {
                                model: [-22, 0, 22]
                                Item {
                                    id: orb
                                    required property real modelData
                                    required property int index
                                    anchors.fill: parent
                                    rotation: modelData
                                    readonly property real a: root.time * (0.7 + index * 0.25) + index * 2.1
                                    Shape {
                                        anchors.fill: parent
                                        preferredRendererType: Shape.CurveRenderer
                                        ShapePath {
                                            strokeWidth: 2
                                            strokeColor: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.28)
                                            fillColor: "transparent"
                                            PathAngleArc { centerX: 245; centerY: 245; radiusX: 235; radiusY: 58; startAngle: 0; sweepAngle: 360 }
                                        }
                                    }
                                    Rectangle {
                                        width: 12; height: 12; radius: 6
                                        x: 245 + 235 * Math.cos(orb.a) - 6
                                        y: 245 + 58 * Math.sin(orb.a) - 6
                                        color: [Theme.brandCyan, Theme.brandIndigo, Theme.brandViolet][orb.index]
                                        border.width: 2; border.color: "white"
                                        // por detrás de la foto (mitad de arriba) queda tapado
                                        z: Math.sin(orb.a) > 0 ? 2 : -1
                                    }
                                }
                            }
                        }

                        Item {
                            id: avatar
                            anchors.centerIn: parent
                            width: 330; height: 230
                            readonly property string home: Quickshell.env("HOME") ?? ""
                            readonly property var sources: ["file://" + home + "/.face", "file:///var/lib/AccountsService/icons/" + (Quickshell.env("USER") ?? "")]
                            property int si: 0
                            Image {
                                id: face
                                visible: false
                                anchors.fill: parent
                                sourceSize: Qt.size(660, 460)
                                fillMode: Image.PreserveAspectCrop
                                Component.onCompleted: source = avatar.sources[0]
                                // si no hay foto, prueba la siguiente; al final queda el logo
                                onStatusChanged: if (status === Image.Error) {
                                    avatar.si++;
                                    if (avatar.si < avatar.sources.length) source = avatar.sources[avatar.si];
                                }
                            }
                            Shape {
                                anchors.fill: parent
                                preferredRendererType: Shape.CurveRenderer
                                ShapePath {
                                    strokeWidth: 3
                                    strokeColor: root.lock.error ? Theme.error : Qt.rgba(1, 1, 1, 0.12)
                                    fillColor: avatar.si < avatar.sources.length ? "transparent" : Theme.surfaceHigh
                                    fillItem: avatar.si < avatar.sources.length ? face : null
                                    startX: avatar.width * 0.22; startY: 0
                                    PathLine { x: avatar.width * 0.78; y: 0 }
                                    PathArc { x: avatar.width * 0.86; y: avatar.height * 0.08; radiusX: 30; radiusY: 30 }
                                    PathLine { x: avatar.width; y: avatar.height * 0.46 }
                                    PathArc { x: avatar.width; y: avatar.height * 0.54; radiusX: 30; radiusY: 30 }
                                    PathLine { x: avatar.width * 0.86; y: avatar.height * 0.92 }
                                    PathArc { x: avatar.width * 0.78; y: avatar.height; radiusX: 30; radiusY: 30 }
                                    PathLine { x: avatar.width * 0.22; y: avatar.height }
                                    PathArc { x: avatar.width * 0.14; y: avatar.height * 0.92; radiusX: 30; radiusY: 30 }
                                    PathLine { x: 0; y: avatar.height * 0.54 }
                                    PathArc { x: 0; y: avatar.height * 0.46; radiusX: 30; radiusY: 30 }
                                    PathLine { x: avatar.width * 0.14; y: avatar.height * 0.08 }
                                    PathArc { x: avatar.width * 0.22; y: 0; radiusX: 30; radiusY: 30 }
                                }
                            }
                            // sin foto: logo de Quantum al centro, meciéndose suave
                            Image {
                                visible: avatar.si >= avatar.sources.length
                                anchors.centerIn: parent
                                width: 150; height: 150
                                source: Quickshell.shellDir + "/assets/quantum-mark.svg"
                                sourceSize: Qt.size(300, 300)
                                rotation: Math.sin(root.time * 0.6) * 8
                            }
                        }
                        // al entrar: check verde sobre la foto
                        Rectangle {
                            anchors.centerIn: parent
                            width: 74; height: 74; radius: 37
                            color: "#22B573"
                            scale: root.lock.success ? 1 : 0
                            Behavior on scale { NumberAnimation { duration: 320 * root.k; easing.type: Easing.OutBack } }
                            Icon { anchors.centerIn: parent; text: "check"; size: 44; color: "white" }
                        }
                    }

                    Item { width: 1; height: 28 }

                    // contraseña
                    Item {
                        id: fieldBox
                        readonly property real e: root.ease(root.stage(520, 650))
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 340; height: 54
                        opacity: e
                        transform: Translate { y: (1 - fieldBox.e) * 30 }

                        Rectangle {
                            id: field
                            width: parent.width; height: parent.height
                            radius: 27
                            color: Theme.surfaceHigh
                            border.width: input.activeFocus || root.lock.error ? 2 : 1
                            border.color: root.lock.error ? Theme.error : input.activeFocus ? Theme.alpha(Theme.primary, 0.7) : Qt.rgba(1, 1, 1, 0.1)
                            Behavior on border.color { ColorAnimation { duration: 200 } }

                            Icon {
                                x: 20; anchors.verticalCenter: parent.verticalCenter
                                text: root.lock.success ? "lock_open" : "lock"
                                size: 20; color: root.lock.success ? "#3DDC84" : Theme.fgMuted
                            }
                            Connections {
                                target: root.lock
                                function onPasswordChanged() {
                                    if (input.text !== root.lock.password)
                                        input.text = root.lock.password;
                                }
                            }

                            TextInput {
                                id: input
                                anchors.fill: parent
                                anchors.leftMargin: 54
                                anchors.rightMargin: 56
                                verticalAlignment: TextInput.AlignVCenter
                                echoMode: TextInput.Password
                                color: "transparent"           // se ven los puntos animados
                                selectionColor: "transparent"
                                selectedTextColor: "transparent"
                                cursorDelegate: Item {}
                                font.pixelSize: Theme.textLarge
                                focus: true
                                enabled: !root.lock.busy && !root.lock.leaving
                                text: root.lock.password
                                onTextChanged: root.lock.password = text
                                onAccepted: root.preview ? root.closePreview() : root.lock.tryUnlock()
                                Keys.onEscapePressed: if (root.preview) root.closePreview()
                                Component.onCompleted: forceActiveFocus()
                                Txt {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: !input.text
                                    text: root.lock.busy ? "Verificando…" : "Escribe tu contraseña"
                                    color: Theme.fgMuted
                                    font.pixelSize: Theme.textNormal + 1
                                }
                            }
                            // puntos que aparecen con rebote; al verificar hacen una ola
                            Row {
                                x: 54; anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 54 - 56
                                height: 24
                                clip: true
                                spacing: 7
                                Repeater {
                                    model: input.text.length
                                    Rectangle {
                                        id: dot
                                        required property int index
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 11; height: 11; radius: 5.5
                                        color: root.lock.success ? "#3DDC84" : Theme.primary
                                        scale: 0
                                        NumberAnimation on scale { to: 1; duration: 260 * root.k; easing.type: Easing.OutBack; easing.overshoot: 2.5 }
                                        transform: Translate { y: root.lock.busy ? -5 * Math.max(0, Math.sin(root.time * 9 - dot.index * 0.6)) : 0 }
                                    }
                                }
                            }
                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 7
                                anchors.verticalCenter: parent.verticalCenter
                                width: 40; height: 40; radius: 20
                                color: input.text ? Theme.primary : "transparent"
                                Behavior on color { ColorAnimation { duration: 180 } }
                                scale: input.text ? 1 : 0.85
                                Behavior on scale { NumberAnimation { duration: 220 * root.k; easing.type: Easing.OutBack } }
                                Icon {
                                    anchors.centerIn: parent
                                    text: root.lock.busy ? "progress_activity" : "arrow_forward"
                                    color: input.text ? Theme.primaryFg : Theme.fg
                                    rotation: root.lock.busy ? root.time * 360 : 0
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.preview ? root.closePreview() : root.lock.tryUnlock() }
                            }
                        }
                        // sacudida al fallar
                        SequentialAnimation {
                            id: shake
                            NumberAnimation { target: field; property: "x"; to: 16; duration: 45 }
                            NumberAnimation { target: field; property: "x"; to: -14; duration: 70 }
                            NumberAnimation { target: field; property: "x"; to: 9; duration: 60 }
                            NumberAnimation { target: field; property: "x"; to: -5; duration: 50 }
                            NumberAnimation { target: field; property: "x"; to: 0; duration: 45 }
                        }
                        Connections {
                            target: root.lock
                            function onErrorChanged() { if (root.lock.error) shake.start(); }
                        }
                    }
                    Item { width: 1; height: 14 }
                    Txt {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.lock.success ? "¡Hola de nuevo!" : root.lock.error || (Quickshell.env("USER") ?? "")
                        color: root.lock.success ? "#3DDC84" : root.lock.error ? Theme.error : Theme.fgMuted
                        font.weight: Font.DemiBold
                        opacity: root.ease(root.stage(620, 600))
                    }
                }
            }

            Side {
                visible: panel.sides && Settings.lock.right.length > 0
                keys: Settings.lock.right
                dir: 1
            }
        }
    }

    // marca abajo
    Row {
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 22
        spacing: 8
        opacity: 0.7 * root.ease(root.stage(900, 500)) * (1 - root.out)
        Image { width: 20; height: 20; source: Quickshell.shellDir + "/assets/quantum-mark.svg"; sourceSize: Qt.size(40, 40) }
        Txt { text: "Quantum Linux"; color: "white" }
    }
}
