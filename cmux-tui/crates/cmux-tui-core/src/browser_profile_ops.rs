//! The agent browser-profile verbs of `cmux.protocol/2` (cx-d0d.85,
//! plans/cmux-next/data-model.md section 5): `browser.profile.list`,
//! `browser.profile.create`, `browser.tab.open` and `browser.tab.set_profile`.
//!
//! Owner role: none of its own. Profile records stay the personal store's
//! (`browser-profiles-v1`); a tab's profile is its frontend browser record's
//! (`frontend-browser-tab-profile-v1`). The app that shows a tab follows the
//! record: it makes the page in that profile's store (cookies, local storage,
//! IndexedDB, cache) and loads the tab's URL there. Back/forward history stays
//! with the old store (a page's history never crosses profiles).
//!
//! There is no delete here: only a person deletes a browser profile
//! (`delete-browser-profile`, origin user).

use std::sync::Arc;

use serde_json::{Map, Value, json};

use crate::history_ops::ledger;
use crate::mux::FrontendTabPlacement;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;
use crate::workspace_registry::{
    BrowserProfileInput, DEFAULT_PROFILE_ID, FrontendBrowserRecord, PersonalBrowserProfile,
};
use crate::{Mux, ResourceTarget};

/// Advertised in identify: the daemon answers the four operations.
pub(crate) const CAPABILITY: &str = "browser-profile-agent-v1";

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::BrowserProfileList
            | ResourceOperation::BrowserProfileCreate
            | ResourceOperation::BrowserTabOpen
            | ResourceOperation::BrowserTabSetProfile
    )
}

/// Answers one request. A mutation runs once per idempotency key: a retry
/// answers the first result and creates or moves nothing again.
pub(crate) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    if matches!(
        request.envelope.operation,
        ResourceOperation::BrowserProfileList | ResourceOperation::BrowserProfileCreate
    ) {
        mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    }
    let operation = request.envelope.operation.wire_name();
    let fields = &request.fields;
    if request.envelope.operation == ResourceOperation::BrowserProfileList {
        return Ok(json!({"profiles": profiles(mux)?.iter().map(wire).collect::<Vec<_>>()}));
    }
    let key = request.envelope.idempotency_key.as_deref().ok_or_else(|| {
        ResourceError::validation_invalid(Some("idempotency_key"), "mutations need a key")
    })?;
    let mut fingerprint_fields = fields.clone();
    fingerprint_fields.insert("selectors".into(), json!(request.selectors));
    let fingerprint = ledger::fingerprint(operation, &fingerprint_fields);
    if ledger::seen(mux, key, operation)? {
        return ledger::commit(mux, key, operation, &fingerprint, &Value::Null, &request.actor);
    }
    let value = match request.envelope.operation {
        ResourceOperation::BrowserProfileCreate => create(mux, fields, key)?,
        ResourceOperation::BrowserTabOpen => open(mux, &request, key)?,
        _ => set_profile(mux, &request)?,
    };
    ledger::commit(mux, key, operation, &fingerprint, &value, &request.actor)
}

fn failed(operation: &str, error: anyhow::Error) -> ResourceError {
    match error.to_string().strip_prefix("bad request: ") {
        Some(reason) => ResourceError::validation_invalid(None, reason),
        None => ResourceError::operation_failed(operation, error.to_string(), json!({})),
    }
}

fn profiles(mux: &Mux) -> Result<Vec<PersonalBrowserProfile>, ResourceError> {
    mux.personal_snapshot()
        .map(|snapshot| snapshot.browser_profiles)
        .map_err(|error| failed("browser.profile.list", error))
}

fn wire(profile: &PersonalBrowserProfile) -> Value {
    json!({
        "id": profile.id,
        "name": profile.name,
        "color": profile.color,
        "icon": profile.icon,
        "index": profile.index,
    })
}

/// The profile `selector` names: its id, else its exact name, else the one
/// name that matches ignoring case.
fn resolve(mux: &Mux, selector: &str) -> Result<PersonalBrowserProfile, ResourceError> {
    let profiles = profiles(mux)?;
    // An id first, so a profile named like another one's id never takes it.
    if let Some(profile) = profiles.iter().find(|p| p.id == selector) {
        return Ok(profile.clone());
    }
    let exact: Vec<_> = profiles.iter().filter(|p| p.name == selector).collect();
    let folded: Vec<_> = if exact.is_empty() {
        profiles.iter().filter(|p| p.name.to_lowercase() == selector.to_lowercase()).collect()
    } else {
        exact
    };
    // validation.invalid on the `profile` field: the catalog's not_found and
    // ambiguous errors name resource scopes, and a profile is a personal record.
    match folded.as_slice() {
        [profile] => Ok((*profile).clone()),
        [] => Err(ResourceError::validation_invalid(
            Some("profile"),
            format!("no browser profile {selector:?}: `cmux browser profile list` lists them"),
        )),
        _ => Err(ResourceError::validation_invalid(
            Some("profile"),
            format!(
                "more than one browser profile is named {selector:?}: pass its id ({})",
                folded.iter().map(|p| p.id.as_str()).collect::<Vec<_>>().join(", ")
            ),
        )),
    }
}

fn text(fields: &Map<String, Value>, name: &str) -> Option<String> {
    fields.get(name).and_then(Value::as_str).map(str::to_string)
}

/// `browser.profile.create`: a new, empty profile (its own store).
fn create(mux: &Mux, fields: &Map<String, Value>, key: &str) -> Result<Value, ResourceError> {
    let input = BrowserProfileInput {
        // From the idempotency key: a retry after a crash, or a concurrent
        // retry, finds the profile the first attempt made instead of a second.
        id: Some(key_uuid(key)),
        name: text(fields, "name").unwrap_or_default(),
        color: text(fields, "color"),
        icon: text(fields, "icon"),
        ..Default::default()
    };
    let (profile, _) = mux
        .personal_mutation(|registry| registry.create_browser_profile(input))
        .map_err(|error| failed("browser.profile.create", error))?;
    Ok(json!({"profile": wire(&profile)}))
}

/// A lowercase version-4-shaped UUID derived from `key`.
fn key_uuid(key: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut bytes: Vec<u8> =
        Sha256::digest(format!("browser.profile.create\0{key}").as_bytes())[..16].to_vec();
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

/// `browser.tab.open`: a frontend-rendered browser tab in `profile` (absent:
/// `default`) on `engine` (absent: `webkit`). The app that shows the pane
/// makes the page in that profile's store.
fn open(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
    key: &str,
) -> Result<Value, ResourceError> {
    let fields = &request.fields;
    let profile = match text(fields, "profile") {
        Some(selector) => resolve(mux, &selector)?.id,
        None => DEFAULT_PROFILE_ID.to_string(),
    };
    let named_pane = request.selectors.pane.is_some()
        || request.selectors.screen.is_some()
        || request.selectors.workspace.is_some();
    if !named_pane {
        mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    }
    let pane = if named_pane {
        let path = mux.resolve_resource_path(ResourceTarget::Pane, &request.selectors)?;
        let public = path.pane.ok_or_else(|| ResourceError::not_found("pane", "pane"))?;
        Some(
            mux.with_state(|state| state.resource_indexes.panes.get(&public).copied())
                .ok_or_else(|| ResourceError::not_found("pane", public.as_str()))?,
        )
    } else {
        None
    };
    let record = FrontendBrowserRecord {
        engine: text(fields, "engine").unwrap_or_else(|| "webkit".into()),
        url: text(fields, "url").unwrap_or_default(),
        title: None,
        favicon_url: None,
        profile_id: Some(profile.clone()),
        owner: None,
    };
    let actor = request.actor.clone();
    let outcome = mux
        .new_frontend_browser_tab_keyed_as(
            &actor,
            pane,
            record,
            None,
            key,
            FrontendTabPlacement::default(),
        )
        .map_err(|error| failed("browser.tab.open", error))?;
    let tab = outcome.surface.resource_identity().map(|identity| identity.tab_id.to_string());
    Ok(json!({"tab_id": tab, "profile_id": profile}))
}

/// `browser.tab.set_profile`: the tab keeps its id and place; its record
/// names `profile`, and the app re-makes the page there and reloads its URL.
fn set_profile(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let selector = text(&request.fields, "profile").unwrap_or_default();
    let profile = resolve(mux, &selector)?;
    let path = mux.resolve_resource_path(ResourceTarget::Tab, &request.selectors)?;
    let tab = path.tab.ok_or_else(|| ResourceError::not_found("tab", "tab"))?;
    let surface = mux
        .with_state(|state| state.surface_by_tab_public_id(&tab).map(|surface| surface.id))
        .ok_or_else(|| ResourceError::not_found("tab", tab.as_str()))?;
    let (_, changed) = mux
        .set_frontend_browser_tab_profile(surface, &profile.id)
        .map_err(|error| failed("browser.tab.set_profile", error))?;
    Ok(json!({"tab_id": tab.as_str(), "profile_id": profile.id, "changed": changed}))
}
