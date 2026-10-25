use id3::{Tag, TagLike, Version};
use regex::Regex;
use std::fs;
use std::path::Path;

// 🛠️ REINGENIERÍA: FFmpeg erradicado del pipeline de metadatos.
// Ahora se ejecuta en memoria pura (Zero-Copy) ahorrando cientos de subprocesos PID.
pub async fn process_metadata(input_path: String) -> Result<Vec<String>, String> {
    let input = Path::new(&input_path);
    if !input.exists() {
        return Err("Archivo no encontrado en I/O nativo.".to_string());
    }

    let filename = input.file_name().unwrap().to_string_lossy().into_owned();
    let (new_filename, artist, title) = parse_and_clean(&filename);

    let parent = input.parent().ok_or("Ruta huérfana".to_string())?;
    let new_file_path = parent.join(&new_filename);

    // 1. Escritura binaria ID3 en RAM (Instantánea)
    let mut tag = Tag::read_from_path(input).unwrap_or_else(|_| Tag::new());
    tag.set_title(&title);
    tag.set_artist(&artist);
    tag.set_album("ReGenial Master");

    if let Err(e) = tag.write_to_path(input, Version::Id3v24) {
        return Err(format!("Error escribiendo ID3 nativo: {}", e));
    }

    // 2. Renombrado físico atómico sin crear archivos temporales pesados
    if input != new_file_path.as_path() {
        let mut attempts = 0;
        let mut delay_ms = 50;
        loop {
            match fs::rename(input, &new_file_path) {
                Ok(_) => break,
                Err(e) => {
                    attempts += 1;
                    if attempts >= 5 {
                        return Err(format!("Rename error tras 5 intentos: {}", e));
                    }
                    std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                    delay_ms *= 2;
                }
            }
        }
    }

    Ok(vec![new_filename, artist, title])
}

fn parse_and_clean(filename: &str) -> (String, String, String) {
    let mut name = filename.to_string();
    let mut ext = String::new();

    if let Some(idx) = name.rfind('.') {
        ext = name[idx..].to_string();
        name = name[..idx].to_string();
    }

    if name.ends_with("_R") || name.ends_with(" R") {
        name = name[..name.len() - 2].to_string();
    }

    let garbage_regex = Regex::new(r"(?i)\s*[\(\[\{][^\)\]\}]*(official|music video|video|audio|lyric|lyrics|letra|letras|hq|hd|4k|remastered|remaster|visualizer|en vivo|en directo|live)[^\)\]\}]*(?:[\)\]\}]|$)\s*").unwrap();
    let spaces_regex = Regex::new(r"\s{2,}").unwrap();
    let dash_regex = Regex::new(r"\s*-\s*-+\s*").unwrap();
    let invalid_chars_regex = Regex::new(r#"[<>:"/\\|?*]"#).unwrap();

    let mut clean_name = garbage_regex.replace_all(&name, " ").to_string();
    clean_name = dash_regex.replace_all(&clean_name, " - ").to_string();
    clean_name = clean_name.replace("_", " ");
    clean_name = spaces_regex
        .replace_all(&clean_name, " ")
        .trim()
        .to_string();

    let parts: Vec<&str> = clean_name.split(" - ").collect();
    let mut artist = "Unknown".to_string();
    let mut title = clean_name.clone();

    if parts.len() >= 2 {
        artist = parts[0].trim().to_string();
        title = parts[1..].join(" - ").trim().to_string();
    }

    artist = to_title_case(&artist);
    title = to_title_case(&title);

    let trailing_regex = Regex::new(r"[\.\-_]+$").unwrap();
    title = trailing_regex.replace(&title, "").to_string();

    let final_filename = if artist != "Unknown" {
        format!("{} - {}{}", artist, title, ext)
    } else {
        format!("{}{}", title, ext)
    };

    let safe_filename = invalid_chars_regex
        .replace_all(&final_filename, "")
        .to_string();
    (safe_filename, artist, title)
}

fn to_title_case(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    text.split_whitespace()
        .map(|word| {
            let mut c = word.chars();
            match c.next() {
                None => String::new(),
                Some(f) => {
                    f.to_uppercase().collect::<String>() + c.as_str().to_lowercase().as_str()
                }
            }
        })
        .collect::<Vec<String>>()
        .join(" ")
}
