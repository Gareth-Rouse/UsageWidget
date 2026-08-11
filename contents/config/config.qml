import QtQuick
import org.kde.plasma.configuration

// Plasma reads this file as the *list of settings pages*, not as a page. The
// actual UI lives in configGeneral.qml; without this model the applet only
// gets the built-in Keyboard Shortcuts / About entries.
ConfigModel {
    ConfigCategory {
        name: "General"
        icon: "configure"
        source: "configGeneral.qml"
    }
}
