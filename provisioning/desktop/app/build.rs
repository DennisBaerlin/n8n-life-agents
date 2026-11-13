// App-Befehle brauchen eine ausdrückliche Erlaubnis (App-Manifest). Nur das App-Fenster bekommt sie
// (capabilities/default.json, ohne `remote`); die Fragebogen-Seite im selben Fenster ist eine fremde Adresse und darf keinen Befehl rufen.
// Neuer Befehl in src/commands.rs → hier eintragen und in capabilities/default.json als allow-<name> freigeben.
const COMMANDS: &[&str] = &[
    "startup",
    "trash_download",
    "check_system",
    "check_docker",
    "fetch_docker",
    "start_docker",
    "wait_docker",
    "start_core",
    "open_wizard",
    "wizard_status",
    "save_backup_kit",
    "kit_status",
    "confirm_kit",
    "change_backup_folder",
    "restore_list",
    "restore_dismiss_card",
    "restore_select",
    "restore_pick_file",
    "restore_pick_sheet",
    "restore_type_sheet",
    "restore_forget",
    "restore_plan",
    "restore_run",
    "restore_status",
    "restore_seen",
    "power_info",
    "power_apply",
    "power_answer",
    "power_restore",
    "finish_setup",
    "rollback",
    "uninstall_plan",
    "uninstall_run",
    "error_report",
    "open_link",
];

fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(COMMANDS)))
        .expect("tauri-build scheiterte");
}
