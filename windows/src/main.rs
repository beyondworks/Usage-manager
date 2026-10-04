// No console window for the tray app, nor for the hook modes Claude Code runs on every
// tool call. A hook's stdin and stdout are pipes Claude Code hands over, which a
// windowless process reads and writes all the same.
#![cfg_attr(windows, windows_subsystem = "windows")]

mod app;
mod codex;
mod desktop;
mod gate;
mod hooks;
mod models;
mod paths;
mod quota;
mod scanner;
#[cfg(test)]
mod testing;
mod timeutil;
mod transcript;

use app::{App, Settings, QUOTA_INTERVAL};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, WindowEvent};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_notification::NotificationExt;

const WIDTH: f64 = 360.0;

fn exe() -> PathBuf {
    std::env::current_exe().unwrap_or_else(|_| PathBuf::from("UsageManager.exe"))
}

/// A windowless program started from a terminal has no console of its own; borrow the
/// terminal's so `--dump` prints where it was typed. Pipes (Claude Code, Git Bash) are
/// already in place and are left alone.
#[cfg(windows)]
fn attach_console() {
    use windows_sys::Win32::System::Console::{AttachConsole, GetStdHandle, ATTACH_PARENT_PROCESS, STD_OUTPUT_HANDLE};
    unsafe {
        let h = GetStdHandle(STD_OUTPUT_HANDLE);
        if h.is_null() || h as isize == -1 {
            AttachConsole(ATTACH_PARENT_PROCESS);
        }
    }
}
#[cfg(not(windows))]
fn attach_console() {}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let has = |f: &str| args.iter().any(|a| a == f);
    if has("--gate") {
        // PreCompact(auto): exit 2 holds the compaction, and the text goes to the user.
        if let gate::Decision::Hold(_) = gate::decide(&hooks::read_stdin()) {
            eprintln!("Usage Manager: 핸드오버가 저장될 때까지 압축을 미룹니다. 저장을 마친 뒤 마커를 touch 하면 압축이 이어집니다.");
            std::process::exit(2);
        }
        return;
    }
    if has("--prompt-hook") {
        if let Some(out) = hooks::prompt_hook(&hooks::read_stdin()) {
            println!("{out}");
        }
        return;
    }
    if has("--status-line") {
        print!("{}", hooks::status_line(&hooks::read_stdin()));
        return;
    }
    if let Some(i) = args.iter().position(|a| a == "--hooks") {
        attach_console();
        let r = if args.get(i + 1).map(String::as_str) == Some("on") {
            hooks::install(&exe(), Some(Settings::load().ctx_threshold))
        } else {
            hooks::uninstall()
        };
        if let Err(e) = r {
            println!("error: {e}");
            std::process::exit(1);
        }
        println!("hooks: claude: {}", hooks::status(&exe()).claude);
        return;
    }
    if has("--dump") {
        attach_console();
        dump();
        return;
    }
    run(has("--demo"));
}

/// What the app reads, as text: the limits, and each session with every figure the
/// judgements use. The self-check reads this.
fn dump() {
    let mut scanner = scanner::Scanner::new(paths::home());
    let snap = scanner.scan(&[]);
    let settings = Settings::load();
    let limit = std::env::var("USAGE_MANAGER_COMPACT_LIMIT").ok().and_then(|v| v.parse().ok()).unwrap_or(settings.compact_limit);
    let mut a = App::new(Settings { compact_limit: limit, ..settings });
    a.tools = snap.tools.clone();
    let sessions = snap.sessions.clone();
    a.apply_scan(scanner::Snapshot { tools: snap.tools, limits: snap.limits, sessions: vec![] });
    let mut live = quota::fetch_proxy();
    live.extend(quota::fetch_claude());
    a.apply_live(live);
    println!("tools: {:?}", a.tools.iter().map(|t| t.display()).collect::<Vec<_>>());
    println!("claude fetch: {}", quota::diagnosis());
    let now = timeutil::now_secs();
    for q in &a.quotas {
        let f = |v: Option<f64>| v.map(|v| format!("{}", v as i64)).unwrap_or_else(|| "-".into());
        println!(
            "quota {} [{}]: weekly={}% 5h={}% resets={} age={}",
            models::provider_name(&q.provider),
            q.provider,
            f(q.weekly),
            f(q.five_hour),
            q.resets_at.map(|r| (r as i64).to_string()).unwrap_or_else(|| "-".into()),
            timeutil::age_text(q.updated_at, now)
        );
    }
    println!("compactLimit: {limit}");
    let (until, _) = quota::backoff();
    let wait = (until - now).max(0.0) as i64;
    println!("claude-backoff: {}", if wait > 0 { format!("{wait}s remaining") } else { "none".into() });
    for s in &sessions {
        let compact_at = match s.measured_compaction_point() {
            Some(m) => format!("{m} measured"),
            None => format!("{} from the setting", s.compaction_tokens(settings.ctx_threshold)),
        };
        println!(
            "session[{}] {} {} {}% {}/{} {} title_from={} compactions={} post={} last_ctx={} compact_at={} handover={} clear={} idle={}",
            s.short_id(),
            s.tool.display(),
            s.label(),
            s.used_percent() as i64,
            s.ctx_tokens,
            s.window_size,
            s.model,
            s.title_source,
            s.compactions,
            s.last_post_tokens,
            s.ctx_tokens,
            compact_at,
            s.handover_saved.map(|b| b.to_string()).unwrap_or_else(|| "unknown".into()),
            s.needs_clear(limit),
            s.is_idle(now)
        );
    }
    println!("hooks: claude: {}", hooks::status(&exe()).claude);
}

// ---- The tray app ----------------------------------------------------------------------

struct Shared {
    app: Arc<Mutex<App>>,
    quota_now: Sender<()>,
    /// Where the tray icon sits, so the popover opens above it and stays anchored there
    /// as its height follows the content.
    anchor: Mutex<Option<(f64, f64)>>,
    hidden_at: Mutex<f64>,
}

fn publish(handle: &AppHandle) {
    let shared = handle.state::<Shared>();
    let view = shared.app.lock().unwrap().view();
    let _ = handle.emit("state", view);
}

fn notify(handle: &AppHandle, pushes: Vec<app::Notice>) {
    for (title, body, id) in pushes {
        eprintln!("[notify] {title} — {body} [{id}]");
        // The self-check drives fake sessions; it must not put banners on a real screen.
        if paths::offline() {
            continue;
        }
        let _ = handle.notification().builder().title(title).body(body).show();
    }
}

#[tauri::command]
fn state(shared: tauri::State<Shared>) -> serde_json::Value {
    shared.app.lock().unwrap().view()
}

#[tauri::command]
fn set_threshold(handle: AppHandle, shared: tauri::State<Shared>, value: i64) {
    let pushes = {
        let mut a = shared.app.lock().unwrap();
        a.settings.ctx_threshold = value.clamp(50, 95);
        a.settings.save();
        // The threshold is also the auto-compaction point; keep the two in step.
        if a.hooks_on {
            let _ = hooks::install(&exe(), Some(a.settings.ctx_threshold));
        }
        a.evaluate_alerts()
    };
    notify(&handle, pushes);
    publish(&handle);
}

#[tauri::command]
fn set_alerts(handle: AppHandle, shared: tauri::State<Shared>, on: bool) {
    {
        let mut a = shared.app.lock().unwrap();
        a.settings.alerts_on = on;
        a.settings.save();
        hooks::set_gate_enabled(on);
    }
    publish(&handle);
}

#[tauri::command]
fn set_hooks(handle: AppHandle, shared: tauri::State<Shared>, on: bool) {
    {
        let mut a = shared.app.lock().unwrap();
        let r = if on { hooks::install(&exe(), Some(a.settings.ctx_threshold)) } else { hooks::uninstall() };
        a.hook_error = r.err();
        a.hooks_on = hooks::status(&exe()).claude;
    }
    publish(&handle);
}

#[tauri::command]
fn set_launch(handle: AppHandle, shared: tauri::State<Shared>, on: bool) {
    let al = handle.autolaunch();
    let _ = if on { al.enable() } else { al.disable() };
    shared.app.lock().unwrap().launch_at_login = al.is_enabled().unwrap_or(false);
    publish(&handle);
}

/// A lookup asked for by hand, at most once a minute. A provider already rate-limited
/// is skipped by its own back-off, so this never extends a limit in force.
#[tauri::command]
fn refresh_now(handle: AppHandle, shared: tauri::State<Shared>) {
    {
        let mut a = shared.app.lock().unwrap();
        if !a.manual_ready() {
            return;
        }
        a.last_manual_fetch = timeutil::now_secs();
    }
    let _ = shared.quota_now.send(());
    publish(&handle);
}

#[tauri::command]
fn hide(handle: AppHandle, shared: tauri::State<Shared>) {
    if let Some(w) = handle.get_webview_window("main") {
        let _ = w.hide();
        *shared.hidden_at.lock().unwrap() = timeutil::now_secs();
    }
}

#[tauri::command]
fn quit(handle: AppHandle) {
    handle.exit(0);
}

/// The page reports its own height; the window follows it, bottom edge kept above the
/// tray so it grows upward the way a taskbar flyout does.
#[tauri::command]
fn fit(handle: AppHandle, shared: tauri::State<Shared>, height: f64) {
    let Some(w) = handle.get_webview_window("main") else { return };
    let _ = w.set_size(LogicalSize::new(WIDTH, height.clamp(120.0, 900.0)));
    place(&handle, &shared);
}

fn place(handle: &AppHandle, shared: &Shared) {
    let Some(w) = handle.get_webview_window("main") else { return };
    let Some((ax, ay)) = *shared.anchor.lock().unwrap() else { return };
    let Ok(size) = w.outer_size() else { return };
    let monitor = handle.monitor_from_point(ax, ay).ok().flatten().or_else(|| w.current_monitor().ok().flatten());
    let Some(m) = monitor else { return };
    let area = m.work_area();
    let (left, top) = (area.position.x as f64, area.position.y as f64);
    let (right, bottom) = (left + area.size.width as f64, top + area.size.height as f64);
    let gap = 12.0 * m.scale_factor();
    let (ww, wh) = (size.width as f64, size.height as f64);
    let x = (ax - ww / 2.0).clamp(left + gap, right - ww - gap);
    // Taskbar at the bottom (usual) → open above the icon; at the top → below it.
    let y = if ay > top + area.size.height as f64 / 2.0 { bottom - wh - gap } else { top + gap };
    let _ = w.set_position(PhysicalPosition::new(x, y));
}

fn toggle(handle: &AppHandle) {
    let Some(w) = handle.get_webview_window("main") else { return };
    let shared = handle.state::<Shared>();
    // A click on the icon first takes focus from an open popover, which hides it; the
    // click itself must not then open it again.
    if timeutil::now_secs() - *shared.hidden_at.lock().unwrap() < 0.25 {
        return;
    }
    if std::env::var("USAGE_MANAGER_DEBUG").is_ok() {
        paths::append_log("window.log", &format!("toggle visible={:?} anchor={:?}", w.is_visible(), *shared.anchor.lock().unwrap()));
    }
    if w.is_visible().unwrap_or(false) {
        let _ = w.hide();
    } else {
        place(handle, &shared);
        let _ = w.show();
        let _ = w.set_focus();
        publish(handle);
    }
}

/// Windows 11 outlines a borderless window in a light line; on this dark panel it reads
/// as a frame, so the line takes the panel's own tone.
#[cfg(windows)]
fn dark_border(w: &tauri::WebviewWindow) {
    use windows_sys::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_BORDER_COLOR};
    if let Ok(hwnd) = w.hwnd() {
        let color: u32 = 0x002A2A2A; // COLORREF 0x00BBGGRR
        unsafe { DwmSetWindowAttribute(hwnd.0 as _, DWMWA_BORDER_COLOR as u32, &color as *const u32 as *const _, 4) };
    }
}
#[cfg(not(windows))]
fn dark_border(_: &tauri::WebviewWindow) {}

/// Windows tints nothing in the tray, so the mark is drawn for the taskbar it sits on.
fn tray_icon() -> tauri::image::Image<'static> {
    let light = taskbar_is_light();
    let bytes: &'static [u8] = if light { include_bytes!("../icons/tray-light.png") } else { include_bytes!("../icons/tray-dark.png") };
    tauri::image::Image::from_bytes(bytes).expect("tray icon")
}

#[cfg(windows)]
fn taskbar_is_light() -> bool {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    let key: Vec<u16> = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize\0".encode_utf16().collect();
    let name: Vec<u16> = "SystemUsesLightTheme\0".encode_utf16().collect();
    let mut value: u32 = 0;
    let mut len: u32 = 4;
    let r = unsafe { RegGetValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr(), RRF_RT_REG_DWORD, std::ptr::null_mut(), &mut value as *mut u32 as *mut _, &mut len) };
    r == 0 && value == 1
}
#[cfg(not(windows))]
fn taskbar_is_light() -> bool {
    false
}

/// File changes, batched for a second, then one scan; a minute's timer catches idle
/// transitions and the periodic full scan.
fn scan_loop(handle: AppHandle, rx: Receiver<Vec<PathBuf>>, mut scanner: scanner::Scanner) {
    let mut minute = 0.0;
    loop {
        let mut changed: Vec<PathBuf> = Vec::new();
        match rx.recv_timeout(Duration::from_secs(60)) {
            Ok(p) => {
                changed.extend(p);
                std::thread::sleep(Duration::from_secs(1));
                while let Ok(p) = rx.try_recv() {
                    changed.extend(p);
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
        changed.sort();
        changed.dedup();
        let snap = scanner.scan(&changed);
        let pushes = {
            let shared = handle.state::<Shared>();
            let mut a = shared.app.lock().unwrap();
            if timeutil::now_secs() - minute > 60.0 {
                a.hooks_on = hooks::status(&exe()).claude;
                minute = timeutil::now_secs();
            }
            a.apply_scan(snap)
        };
        notify(&handle, pushes);
        publish(&handle);
    }
}

/// Limits move slowly and the usage endpoint rate-limits callers that ask too often:
/// once every five minutes, or when asked by hand.
fn quota_loop(handle: AppHandle, rx: Receiver<()>) {
    loop {
        let mut live = quota::fetch_proxy();
        live.extend(quota::fetch_claude());
        let names: Vec<String> = live.iter().map(|q| format!("{} {}%", q.provider, q.weekly.map(|w| w as i64).unwrap_or(-1))).collect();
        paths::append_log(
            "usage.log",
            &format!("quota fetch — {} · claude: {}", if names.is_empty() { "none".into() } else { names.join(" ") }, quota::diagnosis()),
        );
        {
            let shared = handle.state::<Shared>();
            let mut a = shared.app.lock().unwrap();
            a.apply_live(live);
            a.quotas_fetched = true;
            a.next_quota_fetch = timeutil::now_secs() + QUOTA_INTERVAL;
        }
        publish(&handle);
        match rx.recv_timeout(Duration::from_secs(QUOTA_INTERVAL as u64)) {
            Ok(()) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}

fn run(demo: bool) {
    let settings = Settings::load();
    let mut model = App::new(settings);
    if demo {
        model.load_demo();
    }
    let (quota_tx, quota_rx) = channel();
    let shared = Shared { app: Arc::new(Mutex::new(model)), quota_now: quota_tx, anchor: Mutex::new(None), hidden_at: Mutex::new(0.0) };

    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        // Named outright, so the uninstaller removes the same Run entry.
        .plugin(tauri_plugin_autostart::Builder::new().app_name("Usage Manager").build())
        .manage(shared)
        .invoke_handler(tauri::generate_handler![state, set_threshold, set_alerts, set_hooks, set_launch, refresh_now, hide, quit, fit])
        .setup(move |app| {
            let handle = app.handle().clone();
            {
                let shared = handle.state::<Shared>();
                let mut a = shared.app.lock().unwrap();
                a.launch_at_login = handle.autolaunch().is_enabled().unwrap_or(false);
                if !a.demo {
                    a.hooks_on = hooks::status(&exe()).claude;
                    hooks::set_gate_enabled(a.settings.alerts_on);
                }
            }
            if let Some(w) = handle.get_webview_window("main") {
                dark_border(&w);
            }
            TrayIconBuilder::with_id("tray")
                .icon(tray_icon())
                .tooltip("Usage Manager")
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, rect, .. } = event {
                        let handle = tray.app_handle();
                        let scale = handle.get_webview_window("main").and_then(|w| w.scale_factor().ok()).unwrap_or(1.0);
                        let pos = rect.position.to_physical::<f64>(scale);
                        let size = rect.size.to_physical::<f64>(scale);
                        *handle.state::<Shared>().anchor.lock().unwrap() = Some((pos.x + size.width / 2.0, pos.y + size.height / 2.0));
                        toggle(handle);
                    }
                })
                .build(app)?;

            // `--show`: open the popover at once, where a tray click would, for checking
            // the window without a hand on the mouse.
            if std::env::args().any(|a| a == "--show") {
                if let Some(m) = handle.primary_monitor().ok().flatten() {
                    let a = m.work_area();
                    let s = m.scale_factor();
                    *handle.state::<Shared>().anchor.lock().unwrap() =
                        Some((a.position.x as f64 + a.size.width as f64 - 120.0 * s, a.position.y as f64 + a.size.height as f64 + 20.0 * s));
                }
                toggle(&handle);
            }
            if !demo {
                let _ = std::fs::create_dir_all(paths::claude_status());
                let scanner = scanner::Scanner::new(paths::home());
                let (tx, rx) = channel::<Vec<PathBuf>>();
                let watch = scanner.watch_paths();
                let first = tx.clone();
                // The watcher lives as long as the app; it is moved into the managed state.
                let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
                    if let Ok(ev) = res {
                        let _ = tx.send(ev.paths);
                    }
                })?;
                for p in watch.iter().filter(|p| p.exists()) {
                    use notify::Watcher;
                    let _ = watcher.watch(p, notify::RecursiveMode::Recursive);
                }
                app.manage(Mutex::new(watcher));
                let _ = first.send(vec![]);
                let h1 = handle.clone();
                std::thread::spawn(move || scan_loop(h1, rx, scanner));
                let h2 = handle.clone();
                std::thread::spawn(move || quota_loop(h2, quota_rx));
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if std::env::var("USAGE_MANAGER_DEBUG").is_ok() {
                paths::append_log("window.log", &format!("{event:?} visible={:?}", window.is_visible()));
            }
            // Close on a click elsewhere, as a flyout does. Focus can bounce between the
            // window and its webview for a moment as it opens, so only a loss that is still
            // a loss a moment later counts. `--show` keeps its window for checking.
            if let WindowEvent::Focused(false) = event {
                if std::env::args().any(|a| a == "--show") {
                    return;
                }
                let w = window.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(200));
                    if !w.is_focused().unwrap_or(false) && w.is_visible().unwrap_or(false) {
                        let _ = w.hide();
                        *w.state::<Shared>().hidden_at.lock().unwrap() = timeutil::now_secs();
                    }
                });
            }
        })
        .build(tauri::generate_context!())
        .expect("Usage Manager failed to start")
        .run(|_, event| {
            // A tray app outlives its window.
            if let tauri::RunEvent::ExitRequested { api, code: None, .. } = event {
                api.prevent_exit();
            }
        });
}
