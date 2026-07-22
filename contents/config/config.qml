import org.kde.kcmutils as KCM
import QtQuick.Controls
import QtQuick.Layouts

KCM.SimpleKCM {
    property alias cfg_refreshSeconds: spin.value

    ColumnLayout {
        RowLayout {
            Label {
                text: i18nc("@label", "Refresh interval (seconds)")
            }
            SpinBox {
                id: spin
                from: 30
                to: 86400
            }
        }
    }
}
