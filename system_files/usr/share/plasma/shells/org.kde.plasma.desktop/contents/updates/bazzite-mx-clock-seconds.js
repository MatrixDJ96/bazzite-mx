/*
    The panel clock shows seconds. plasmashell runs every .js under this
    directory once per user and records it in plasmashellrc; new and
    existing accounts alike.

    showSeconds: Never, ToolTip (the upstream default) or Always, the name
    the settings dialog writes, or 0, 1 or 2 as a script writes it. Only the
    default is changed, so a clock the user set to "never" keeps it.
*/

const containments = desktops().concat(panels());

containments.forEach(containment => {
    containment.widgets("org.kde.plasma.digitalclock").forEach(widget => {
        widget.currentConfigGroup = ["Appearance"];
        const current = String(widget.readConfig("showSeconds", "1")).toLowerCase();

        if (current === "1" || current === "tooltip") {
            widget.writeConfig("showSeconds", 2);
            widget.reloadConfig();
        }
    });
});
