//! Agent browser profiles (`browser-profile-agent-v1`, cx-d0d.85) through the
//! curated CLI and a real daemon: an agent lists and creates browser
//! profiles, opens a tab in one, and moves a tab to another. The tab keeps
//! its id and shows its profile as `extra.browser_profile_id`; the app that
//! shows the tab only follows that record. Agents cannot delete a profile.
#![cfg(unix)]

use super::*;

fn cmux(server: &HeadlessServer, args: &[&str]) -> Output {
    Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap()
}

fn ok(server: &HeadlessServer, args: &[&str]) -> serde_json::Value {
    let output = cmux(server, args);
    assert_success(&output);
    json_output(&output)
}

fn refused(server: &HeadlessServer, args: &[&str]) -> String {
    let output = cmux(server, args);
    assert!(!output.status.success(), "{args:?}: {}", String::from_utf8_lossy(&output.stdout));
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// The first object under `value` that has `key` (results nest a snapshot).
fn find<'a>(value: &'a serde_json::Value, key: &str) -> Option<&'a serde_json::Value> {
    match value {
        serde_json::Value::Object(map) => {
            map.get(key).or_else(|| map.values().find_map(|child| find(child, key)))
        }
        serde_json::Value::Array(items) => items.iter().find_map(|child| find(child, key)),
        _ => None,
    }
}

fn text(value: Option<&serde_json::Value>) -> String {
    value.and_then(|value| value.as_str()).unwrap_or_default().to_string()
}

fn profile_of(server: &HeadlessServer, tab: &str) -> String {
    text(find(&ok(server, &["tab", tab, "show"]), "browser_profile_id"))
}

#[test]
fn agents_create_profiles_open_tabs_in_them_and_move_tabs_through_a_real_daemon() {
    let server = HeadlessServer::start("browser-profiles");
    let identity = raw_json(&server, serde_json::json!({"id": "who", "cmd": "identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == "browser-profile-agent-v1"),
        "{identity}"
    );

    // The list starts with the default profile; create returns the new id.
    let listed = ok(&server, &["browser", "profile", "list"]);
    assert_eq!(find(&listed, "profiles").unwrap()[0]["id"], "default", "{listed}");
    let work = text(find(&ok(&server, &["browser", "profile", "create", "--name", "Work"]), "id"));
    let client =
        text(find(&ok(&server, &["browser", "profile", "create", "--name", "Client"]), "id"));
    assert!(work.len() == 36 && client.len() == 36 && work != client, "{work} {client}");
    let names: Vec<String> = find(&ok(&server, &["browser", "profile", "list"]), "profiles")
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|p| text(p.get("name")))
        .collect();
    assert_eq!(names, ["Default", "Work", "Client"]);

    // A tab opened straight in a profile (by name, any case) reports it.
    let opened = ok(
        &server,
        &["browser", "tab", "open", "--url", "https://example.com/", "--profile", "work"],
    );
    let tab = text(find(&opened, "tab_id"));
    assert!(tab.starts_with("tab_"), "{opened}");
    assert_eq!(text(find(&opened, "profile_id")), work);
    assert_eq!(profile_of(&server, &tab), work);

    // Move it by profile id: same tab id, the record names the new profile.
    let moved = ok(&server, &["browser", "tab", &tab, "set-profile", "--profile", &client]);
    assert_eq!(text(find(&moved, "tab_id")), tab, "{moved}");
    assert_eq!(find(&moved, "changed").and_then(|v| v.as_bool()), Some(true), "{moved}");
    assert_eq!(profile_of(&server, &tab), client);
    // Back by name; the same profile again changes nothing.
    ok(&server, &["browser", "tab", &tab, "set-profile", "--profile", "Work"]);
    assert_eq!(profile_of(&server, &tab), work);
    let again = ok(&server, &["browser", "tab", &tab, "set-profile", "--profile", "Work"]);
    assert_eq!(find(&again, "changed").and_then(|v| v.as_bool()), Some(false), "{again}");

    // A tab with no profile is in default; unknown profiles and non-browser tabs are refused.
    let plain = text(find(
        &ok(&server, &["browser", "tab", "open", "--url", "https://example.org/"]),
        "tab_id",
    ));
    assert_eq!(profile_of(&server, &plain), "default");
    let error = refused(&server, &["browser", "tab", &tab, "set-profile", "--profile", "Nope"]);
    assert!(error.contains("Nope"), "{error}");
    ok(&server, &["tab", "create", "terminal"]);
    let tabs = ok(&server, &["tab", "list"]);
    let terminal = find(&tabs, "items")
        .or(Some(&tabs))
        .and_then(|items| items.as_array())
        .and_then(|items| items.iter().find(|tab| tab["content_kind"] == "terminal"))
        .and_then(|tab| tab["id"].as_str())
        .unwrap_or_else(|| panic!("no terminal tab in {tabs}"))
        .to_string();
    refused(&server, &["browser", "tab", &terminal, "set-profile", "--profile", "Work"]);

    // No agent verb deletes a profile (only a person does).
    refused(&server, &["browser", "profile", "delete", "--profile", "Work"]);
    assert_eq!(
        find(&ok(&server, &["browser", "profile", "list"]), "profiles").unwrap()[1]["id"],
        work
    );
}
