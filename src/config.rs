use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// A hotkey pinned to the favorites panel. `context` is the source/scene name
/// for hotkeys that OBS registers once per source.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Favorite {
    pub name: String,
    pub context: Option<String>,
}

/// What a panel button does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum PanelAction {
    Scene { name: String },
    Hotkey { name: String, context: Option<String> },
    Mute { input: String },
}

/// A user-placed button on the custom panel.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PanelItem {
    #[serde(flatten)]
    pub action: PanelAction,
    /// Custom title; falls back to the scene/input name or hotkey label.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

/// Tile density: bigger tiles mean fewer columns at the same window width.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TileSize {
    Small,
    #[default]
    Medium,
    Large,
}

impl TileSize {
    pub const ALL: [TileSize; 3] = [TileSize::Small, TileSize::Medium, TileSize::Large];

    pub fn css_class(self) -> &'static str {
        match self {
            TileSize::Small => "tiles-small",
            TileSize::Medium => "tiles-medium",
            TileSize::Large => "tiles-large",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            TileSize::Small => "Piccoli",
            TileSize::Medium => "Medi",
            TileSize::Large => "Grandi",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub host: String,
    pub port: u16,
    pub password: String,
    pub auto_connect: bool,
    pub start_fullscreen: bool,
    pub confirm_stop: bool,
    pub tile_size: TileSize,
    pub favorites: Vec<Favorite>,
    /// User-chosen tile names, keyed by [`alias_key`]. Plugins often expose only internal
    /// hotkey names over the WebSocket (descriptions are not part of the API).
    pub aliases: BTreeMap<String, String>,
    pub panel: Vec<PanelItem>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            host: "localhost".into(),
            port: 4455,
            password: String::new(),
            auto_connect: false,
            start_fullscreen: false,
            confirm_stop: true,
            tile_size: TileSize::Medium,
            favorites: Vec::new(),
            aliases: BTreeMap::new(),
            panel: Vec::new(),
        }
    }
}

pub fn alias_key(name: &str, context: Option<&str>) -> String {
    match context {
        Some(c) => format!("{name}@{c}"),
        None => name.to_owned(),
    }
}

fn path() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("obs-touch-control").join("config.json"))
}

impl Config {
    pub fn load() -> Self {
        path()
            .and_then(|p| fs::read_to_string(p).ok())
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    /// Writes the config with 0600 permissions, since it holds the websocket password.
    pub fn save(&self) -> std::io::Result<()> {
        let path = path().ok_or_else(|| std::io::Error::other("config dir not found"))?;
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let json = serde_json::to_string_pretty(self).map_err(std::io::Error::other)?;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        file.write_all(json.as_bytes())
    }

    pub fn is_favorite(&self, fav: &Favorite) -> bool {
        self.favorites.contains(fav)
    }

    pub fn toggle_favorite(&mut self, fav: Favorite) {
        if let Some(pos) = self.favorites.iter().position(|f| *f == fav) {
            self.favorites.remove(pos);
        } else {
            self.favorites.push(fav);
        }
    }
}
