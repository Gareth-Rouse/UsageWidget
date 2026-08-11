import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

KCM.SimpleKCM {
    id: page

    property alias cfg_refreshSeconds: spin.value
    // Comma-separated provider keys. "" = show everything the fetch reports,
    // the literal "none" = show nothing (an empty string cannot express that).
    property string cfg_enabledProviders: ""
    // Comma-separated "providerKey=windowId" choices.
    property string cfg_windowSelections: ""

    // windows per provider key: { key: [{ id, label }, …] }
    property var windowsByKey: ({})
    property string status: "loading…"

    readonly property string fetchCommand: {
        var url = Qt.resolvedUrl("../scripts/usage-fetch.py").toString()
        return "python3 " + url.replace("file://", "")
    }

    // One row per provider found in the payload.
    ListModel { id: rows }

    // ----------------------------------------------------------------------
    // Config <-> model
    // ----------------------------------------------------------------------
    function enabledList() {
        var raw = page.cfg_enabledProviders.trim()
        if (raw === "") return null          // null = "all enabled"
        if (raw === "none") return []
        return raw.split(",")
                  .map(function (s) { return s.trim() })
                  .filter(function (s) { return s !== "" })
    }

    function selectionMap() {
        var map = ({})
        var parts = page.cfg_windowSelections.split(",")
        for (var i = 0; i < parts.length; i++) {
            var eq = parts[i].indexOf("=")
            if (eq <= 0) continue
            map[parts[i].slice(0, eq).trim()] = parts[i].slice(eq + 1).trim()
        }
        return map
    }

    function rebuild(payload) {
        if (!payload || !payload.providers) return
        var enabled = page.enabledList()
        var selections = page.selectionMap()
        var byKey = ({})

        rows.clear()
        for (var i = 0; i < payload.providers.length; i++) {
            var p = payload.providers[i]
            var wins = []
            for (var j = 0; j < (p.windows || []).length; j++) {
                wins.push({ id: p.windows[j].id, label: p.windows[j].label })
            }
            byKey[p.key] = wins

            var chosen = selections[p.key] || p.defaultWindowId || ""
            var valid = false
            for (var k = 0; k < wins.length; k++) {
                if (wins[k].id === chosen) valid = true
            }
            if (!valid) chosen = wins.length > 0 ? wins[0].id : ""

            rows.append({
                key: p.key,
                label: p.label || p.key,
                error: p.ok === false ? (p.error || "unavailable") : "",
                windowId: chosen,
                enabled: enabled === null || enabled.indexOf(p.key) >= 0
            })
        }
        page.windowsByKey = byKey
        page.status = payload.generatedAt
            ? "updated " + new Date(payload.generatedAt).toLocaleTimeString(Qt.locale(), "HH:mm")
            : ""
    }

    function serialize() {
        var keys = []
        var sels = []
        for (var i = 0; i < rows.count; i++) {
            var r = rows.get(i)
            if (r.enabled) keys.push(r.key)
            if (r.windowId !== "") sels.push(r.key + "=" + r.windowId)
        }
        page.cfg_enabledProviders = keys.length > 0 ? keys.join(",") : "none"
        page.cfg_windowSelections = sels.join(",")
    }

    function windowIndex(key, windowId) {
        var wins = page.windowsByKey[key] || []
        for (var i = 0; i < wins.length; i++) {
            if (wins[i].id === windowId) return i
        }
        return -1
    }

    // ----------------------------------------------------------------------
    // Data: one live fetch when the dialog opens (~1s).
    // ----------------------------------------------------------------------

    P5Support.DataSource {
        id: executable
        engine: "executable"
        onNewData: (sourceName, data) => {
            executable.disconnectSource(sourceName)
            if (data && data.stdout) {
                try {
                    page.rebuild(JSON.parse(data.stdout))
                    return
                } catch (e) {
                    // fall through to the error status below
                }
            }
            if (rows.count === 0) page.status = "could not read usage data"
        }
    }

    Component.onCompleted: {
        // cfg_* properties are assigned by the config dialog after the page is
        // constructed, so defer the fetch by one event-loop turn.
        Qt.callLater(function () { executable.connectSource(page.fetchCommand) })
    }

    // ----------------------------------------------------------------------
    // UI
    // ----------------------------------------------------------------------
    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            Label { text: "Refresh interval (seconds)" }
            SpinBox {
                id: spin
                from: 30
                to: 86400
            }
        }

        Label {
            text: "Providers shown on the panel"
            font.bold: true
        }

        Label {
            Layout.fillWidth: true
            visible: rows.count === 0
            text: page.status
            opacity: 0.7
        }

        Repeater {
            model: rows

            delegate: RowLayout {
                id: row
                required property int index
                required property var model
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                CheckBox {
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 8
                    text: row.model.label
                    checked: row.model.enabled
                    onToggled: {
                        rows.setProperty(row.index, "enabled", checked)
                        page.serialize()
                    }
                }

                ComboBox {
                    id: combo
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 14
                    enabled: row.model.error === "" && count > 0
                    textRole: "label"
                    valueRole: "id"
                    model: page.windowsByKey[row.model.key] || []
                    currentIndex: page.windowIndex(row.model.key, row.model.windowId)
                    displayText: combo.currentIndex >= 0 ? combo.currentText
                                                         : "no windows"
                    onActivated: {
                        rows.setProperty(row.index, "windowId", combo.currentValue)
                        page.serialize()
                    }
                }

                Label {
                    Layout.fillWidth: true
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                    visible: row.model.error !== ""
                    text: row.model.error
                    color: Kirigami.Theme.negativeTextColor
                    elide: Text.ElideRight
                }
            }
        }
    }
}
