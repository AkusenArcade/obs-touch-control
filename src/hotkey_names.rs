//! Human-friendly labels and grouping for OBS internal hotkey names.

/// Display name of the group a hotkey belongs to, based on its prefix.
pub fn group(name: &str) -> String {
    match name.split_once('.').map(|(p, _)| p) {
        Some("OBSBasic") => "OBS".into(),
        Some("libobs") => "Sorgenti".into(),
        Some(prefix) => humanize(prefix),
        None if is_scene_switcher(name) => "Advanced Scene Switcher".into(),
        None if name.starts_with("VerticalCanvasDock") => "Canvas verticale".into(),
        None => "Altro".into(),
    }
}

pub fn label(name: &str) -> String {
    let known = match name {
        "OBSBasic.StartStreaming" => "Avvia diretta",
        "OBSBasic.StopStreaming" => "Ferma diretta",
        "OBSBasic.ForceStopStreaming" => "Forza stop diretta",
        "OBSBasic.StartRecording" => "Avvia registrazione",
        "OBSBasic.StopRecording" => "Ferma registrazione",
        "OBSBasic.PauseRecording" => "Pausa registrazione",
        "OBSBasic.UnpauseRecording" => "Riprendi registrazione",
        "OBSBasic.SplitFile" => "Dividi file registrazione",
        "OBSBasic.AddChapterMarker" => "Aggiungi capitolo",
        "OBSBasic.StartReplayBuffer" => "Avvia replay buffer",
        "OBSBasic.StopReplayBuffer" => "Ferma replay buffer",
        "OBSBasic.StartVirtualCam" => "Avvia camera virtuale",
        "OBSBasic.StopVirtualCam" => "Ferma camera virtuale",
        "OBSBasic.EnablePreview" => "Abilita anteprima",
        "OBSBasic.DisablePreview" => "Disabilita anteprima",
        "OBSBasic.EnablePreviewProgram" => "Attiva Studio Mode",
        "OBSBasic.DisablePreviewProgram" => "Disattiva Studio Mode",
        "OBSBasic.ShowContextBar" => "Mostra barra sorgente",
        "OBSBasic.HideContextBar" => "Nascondi barra sorgente",
        "OBSBasic.Transition" => "Transizione",
        "OBSBasic.ResetStats" => "Azzera statistiche",
        "OBSBasic.Screenshot" => "Screenshot",
        "OBSBasic.SelectedSourceScreenshot" => "Screenshot sorgente selezionata",
        "OBSBasic.SelectScene" => "Passa alla scena",
        "OBSBasic.QuickTransition" => "Transizione rapida",
        "libobs.mute" => "Silenzia",
        "libobs.unmute" => "Riattiva audio",
        "libobs.push-to-mute" => "Push-to-mute",
        "libobs.push-to-talk" => "Push-to-talk",
        "ReplayBuffer.Save" => "Salva replay",
        "MediaSource.Restart" => "Riavvia media",
        "MediaSource.Play" => "Riproduci media",
        "MediaSource.Pause" => "Pausa media",
        "MediaSource.Stop" => "Ferma media",
        "ObsBrowser.Refresh" => "Aggiorna browser",
        _ => "",
    };
    if !known.is_empty() {
        return known.into();
    }
    if let Some(desc) = name.strip_prefix("macro_condition_hotkey_") {
        return desc.to_owned();
    }
    for (prefix, verb) in [
        ("macro_pause_hotkey_", "Pausa macro"),
        ("macro_unpause_hotkey_", "Riprendi macro"),
        ("macro_toggle_pause_hotkey_", "Pausa/riprendi macro"),
    ] {
        if let Some(n) = name.strip_prefix(prefix) {
            return format!("{verb} {n}");
        }
    }
    if let Some(rest) = name.strip_prefix("VerticalCanvasDock") {
        return format!("Verticale: {}", humanize(rest).to_lowercase());
    }
    if let Some(item) = name.strip_prefix("libobs.show_scene_item.") {
        return format!("Mostra «{item}»");
    }
    if let Some(item) = name.strip_prefix("libobs.hide_scene_item.") {
        return format!("Nascondi «{item}»");
    }
    humanize(name.rsplit_once('.').map_or(name, |(_, last)| last))
}

/// Advanced Scene Switcher registers its hotkeys with bare, dot-less names.
fn is_scene_switcher(name: &str) -> bool {
    name.starts_with("macro_") || name.ends_with("SwitcherHotkey")
}

/// "SelectedSourceScreenshot" / "push_to_talk" -> "Selected source screenshot" / "Push to talk".
fn humanize(raw: &str) -> String {
    let mut words: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut prev_lower = false;
    for c in raw.chars() {
        let split = c == '_' || c == '-' || c == ' ';
        if (split || (c.is_uppercase() && prev_lower)) && !cur.is_empty() {
            words.push(std::mem::take(&mut cur));
        }
        if !split {
            cur.push(c);
        }
        prev_lower = c.is_lowercase() || c.is_ascii_digit();
    }
    if !cur.is_empty() {
        words.push(cur);
    }
    let mut out = String::with_capacity(raw.len() + words.len());
    for (i, w) in words.iter().enumerate() {
        let mut chars = w.chars();
        let Some(first) = chars.next() else { continue };
        if i > 0 {
            out.push(' ');
        }
        // Keep acronyms ("OBS", "NDI") as they are.
        if w.chars().all(|c| !c.is_lowercase()) {
            out.push_str(w);
        } else if i == 0 {
            out.extend(first.to_uppercase());
            out.push_str(chars.as_str());
        } else {
            out.extend(first.to_lowercase());
            out.push_str(chars.as_str());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels() {
        assert_eq!(label("OBSBasic.StartStreaming"), "Avvia diretta");
        assert_eq!(label("Foo.SomeNewThing"), "Some new thing");
        assert_eq!(label("plugin.push_to_talk"), "Push to talk");
        assert_eq!(group("OBSBasic.Transition"), "OBS");
        assert_eq!(group("MediaSource.Play"), "Media source");
        assert_eq!(label("macro_condition_hotkey_Macro trigger hotkey 1"), "Macro trigger hotkey 1");
        assert_eq!(group("macro_condition_hotkey_Macro trigger hotkey 1"), "Advanced Scene Switcher");
        assert_eq!(group("startSwitcherHotkey"), "Advanced Scene Switcher");
        assert_eq!(label("VerticalCanvasDockStartRecording"), "Verticale: start recording");
    }
}
