pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    // Last successfully parsed payload. Defaults to an empty-ish object so
    // every binding is guarded before the first fetch arrives.
    property var model: ({ providers: [] })
    // True until the first successful fetch completes.
    property bool loading: true
    // True when the most recent parse failed (model is stale).
    property bool stale: false

    // Refresh interval, bound to config so it re-arms automatically.
    property int refreshMs: Plasmoid.configuration.refreshSeconds * 1000
    onRefreshMsChanged: {
        pollTimer.interval = root.refreshMs
        if (!root.loading) {
            pollTimer.restart()
        }
    }

    // Compact short codes for the three providers, in fixed order.
    readonly property var providerOrder: ["synthetic", "openai", "anthropic"]
    readonly property var providerCodes: ({ "synthetic": "S", "openai": "O", "anthropic": "A" })

    readonly property int smallFontSize: Math.round(Kirigami.Units.gridUnit * 0.75)

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    // Relative reset string: 'resets in Xd' / 'resets in Xh Ym' / 'resets in Xm',
    // or '' when resetsAt is null/invalid.
    function fmtReset(ms) {
        if (ms === null || ms === undefined || typeof ms !== "number" || isNaN(ms)) return ""
        var delta = ms - Date.now()
        if (delta <= 0) return "resets now"
        var totalMin = Math.floor(delta / 60000)
        if (totalMin < 1) return "resets in <1m"
        var days = Math.floor(totalMin / 1440)
        var hours = Math.floor((totalMin % 1440) / 60)
        var mins = totalMin % 60
        if (days >= 1) return "resets in " + days + "d"
        if (hours >= 1) return "resets in " + hours + "h " + mins + "m"
        return "resets in " + mins + "m"
    }

    // Local HH:mm string for an epoch-ms value.
    function fmtLocal(ms) {
        if (ms === null || ms === undefined || typeof ms !== "number" || isNaN(ms)) return ""
        return new Date(ms).toLocaleTimeString(Qt.locale(), "HH:mm")
    }

    // Color by used percentage + provider health.
    function usedColor(pct, ok) {
        if (!ok) return Kirigami.Theme.disabledTextColor
        if (pct > 90) return Kirigami.Theme.negativeTextColor
        if (pct >= 70) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.positiveTextColor
    }

    // Find a provider object by key; returns undefined when absent.
    function findProvider(key) {
        var providers = root.model && root.model.providers ? root.model.providers : []
        for (var i = 0; i < providers.length; i++) {
            if (providers[i].key === key) return providers[i]
        }
        return undefined
    }

    // The default window of a provider, or undefined.
    function defaultWindow(provider) {
        if (!provider || !provider.ok || !provider.windows) return undefined
        var dwid = provider.defaultWindowId
        for (var i = 0; i < provider.windows.length; i++) {
            if (provider.windows[i].id === dwid) return provider.windows[i]
        }
        return provider.windows.length > 0 ? provider.windows[0] : undefined
    }

    // Build a window list with an isDefault flag baked in (avoids needing
    // cross-delegate id access from nested Repeaters).
    function windowRows(provider) {
        if (!provider || !provider.ok || !provider.windows) return []
        var dwid = provider.defaultWindowId
        return provider.windows.map(function (w) {
            return {
                id: w.id,
                label: w.label,
                usedPercent: w.usedPercent,
                resetsAt: w.resetsAt,
                detail: w.detail,
                isDefault: (w.id === dwid)
            }
        })
    }

    // ------------------------------------------------------------------
    // Data source: executable engine runs the fetch script.
    // ------------------------------------------------------------------
    readonly property string fetchCommand: {
        var url = Qt.resolvedUrl("../scripts/usage-fetch.py").toString()
        return "python3 " + url.replace("file://", "")
    }

    P5Support.DataSource {
        id: executable
        engine: "executable"
        // We connect/disconnect sources manually (executable fires once per
        // connectSource), so never keep a persistent connectedSources list.

        onNewData: (sourceName, data) => {
            executable.disconnectSource(sourceName)
            if (!data) {
                root.stale = true
                root.scheduleNext()
                return
            }
            var stdout = data.stdout
            if (stdout === undefined || stdout === "") {
                root.stale = true
                root.scheduleNext()
                return
            }
            try {
                var parsed = JSON.parse(stdout)
                root.model = parsed
                root.loading = false
                root.stale = false
            } catch (e) {
                // Keep last good model; mark stale.
                root.stale = true
            }
            root.scheduleNext()
        }
    }

    // Re-poll timer: re-arms on refreshSeconds change via onRefreshMsChanged.
    Timer {
        id: pollTimer
        repeat: false
        interval: root.refreshMs
        onTriggered: root.fetch()
    }

    function fetch() {
        executable.connectSource(root.fetchCommand)
    }

    function scheduleNext() {
        pollTimer.interval = root.refreshMs
        pollTimer.restart()
    }

    Component.onCompleted: {
        // Kick off the first fetch immediately.
        fetch()
    }

    // ------------------------------------------------------------------
    // Shared detail layout (tooltip + full representation)
    // ------------------------------------------------------------------
    Component {
        id: detailComponent

        ColumnLayout {
            id: detailRoot
            spacing: Kirigami.Units.smallSpacing

            // Header: "Updated HH:mm"
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: {
                    var g = root.model && root.model.generatedAt ? root.model.generatedAt : null
                    return g !== null ? "Updated " + root.fmtLocal(g) : "Updated …"
                }
                font.bold: true
                color: Kirigami.Theme.textColor
                elide: Text.ElideRight
            }

            Repeater {
                model: root.providerOrder

                delegate: ColumnLayout {
                    id: providerColumn
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    readonly property var provider: root.findProvider(modelData)

                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        text: {
                            var p = providerColumn.provider
                            return (p && p.label) ? p.label : modelData
                        }
                        font.bold: true
                        color: Kirigami.Theme.textColor
                        elide: Text.ElideRight
                    }

                    // Error row when provider not ok.
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        visible: {
                            var p = providerColumn.provider
                            return !!p && p.ok === false
                        }
                        text: {
                            var p = providerColumn.provider
                            if (!p) return ""
                            var err = p.error ? p.error : "unavailable"
                            return "✗ " + err
                        }
                        color: Kirigami.Theme.negativeTextColor
                        wrapMode: Text.Wrap
                        elide: Text.ElideRight
                    }

                    // One row per window (isDefault baked into each row).
                    Repeater {
                        model: root.windowRows(providerColumn.provider)

                        delegate: ColumnLayout {
                            id: winColumn
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                PlasmaComponents.Label {
                                    text: modelData.isDefault ? "●" : " "
                                    color: Kirigami.Theme.textColor
                                    Layout.alignment: Qt.AlignTop
                                }

                                PlasmaComponents.Label {
                                    text: modelData.label ? modelData.label : modelData.id
                                    color: Kirigami.Theme.textColor
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                // Mini progress bar (two-rectangle).
                                Item {
                                    implicitWidth: 80
                                    implicitHeight: 12
                                    Layout.preferredWidth: 80
                                    Layout.preferredHeight: 12
                                    Layout.alignment: Qt.AlignVCenter

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 3
                                        color: Kirigami.Theme.backgroundColor
                                        border.color: Kirigami.Theme.disabledTextColor
                                        border.width: 1
                                    }

                                    Rectangle {
                                        width: Math.max(0, Math.min(1, (modelData.usedPercent || 0) / 100)) * parent.width
                                        height: parent.height
                                        radius: 3
                                        color: root.usedColor(modelData.usedPercent || 0, true)
                                    }
                                }

                                PlasmaComponents.Label {
                                    text: Math.round(modelData.usedPercent || 0) + "%"
                                    color: root.usedColor(modelData.usedPercent || 0, true)
                                    Layout.alignment: Qt.AlignVCenter
                                }
                            }

                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                Layout.leftMargin: 12
                                text: {
                                    var parts = []
                                    var d = modelData.detail
                                    if (d) parts.push(d)
                                    var r = root.fmtReset(modelData.resetsAt)
                                    if (r) parts.push(r)
                                    return parts.join(" · ")
                                }
                                font.pixelSize: root.smallFontSize
                                color: Kirigami.Theme.disabledTextColor
                                wrapMode: Text.Wrap
                                elide: Text.ElideRight
                            }
                        }
                    }

                    // Placeholder when provider ok but has no windows.
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        visible: {
                            var p = providerColumn.provider
                            return !!p && p.ok !== false && (!p.windows || p.windows.length === 0)
                        }
                        text: "no windows"
                        font.pixelSize: root.smallFontSize
                        color: Kirigami.Theme.disabledTextColor
                    }

                    // Placeholder when provider entirely absent from payload.
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        visible: !providerColumn.provider
                        text: "—"
                        font.pixelSize: root.smallFontSize
                        color: Kirigami.Theme.disabledTextColor
                    }
                }
            }

            // Stale / loading footer.
            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: root.stale || root.loading
                text: root.loading ? "loading…" : "stale data (last fetch failed)"
                font.pixelSize: root.smallFontSize
                color: Kirigami.Theme.disabledTextColor
            }
        }
    }

    // ------------------------------------------------------------------
    // Compact representation: adapts to panel orientation.
    // ------------------------------------------------------------------
    compactRepresentation: Item {
        id: compactRoot
        readonly property bool horizontal: Plasmoid.formFactor === PlasmaCore.Types.Horizontal

        Loader {
            id: compactLoader
            anchors.fill: parent
            sourceComponent: compactRoot.horizontal ? rowComp : columnComp
        }

        // Click-to-expand on top; hoverEnabled false so it doesn't steal the
        // tooltip's hover events.
        MouseArea {
            anchors.fill: parent
            hoverEnabled: false
            onClicked: plasmoid.expanded = !plasmoid.expanded
        }
    }

    Component {
        id: rowComp
        RowLayout {
            spacing: 2
            anchors.fill: parent
            Repeater {
                model: root.providerOrder
                delegate: segmentDelegateComp
            }
        }
    }

    Component {
        id: columnComp
        ColumnLayout {
            spacing: 0
            anchors.fill: parent
            Repeater {
                model: root.providerOrder
                delegate: segmentDelegateComp
            }
        }
    }

    // A single compact segment: code letter + default-window percent.
    Component {
        id: segmentDelegateComp

        RowLayout {
            id: seg
            required property var modelData
            spacing: 1
            Layout.alignment: Qt.AlignVCenter | Qt.AlignHCenter

            readonly property var provider: root.findProvider(modelData)
            readonly property var win: root.defaultWindow(provider)

            PlasmaComponents.Label {
                text: root.providerCodes[modelData] || "?"
                color: (seg.provider && seg.provider.ok === false)
                       ? Kirigami.Theme.disabledTextColor
                       : Kirigami.Theme.textColor
                font.bold: true
            }
            PlasmaComponents.Label {
                text: {
                    if (root.loading) return "…"
                    if (!seg.provider || seg.provider.ok === false) return "?"
                    if (!seg.win) return "?"
                    return Math.round(seg.win.usedPercent || 0) + "%"
                }
                color: {
                    if (root.loading) return Kirigami.Theme.disabledTextColor
                    if (!seg.provider || seg.provider.ok === false || !seg.win)
                        return Kirigami.Theme.disabledTextColor
                    return root.usedColor(seg.win.usedPercent || 0, true)
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Tooltip (rich, mouse-over)
    // ------------------------------------------------------------------
    toolTipItem: Loader {
        sourceComponent: detailComponent
    }

    // ------------------------------------------------------------------
    // Full representation (click-to-pin popup): same detail layout.
    // ------------------------------------------------------------------
    fullRepresentation: Loader {
        sourceComponent: detailComponent

        Layout.minimumWidth: 320
        Layout.minimumHeight: 200
        Layout.preferredWidth: 360
        Layout.preferredHeight: 280
    }
}
