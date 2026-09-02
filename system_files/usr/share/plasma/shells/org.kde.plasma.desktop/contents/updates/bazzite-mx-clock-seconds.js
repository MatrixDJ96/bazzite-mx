/*
    The panel clock shows seconds. plasmashell runs every .js under this
    directory once per user, in file-name order, and records it in
    plasmashellrc; new and existing accounts alike.

    showSeconds: 0 never, 1 tooltip only (the upstream default), 2 always.
    Only the default is changed, so a clock the user set to "never" keeps it.
*/

const containments = desktops().concat(panels());

containments.forEach(containment => containment.widgets("org.kde.plasma.digitalclock").forEach(widget => {
    widget.currentConfigGroup = ["Appearance"];
    if (widget.readConfig("showSeconds", 1) == 1) {
        widget.writeConfig("showSeconds", 2);
        widget.reloadConfig();
    }
}));
