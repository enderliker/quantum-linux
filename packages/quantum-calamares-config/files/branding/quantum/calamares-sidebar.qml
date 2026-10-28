/* Barra lateral del instalador de Quantum Linux: los pasos como una línea de
   progreso vertical que se va llenando con el degradado de Quantum.
   SPDX-License-Identifier: GPL-3.0-or-later
*/
import io.calamares.ui 1.0
import io.calamares.core 1.0

import QtQuick 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: sideBar
    anchors.fill: parent
    color: "#0D0B14"

    readonly property int current: ViewManager.currentStepIndex
    readonly property int count: steps.count

    // resplandor de color arriba
    Rectangle {
        width: parent.width * 1.6; height: width; radius: width / 2
        x: -parent.width * 0.6; y: -width * 0.62
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#3A2E8F" }
            GradientStop { position: 1.0; color: "#0D0B14" }
        }
        opacity: 0.55
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 0

        // logo y nombre
        RowLayout {
            Layout.bottomMargin: 28
            spacing: 10
            Image {
                source: "file://" + Branding.imagePath(Branding.ProductLogo)
                sourceSize.width: 88; sourceSize.height: 88
                Layout.preferredWidth: 44; Layout.preferredHeight: 44
            }
            ColumnLayout {
                spacing: -2
                Text { text: "Quantum"; color: "#FFFFFF"; font.family: "Inter"; font.pixelSize: 20; font.weight: Font.ExtraBold }
                Text { text: "INSTALADOR"; color: "#9C95B8"; font.family: "Inter"; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 3 }
            }
        }

        // pasos
        Repeater {
            id: steps
            model: ViewManager
            Item {
                id: step
                required property int index
                required property string display
                readonly property bool done: index < sideBar.current
                readonly property bool here: index === sideBar.current
                Layout.fillWidth: true
                Layout.preferredHeight: 48

                // línea que une los pasos (se llena al avanzar)
                Rectangle {
                    visible: step.index < sideBar.count - 1
                    x: 15; y: 32; width: 2; height: 32
                    color: "#2A2933"
                    Rectangle {
                        width: parent.width
                        height: step.done ? parent.height : 0
                        Behavior on height { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#4FD8FF" }
                            GradientStop { position: 1.0; color: "#B14DFF" }
                        }
                    }
                }
                // círculo
                Rectangle {
                    id: dot
                    x: 0; y: 0
                    width: 32; height: 32; radius: 16
                    color: step.done || step.here ? "transparent" : "#16141F"
                    border.width: step.done || step.here ? 0 : 2
                    border.color: "#3A3848"
                    gradient: step.done || step.here ? grad : null
                    scale: step.here ? 1.08 : 1
                    Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
                    Gradient {
                        id: grad
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "#4FD8FF" }
                        GradientStop { position: 0.5; color: "#6A5CFF" }
                        GradientStop { position: 1.0; color: "#B14DFF" }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: step.done ? "check" : String(step.index + 1)
                        font.family: step.done ? "Material Symbols Rounded" : "Inter"
                        font.pixelSize: step.done ? 20 : 14
                        font.weight: Font.Bold
                        color: step.done || step.here ? "#FFFFFF" : "#7D7896"
                    }
                }
                // brillo del paso actual
                Rectangle {
                    visible: step.here
                    anchors.centerIn: dot
                    width: 46; height: 46; radius: 23
                    color: "transparent"
                    border.width: 2
                    border.color: "#6A5CFF"
                    opacity: 0.45
                }
                Text {
                    anchors.verticalCenter: dot.verticalCenter
                    x: 48
                    width: parent.width - 48
                    text: step.display
                    elide: Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 15
                    font.weight: step.here ? Font.Bold : Font.Medium
                    color: step.here ? "#FFFFFF" : step.done ? "#C8C4D4" : "#7D7896"
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
            }
        }

        Item { Layout.fillHeight: true }

        Text {
            Layout.fillWidth: true
            text: "Quantum Linux 1.0 «Quark»"
            color: "#7D7896"
            font.family: "Inter"; font.pixelSize: 12
        }
        Text {
            Layout.fillWidth: true
            Layout.topMargin: 2
            text: "Como Windows, pero mejor."
            color: "#9C8CFF"
            font.family: "Inter"; font.pixelSize: 12; font.weight: Font.DemiBold
        }
        Text {
            Layout.topMargin: 10
            visible: debug.enabled
            text: "Depurar"
            color: "#9C95B8"
            font.family: "Inter"; font.pixelSize: 12; font.underline: true
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: debug.toggle() }
        }
    }
}
