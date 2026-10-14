//! OBS WebSocket backend. Runs on the tokio runtime, receives [`Command`]s from the UI
//! and pushes [`Update`]s back over an async channel consumed on the GTK main loop.

use std::time::Duration;

use futures_util::StreamExt;
use obws::Client;
use obws::events::{Event, OutputState};
use obws::requests::inputs::Volume;
use tokio::sync::mpsc;

const RECONNECT_DELAY: Duration = Duration::from_secs(3);
/// Slider floor; anything at or below is sent as -inf (mul 0).
pub const MIN_DB: f32 = -60.0;

#[derive(Debug, Clone)]
pub struct ConnParams {
    pub host: String,
    pub port: u16,
    pub password: Option<String>,
}

#[derive(Debug)]
pub enum Command {
    Connect(ConnParams),
    Disconnect,
    Refresh,
    SetProgramScene(String),
    SetPreviewScene(String),
    Transition,
    SetStudioMode(bool),
    ToggleStream,
    ToggleRecord,
    ToggleRecordPause,
    ToggleVirtualCam,
    ToggleReplayBuffer,
    SaveReplay,
    TriggerHotkey { name: String, context: Option<String> },
    ToggleMute(String),
    SetVolume(String, f32),
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Phase {
    #[default]
    Off,
    Starting,
    On,
    Stopping,
    Reconnecting,
}

impl Phase {
    pub fn is_active(self) -> bool {
        matches!(self, Phase::On | Phase::Reconnecting | Phase::Stopping)
    }

    fn from_active(active: bool) -> Self {
        if active { Phase::On } else { Phase::Off }
    }

    fn from_state(state: OutputState) -> Self {
        match state {
            OutputState::Starting => Phase::Starting,
            OutputState::Stopping => Phase::Stopping,
            OutputState::Stopped => Phase::Off,
            OutputState::Reconnecting => Phase::Reconnecting,
            _ => Phase::On,
        }
    }
}

#[derive(Debug, Clone)]
pub struct AudioInput {
    pub name: String,
    pub muted: bool,
    pub volume_db: f32,
}

#[derive(Debug)]
pub enum Update {
    Connecting,
    Connected { obs_version: String },
    Disconnected(Option<String>),
    SceneList(Vec<String>),
    ProgramScene(Option<String>),
    PreviewScene(Option<String>),
    StudioMode(bool),
    Stream(Phase),
    Record { phase: Phase, paused: bool },
    VirtualCam(Option<Phase>),
    ReplayBuffer(Option<Phase>),
    Timecodes { stream: Option<Duration>, record: Option<Duration> },
    Hotkeys(Vec<String>),
    Inputs(Vec<String>),
    AudioInputs(Vec<AudioInput>),
    InputMute(String, bool),
    InputVolume(String, f32),
    Error(String),
}

pub type CommandSender = mpsc::UnboundedSender<Command>;

pub fn spawn(rt: &tokio::runtime::Handle) -> (CommandSender, async_channel::Receiver<Update>) {
    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
    let (upd_tx, upd_rx) = async_channel::unbounded();
    rt.spawn(run(cmd_rx, Out(upd_tx)));
    (cmd_tx, upd_rx)
}

#[derive(Clone)]
struct Out(async_channel::Sender<Update>);

impl Out {
    fn send(&self, u: Update) {
        let _ = self.0.try_send(u);
    }
}

enum SessionEnd {
    Lost(String),
    NewParams(ConnParams),
    UserDisconnect,
    Quit,
}

async fn run(mut cmd_rx: mpsc::UnboundedReceiver<Command>, out: Out) {
    let mut params: Option<ConnParams> = None;

    loop {
        let Some(p) = params.clone() else {
            match cmd_rx.recv().await {
                Some(Command::Connect(p)) => params = Some(p),
                Some(_) => {}
                None => return,
            }
            continue;
        };

        out.send(Update::Connecting);
        match Client::connect(&p.host, p.port, p.password.as_deref()).await {
            Ok(mut client) => {
                let end = session(&client, &mut cmd_rx, &out).await;
                client.disconnect().await;
                match end {
                    SessionEnd::Lost(reason) => out.send(Update::Disconnected(Some(reason))),
                    SessionEnd::NewParams(p) => {
                        params = Some(p);
                        continue;
                    }
                    SessionEnd::UserDisconnect => {
                        params = None;
                        out.send(Update::Disconnected(None));
                        continue;
                    }
                    SessionEnd::Quit => return,
                }
            }
            Err(e) => out.send(Update::Disconnected(Some(describe_error(&e)))),
        }

        // Wait before retrying, but react immediately to user commands.
        tokio::select! {
            _ = tokio::time::sleep(RECONNECT_DELAY) => {}
            cmd = cmd_rx.recv() => match cmd {
                Some(Command::Connect(p)) => params = Some(p),
                Some(Command::Disconnect) => {
                    params = None;
                    out.send(Update::Disconnected(None));
                }
                Some(_) => {}
                None => return,
            }
        }
    }
}

fn describe_error(e: &obws::error::Error) -> String {
    use obws::error::Error;
    match e {
        Error::Timeout => "Timeout: OBS non risponde".into(),
        Error::Connect(_) => "Impossibile connettersi: OBS è aperto e il server WebSocket è attivo?".into(),
        Error::Handshake(_) => "Autenticazione fallita: controlla la password".into(),
        Error::Api { code, message } => match message {
            Some(m) => format!("{m} ({code:?})"),
            None => format!("Errore OBS: {code:?}"),
        },
        other => other.to_string(),
    }
}

async fn session(
    client: &Client,
    cmd_rx: &mut mpsc::UnboundedReceiver<Command>,
    out: &Out,
) -> SessionEnd {
    // Subscribe before the initial fetch so no change slips through in between.
    let mut events = match client.events() {
        Ok(e) => e,
        Err(e) => return SessionEnd::Lost(describe_error(&e)),
    };

    match client.general().version().await {
        Ok(v) => out.send(Update::Connected { obs_version: v.obs_studio_version.to_string() }),
        Err(e) => return SessionEnd::Lost(describe_error(&e)),
    }

    let mut st = SessionState::default();
    if let Err(e) = full_refresh(client, out, &mut st).await {
        return SessionEnd::Lost(describe_error(&e));
    }

    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            ev = events.next() => match ev {
                None | Some(Event::ServerStopping | Event::ServerStopped | Event::ExitStarted) => {
                    return SessionEnd::Lost("OBS ha chiuso la connessione".into());
                }
                Some(ev) => {
                    if let Err(e) = handle_event(client, out, &mut st, ev).await {
                        out.send(Update::Error(describe_error(&e)));
                    }
                }
            },
            cmd = cmd_rx.recv() => match cmd {
                None => return SessionEnd::Quit,
                Some(Command::Connect(p)) => return SessionEnd::NewParams(p),
                Some(Command::Disconnect) => return SessionEnd::UserDisconnect,
                Some(Command::Refresh) => {
                    if let Err(e) = full_refresh(client, out, &mut st).await {
                        out.send(Update::Error(describe_error(&e)));
                    }
                }
                Some(cmd) => {
                    if let Err(e) = execute(client, cmd).await {
                        out.send(Update::Error(describe_error(&e)));
                    }
                }
            },
            _ = tick.tick() => {
                if st.stream.is_active() || st.record.is_active() {
                    update_timecodes(client, out, &st).await;
                }
            }
        }
    }
}

#[derive(Default)]
struct SessionState {
    stream: Phase,
    record: Phase,
}

async fn update_timecodes(client: &Client, out: &Out, st: &SessionState) {
    let stream = if st.stream.is_active() {
        client.streaming().status().await.ok().map(|s| millis(s.duration.whole_milliseconds()))
    } else {
        None
    };
    let record = if st.record.is_active() {
        client.recording().status().await.ok().map(|s| millis(s.duration.whole_milliseconds()))
    } else {
        None
    };
    out.send(Update::Timecodes { stream, record });
}

fn millis(ms: i128) -> Duration {
    Duration::from_millis(ms.max(0) as u64)
}

async fn full_refresh(client: &Client, out: &Out, st: &mut SessionState) -> obws::error::Result<()> {
    refresh_scenes(client, out).await?;

    let studio = client.ui().studio_mode_enabled().await?;
    out.send(Update::StudioMode(studio));

    let stream = client.streaming().status().await?;
    st.stream = if stream.reconnecting { Phase::Reconnecting } else { Phase::from_active(stream.active) };
    out.send(Update::Stream(st.stream));

    let record = client.recording().status().await?;
    st.record = Phase::from_active(record.active);
    out.send(Update::Record { phase: st.record, paused: record.paused });

    // Virtual cam and replay buffer may be unavailable (not installed / not enabled in settings).
    let vcam = client.virtual_cam().status().await.ok().map(Phase::from_active);
    out.send(Update::VirtualCam(vcam));
    let replay = client.replay_buffer().status().await.ok().map(Phase::from_active);
    out.send(Update::ReplayBuffer(replay));

    out.send(Update::Hotkeys(client.hotkeys().list().await?));
    refresh_inputs(client, out).await?;
    Ok(())
}

async fn refresh_scenes(client: &Client, out: &Out) -> obws::error::Result<()> {
    let list = client.scenes().list().await?;
    let mut scenes = list.scenes;
    // obs-websocket lists scenes bottom-up; reverse to match the OBS UI order.
    scenes.sort_by_key(|s| std::cmp::Reverse(s.index));
    out.send(Update::SceneList(scenes.into_iter().map(|s| s.id.name).collect()));
    out.send(Update::ProgramScene(list.current_program_scene.map(|s| s.name)));
    out.send(Update::PreviewScene(list.current_preview_scene.map(|s| s.name)));
    Ok(())
}

async fn refresh_inputs(client: &Client, out: &Out) -> obws::error::Result<()> {
    let inputs = client.inputs().list(None).await?;
    let mut audio = Vec::new();
    for input in &inputs {
        let name = input.id.name.as_str();
        // Inputs without audio reject GetInputMute; that is how we filter them out.
        let Ok(muted) = client.inputs().muted(name.into()).await else { continue };
        let volume_db = client
            .inputs()
            .volume(name.into())
            .await
            .map(|v| v.db)
            .unwrap_or(0.0);
        audio.push(AudioInput { name: name.to_owned(), muted, volume_db });
    }
    out.send(Update::Inputs(inputs.into_iter().map(|i| i.id.name).collect()));
    out.send(Update::AudioInputs(audio));
    Ok(())
}

async fn handle_event(
    client: &Client,
    out: &Out,
    st: &mut SessionState,
    ev: Event,
) -> obws::error::Result<()> {
    match ev {
        Event::CurrentProgramSceneChanged { id } => out.send(Update::ProgramScene(Some(id.name))),
        Event::CurrentPreviewSceneChanged { id } => out.send(Update::PreviewScene(Some(id.name))),
        Event::SceneListChanged { .. }
        | Event::SceneCreated { .. }
        | Event::SceneRemoved { .. }
        | Event::SceneNameChanged { .. } => {
            refresh_scenes(client, out).await?;
            out.send(Update::Hotkeys(client.hotkeys().list().await?));
        }
        Event::StudioModeStateChanged { enabled } => {
            out.send(Update::StudioMode(enabled));
            let preview = if enabled {
                client.scenes().current_preview_scene().await.ok().map(|s| s.id.name)
            } else {
                None
            };
            out.send(Update::PreviewScene(preview));
        }
        Event::StreamStateChanged { state, .. } => {
            st.stream = Phase::from_state(state);
            out.send(Update::Stream(st.stream));
        }
        Event::RecordStateChanged { state, .. } => {
            let paused = state == OutputState::Paused;
            st.record = Phase::from_state(state);
            out.send(Update::Record { phase: st.record, paused });
        }
        Event::VirtualcamStateChanged { state, .. } => {
            out.send(Update::VirtualCam(Some(Phase::from_state(state))));
        }
        Event::ReplayBufferStateChanged { state, .. } => {
            out.send(Update::ReplayBuffer(Some(Phase::from_state(state))));
        }
        Event::InputMuteStateChanged { id, muted } => out.send(Update::InputMute(id.name, muted)),
        Event::InputVolumeChanged { id, db, .. } => out.send(Update::InputVolume(id.name, db as f32)),
        Event::InputCreated { .. } | Event::InputRemoved { .. } | Event::InputNameChanged { .. } => {
            refresh_inputs(client, out).await?;
            out.send(Update::Hotkeys(client.hotkeys().list().await?));
        }
        Event::CurrentSceneCollectionChanged { .. } | Event::CurrentProfileChanged { .. } => {
            full_refresh(client, out, st).await?;
        }
        _ => {}
    }
    Ok(())
}

async fn execute(client: &Client, cmd: Command) -> obws::error::Result<()> {
    match cmd {
        Command::SetProgramScene(name) => client.scenes().set_current_program_scene(name.as_str()).await,
        Command::SetPreviewScene(name) => client.scenes().set_current_preview_scene(name.as_str()).await,
        Command::Transition => client.transitions().trigger().await,
        Command::SetStudioMode(on) => client.ui().set_studio_mode_enabled(on).await,
        Command::ToggleStream => client.streaming().toggle().await.map(drop),
        Command::ToggleRecord => client.recording().toggle().await.map(drop),
        Command::ToggleRecordPause => client.recording().toggle_pause().await.map(drop),
        Command::ToggleVirtualCam => client.virtual_cam().toggle().await.map(drop),
        Command::ToggleReplayBuffer => client.replay_buffer().toggle().await.map(drop),
        Command::SaveReplay => client.replay_buffer().save().await,
        Command::TriggerHotkey { name, context } => {
            client.hotkeys().trigger_by_name(&name, context.as_deref()).await
        }
        Command::ToggleMute(name) => client.inputs().toggle_mute(name.as_str().into()).await.map(drop),
        Command::SetVolume(name, db) => {
            let volume = if db <= MIN_DB { Volume::Mul(0.0) } else { Volume::Db(db) };
            client.inputs().set_volume(name.as_str().into(), volume).await
        }
        Command::Connect(_) | Command::Disconnect | Command::Refresh => Ok(()),
    }
}
