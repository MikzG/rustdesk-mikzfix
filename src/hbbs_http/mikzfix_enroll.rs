//! mikzfix: unattended access for MikzFix (enrolment protocol v1, sections 7 and 9).
//!
//! Runs only in the server process of an INSTALLED desktop app, never on Android or iOS.
//! Nothing touches the network unless the user said "Allow" (`mikzfix-unattended == "Y"`)
//! or a previous enrolment has to be revoked. The pure protocol pieces (message, signature,
//! sealed box, fp, response parsing) live in `hbb_common::mikzfix_enroll` and are unit tested
//! there against the protocol's test vector.

use hbb_common::{
    config::{self, keys, Config},
    log,
    mikzfix_enroll as pe,
    tokio::{self, time::sleep},
};
use std::{
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

/// Local check of the switch (no network).
const LOCAL_POLL: Duration = Duration::from_secs(5);
/// Full cycle (section 9): at start and then every 10 minutes.
const CYCLE: Duration = Duration::from_secs(600);
/// hbbs has not confirmed our key yet: wait, it is not a failure.
const KEY_WAIT: Duration = Duration::from_secs(60);
const DAY: i64 = 86_400;
/// Network error: up to 3 quick retries on the same occasion (section 7).
const NET_RETRIES: [u64; 3] = [30, 120, 600];

static STARTED: AtomicBool = AtomicBool::new(false);

pub fn start() {
    if !crate::is_server() || !crate::platform::is_installed() {
        return;
    }
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(run);
}

#[tokio::main(flavor = "current_thread")]
async fn run() {
    Enroller::default().run().await;
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn opt(k: &str) -> String {
    Config::get_option(k)
}

fn set_opt(k: &str, v: &str) {
    Config::set_option(k.to_owned(), v.to_owned());
}

fn unattended() -> String {
    opt(keys::OPTION_MIKZFIX_UNATTENDED)
}

#[derive(Debug, PartialEq)]
enum Outcome {
    Ok { rotate: bool },
    Fail,
    BadRequest,
    /// The user flipped the switch while we were waiting; drop this attempt silently.
    Aborted,
}

#[derive(Default)]
struct Enroller {
    /// The first cycle after the service start has run (enrol even if fp is unchanged).
    first_done: bool,
    /// The fp of the last failed enrol, so a failure is only retried after 24 h.
    last_failed_fp: Option<String>,
    /// `bad_request` for this fp: no retry until a new start, version or fp.
    bad_request_fp: Option<String>,
    /// `rate_limited`: not before this Unix time.
    not_before: i64,
    last_rotate: Option<Instant>,
    /// The first revoke-pending attempt after start is not gated by the 24 h rule.
    revoke_tried: bool,
    /// Windows "Start at login" value last applied to the Startup shortcut.
    #[allow(dead_code)]
    autostart_applied: Option<bool>,
    /// Failed attempts for the current value; retried on later cycles up to a limit.
    #[allow(dead_code)]
    autostart_failures: u8,
}

/// mikzfix: "Start at login" (`""`/`"Y"` = on, the default; `"N"` = off). Set by the UI
/// (Settings > General, also without login). On Windows the service keeps the all-users
/// Startup shortcut of the tray in step with it; on macOS the UI writes a per-user LaunchAgent.
pub const OPTION_START_AT_LOGIN: &str = "mikzfix-start-at-login";

impl Enroller {
    #[cfg(windows)]
    fn sync_autostart(&mut self) {
        let want = opt(OPTION_START_AT_LOGIN) != "N";
        if self.autostart_applied == Some(want) {
            return;
        }
        match crate::platform::windows::mikzfix_sync_tray_autostart(want) {
            Ok(()) => {
                log::info!("mikzfix start-at-login={}", want);
                self.autostart_applied = Some(want);
                self.autostart_failures = 0;
            }
            Err(e) => {
                // Retried on the next cycles; after 3 failures, only when the value changes or
                // the service restarts.
                self.autostart_failures += 1;
                log::warn!(
                    "mikzfix start-at-login={} failed ({}): {}",
                    want,
                    self.autostart_failures,
                    e
                );
                if self.autostart_failures >= 3 {
                    self.autostart_applied = Some(want);
                    self.autostart_failures = 0;
                }
            }
        }
    }

    async fn run(mut self) {
        // Let the rendezvous mediator register the key first.
        sleep(Duration::from_secs(10)).await;
        let mut last_seen = unattended();
        let mut next = Instant::now();
        loop {
            #[cfg(windows)]
            self.sync_autostart();
            let cur = unattended();
            if cur != last_seen {
                if last_seen == "Y" && cur != "Y" {
                    self.turn_off().await;
                }
                last_seen = cur;
                next = Instant::now();
            }
            if Instant::now() >= next {
                let wait = self.cycle().await;
                next = Instant::now() + wait;
            }
            sleep(LOCAL_POLL).await;
        }
    }

    /// Section 9, the cycle. Returns how long to wait before the next one.
    async fn cycle(&mut self) -> Duration {
        if config::option2bool("stop-service", &opt("stop-service")) {
            return CYCLE;
        }
        // 1. A revoke that has not reached the server yet.
        if opt(keys::OPTION_MIKZFIX_REVOKE_PENDING) == "Y" && self.retry_allowed() {
            self.revoke_tried = true;
            match self.send(pe::OP_REVOKE, None, false).await {
                Outcome::Ok { .. } => {
                    set_opt(keys::OPTION_MIKZFIX_REVOKE_PENDING, "");
                    set_opt(keys::OPTION_MIKZFIX_ENROLL_LAST_FAIL, "");
                }
                Outcome::Aborted => {}
                _ => set_opt(keys::OPTION_MIKZFIX_ENROLL_LAST_FAIL, &now().to_string()),
            }
        }
        // 2. Only with consent.
        if unattended() != "Y" {
            if !opt(keys::OPTION_MIKZFIX_ENROLL_FP).is_empty() {
                // Enrolled before but the switch is off (e.g. changed while stopped).
                self.turn_off().await;
            }
            return CYCLE;
        }
        if !Config::get_key_confirmed() {
            return KEY_WAIT;
        }
        // 3. Make sure the permanent password exists; compute h1 and fp.
        let Some(h1) = ensure_password() else {
            log::error!("mikzfix-enroll op=enroll error=no_password");
            return CYCLE;
        };
        let id = Config::get_id();
        let fp = pe::fingerprint(&id, &h1);
        // 4. When to enrol.
        let t = now();
        let stored = opt(keys::OPTION_MIKZFIX_ENROLL_FP);
        let blocked = self.bad_request_fp.as_deref() == Some(fp.as_str());
        let last_fail = opt(keys::OPTION_MIKZFIX_ENROLL_LAST_FAIL).parse::<i64>().ok();
        let due_start = !self.first_done;
        let due_change =
            fp != stored && self.last_failed_fp.as_deref() != Some(fp.as_str()) && !blocked;
        let due_retry = last_fail.map_or(false, |x| t - x >= DAY) && !blocked && t >= self.not_before;
        if !(due_start || due_change || due_retry) {
            return CYCLE;
        }
        self.first_done = true;
        match self.send(pe::OP_ENROLL, Some(&h1), true).await {
            Outcome::Ok { rotate } => {
                set_opt(keys::OPTION_MIKZFIX_ENROLL_FP, &fp);
                set_opt(keys::OPTION_MIKZFIX_ENROLL_LAST_FAIL, "");
                self.last_failed_fp = None;
                self.bad_request_fp = None;
                if rotate
                    && self
                        .last_rotate
                        .map_or(true, |x| x.elapsed() >= Duration::from_secs(DAY as u64))
                {
                    // A new password changes fp, so the next cycle (now) enrols it.
                    self.last_rotate = Some(Instant::now());
                    if Config::set_permanent_password(&Config::get_auto_password(32)) {
                        return Duration::ZERO;
                    }
                    log::error!("mikzfix-enroll op=rotate error=set_password_failed");
                }
            }
            Outcome::Aborted => return Duration::ZERO,
            Outcome::BadRequest => {
                self.bad_request_fp = Some(fp.clone());
                self.fail(&fp);
            }
            Outcome::Fail => self.fail(&fp),
        }
        CYCLE
    }

    fn retry_allowed(&self) -> bool {
        if !self.revoke_tried {
            return true;
        }
        let last_fail = opt(keys::OPTION_MIKZFIX_ENROLL_LAST_FAIL).parse::<i64>().ok();
        last_fail.map_or(true, |x| now() - x >= DAY) && now() >= self.not_before
    }

    fn fail(&mut self, fp: &str) {
        set_opt(keys::OPTION_MIKZFIX_ENROLL_LAST_FAIL, &now().to_string());
        self.last_failed_fp = Some(fp.to_owned());
    }

    /// Section 9, revoke. The permanent password is deleted FIRST, whatever happens to the
    /// request, so the old hash is useless even if the revoke never arrives.
    async fn turn_off(&mut self) {
        if !Config::set_permanent_password("") {
            log::error!("mikzfix-enroll op=revoke error=clear_password_failed");
        }
        set_opt(keys::OPTION_MIKZFIX_ENROLL_FP, "");
        set_opt(keys::OPTION_MIKZFIX_REVOKE_PENDING, "Y");
        self.last_failed_fp = None;
        self.bad_request_fp = None;
        self.revoke_tried = true;
        match self.send(pe::OP_REVOKE, None, false).await {
            Outcome::Ok { .. } => {
                set_opt(keys::OPTION_MIKZFIX_REVOKE_PENDING, "");
                set_opt(keys::OPTION_MIKZFIX_ENROLL_LAST_FAIL, "");
            }
            // Turned back on while waiting: the pending revoke goes out in the next cycle,
            // before the new enrol.
            Outcome::Aborted => {}
            _ => set_opt(keys::OPTION_MIKZFIX_ENROLL_LAST_FAIL, &now().to_string()),
        }
    }

    /// One request with the retry rules of section 7. `want_on` is the switch position this
    /// request belongs to: if it changes while waiting, the attempt is aborted.
    async fn send(&mut self, op: &str, h1: Option<&[u8; 32]>, want_on: bool) -> Outcome {
        let url = format!("{}/{}", config::MIKZFIX_ENROLL_URL, op);
        let mut net_tries = 0;
        let mut one_retry_used = false;
        let mut ts_override: Option<i64> = None;
        loop {
            let ts = ts_override.take().unwrap_or_else(now);
            let body = match build_body(op, h1, ts) {
                Ok(b) => b,
                Err(e) => {
                    log::error!("mikzfix-enroll op={} error=build_failed {}", op, e);
                    return Outcome::Fail;
                }
            };
            let res = crate::post_request(url.clone(), body, "").await;
            let received = now();
            let parsed = match res {
                Ok(b) => pe::parse_response(&b),
                Err(_) => pe::EnrollResponse::Network,
            };
            match parsed {
                pe::EnrollResponse::Ok { status, rotate, .. } => {
                    log::info!("mikzfix-enroll op={} status={}", op, status);
                    return Outcome::Ok { rotate };
                }
                pe::EnrollResponse::Network => {
                    log::warn!("mikzfix-enroll op={} error=network", op);
                    if net_tries < NET_RETRIES.len() {
                        let wait = Duration::from_secs(NET_RETRIES[net_tries]);
                        net_tries += 1;
                        if !wait_while(wait, want_on).await {
                            return Outcome::Aborted;
                        }
                        continue;
                    }
                    return Outcome::Fail;
                }
                pe::EnrollResponse::Err {
                    error,
                    server_time,
                    retry_after,
                } => {
                    log::warn!("mikzfix-enroll op={} error={}", op, error);
                    match error.as_str() {
                        "ts_out_of_window" if !one_retry_used => {
                            one_retry_used = true;
                            ts_override = Some(server_time + (now() - received));
                        }
                        "replay" if !one_retry_used => {
                            one_retry_used = true;
                        }
                        "stale" if !one_retry_used => {
                            one_retry_used = true;
                            sleep(Duration::from_secs(1)).await;
                            ts_override = Some(now().max(server_time));
                        }
                        "bad_request" => return Outcome::BadRequest,
                        "rate_limited" => {
                            self.not_before = now() + retry_after.max(0);
                            return Outcome::Fail;
                        }
                        _ => return Outcome::Fail,
                    }
                }
            }
        }
    }
}

/// Sleeps `dur`, checking the switch; returns false as soon as it leaves `want_on`.
async fn wait_while(dur: Duration, want_on: bool) -> bool {
    let end = Instant::now() + dur;
    while Instant::now() < end {
        if (unattended() == "Y") != want_on {
            return false;
        }
        sleep(LOCAL_POLL.min(end.saturating_duration_since(Instant::now()))).await;
    }
    (unattended() == "Y") == want_on
}

/// h1 of the local permanent password; generates a random one when there is none.
/// Only called after consent, in the process that owns the config (section 5).
fn ensure_password() -> Option<[u8; 32]> {
    if let Some(h1) = Config::get_local_permanent_password_h1() {
        return Some(h1);
    }
    // The plain text is dropped right after; only h1 is ever read back.
    if !Config::set_permanent_password(&Config::get_auto_password(32)) {
        return None;
    }
    Config::get_local_permanent_password_h1()
}

fn device_fields() -> (String, String) {
    let sysinfo = crate::get_sysinfo();
    let preset = Config::get_option(keys::OPTION_PRESET_DEVICE_NAME);
    let hostname = if preset.is_empty() {
        sysinfo["hostname"].as_str().unwrap_or_default().to_owned()
    } else {
        preset
    };
    let os = sysinfo["os"].as_str().unwrap_or_default().to_owned();
    (hostname, os)
}

fn build_body(op: &str, h1: Option<&[u8; 32]>, ts: i64) -> hbb_common::ResultType<String> {
    let sealed = match (op, h1) {
        (pe::OP_ENROLL, Some(h1)) => pe::seal_h1(h1, config::MIKZFIX_ENROLL_PK)?,
        (pe::OP_ENROLL, None) => hbb_common::bail!("enroll without h1"),
        _ => Vec::new(),
    };
    let (sk, _pk) = Config::get_key_pair();
    let id = Config::get_id();
    let uuid = hbb_common::get_uuid();
    let nonce = pe::random_nonce();
    let (hostname, os) = device_fields();
    let req = pe::build_request(
        &pe::RequestInput {
            op,
            id: &id,
            uuid: &uuid,
            ts,
            nonce: &nonce,
            sealed: &sealed,
            hostname: &hostname,
            os: &os,
            ver: crate::VERSION,
        },
        &sk,
    )?;
    Ok(serde_json::to_string(&req)?)
}
