/*
    A bottom panel on every screen that has none. plasmashell runs this once
    per user at start, for new and existing accounts; `ujust setup-panels`
    evaluates the same file again for a user whose first login had one screen.

    A screen that carries any panel is left alone, so an existing
    multi-screen set-up is never touched. The new panel copies the primary
    panel's geometry and widgets except the system tray: a second systemtray
    applet spawns a duplicate tray containment. The task manager is filtered
    to its own screen and keeps the primary's pinned launchers.
*/

const FALLBACK_WIDGETS = [
    "org.kde.plasma.kickoff",
    "org.kde.plasma.pager",
    "org.kde.plasma.icontasks",
    "org.kde.plasma.marginsseparator",
    "org.kde.plasma.digitalclock",
    "org.kde.plasma.showdesktop"
];

function primaryPanel() {
    const all = panels();
    return all.find(p => p.screen === 0 && p.location === "bottom") || all.find(p => p.screen === 0) || null;
}

function launchersOf(panel) {
    if (!panel) {
        return "";
    }
    const tasks = panel.widgets("org.kde.plasma.icontasks");
    if (tasks.length === 0) {
        return "";
    }
    tasks[0].currentConfigGroup = ["General"];
    return tasks[0].readConfig("launchers", "");
}

const primary = primaryPanel();
const launchers = launchersOf(primary);
const types = primary ? primary.widgets().map(w => w.type) : FALLBACK_WIDGETS;
let added = 0;

for (let s = 1; s < screenCount; s++) {
    if (panels().some(p => p.screen === s)) {
        continue;
    }
    const panel = new Panel;
    panel.location = "bottom";
    panel.screen = s;
    if (primary) {
        panel.height = primary.height;
        panel.floating = primary.floating;
        panel.hiding = primary.hiding;
        panel.alignment = primary.alignment;
        panel.lengthMode = primary.lengthMode;
    }
    for (const type of types) {
        if (type === "org.kde.plasma.systemtray") {
            continue;
        }
        const widget = panel.addWidget(type);
        if (type === "org.kde.plasma.icontasks") {
            widget.currentConfigGroup = ["General"];
            widget.writeConfig("showOnlyCurrentScreen", true);
            if (launchers) {
                widget.writeConfig("launchers", launchers);
            }
        } else if (type === "org.kde.plasma.digitalclock") {
            widget.currentConfigGroup = ["Appearance"];
            widget.writeConfig("showSeconds", 2);
        }
        widget.reloadConfig();
    }
    added++;
}

print("bazzite-mx-panels: " + screenCount + " screen(s), " + added + " panel(s) added");
