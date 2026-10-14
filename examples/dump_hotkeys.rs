//! Prints every hotkey name OBS exposes over the WebSocket, using the app's saved config.
//! Run: cargo run --example dump_hotkeys

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = dirs::config_dir().unwrap().join("obs-touch-control/config.json");
    let cfg: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path)?)?;
    let password = cfg["password"].as_str().filter(|p| !p.is_empty());
    let client = obws::Client::connect(
        cfg["host"].as_str().unwrap_or("localhost"),
        cfg["port"].as_u64().unwrap_or(4455) as u16,
        password,
    )
    .await?;
    for name in client.hotkeys().list().await? {
        println!("{name}");
    }
    Ok(())
}
