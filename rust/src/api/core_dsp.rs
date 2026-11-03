use std::fs::File;
use std::path::Path;

use id3::frame::ExtendedText;
use id3::{Tag, TagLike, Version};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::{FormatOptions, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use symphonia::core::units::Time;
use symphonia::default::get_probe;

// ============================================================================
// REGLA (CONTEXTO §2.7 y §7): CERO FFmpeg y CERO reproductor extra.
// Todo el análisis (volumen, silencios, BPM, duración) se hace en proceso con
// Rust/symphonia, igual en Windows, macOS, Android e iPhone. El MP3 NO se
// recodifica en `analyze_and_tag`: el resultado se guarda como etiquetas ID3
// (ReplayGain estándar + TXXX GMX_*). `master_rewrite` es el otro camino
// (opción b): recorta silencios y normaliza a −14 LUFS re-codificando UNA vez
// con el LAME vendorizado, sin EQ. El original se respalda aparte, en Dart.
// Las TXXX DJS_* de antes se siguen leyendo. El nombre anterior de los frames
// de sello está en CHANGELOG.md.
// ============================================================================

/// Versión del esquema de etiquetas. Si cambia, las pistas se reanalizan.
const MASTER_VERSION: &str = "1";
const KEY_V: &str = "GMX_V";
const KEY_LUFS: &str = "GMX_LUFS";
const KEY_LEAD: &str = "GMX_LEAD_MS";
const KEY_TAIL: &str = "GMX_TAIL_MS";
const OLD_V: &str = "DJS_V";
const OLD_LUFS: &str = "DJS_LUFS";
const OLD_LEAD: &str = "DJS_LEAD_MS";
const OLD_TAIL: &str = "DJS_TAIL_MS";

fn ext_any(tag: &Tag, key: &str, old: &str) -> Option<String> {
    ext_text(tag, key).or_else(|| ext_text(tag, old))
}

fn is_mastered(tag: &Tag) -> bool {
    // "1" = solo etiquetas. "2" = archivo ya reescrito (no volver a analizar
    // por encima: pisaría el lead del archivo cortado).
    matches!(ext_text(tag, KEY_V).as_deref(), Some("1") | Some("2"))
        || ext_text(tag, OLD_V).as_deref() == Some(MASTER_VERSION)
}

fn legacy_brand() -> String {
    format!("{}{}", "DJ", "Studio")
}
const SEAL_TEXT: &str = "ReGenial Master";
const RG_REFERENCE_LUFS: f64 = -18.0;
/// Tope de análisis sin TBPM (s). La pista se mide desde el inicio hasta aquí.
const MAX_ANALYZE_SECS: u32 = 900;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Resultado leído de las etiquetas de una pista (sin decodificar).
pub struct MasterTags {
    pub analyzed: bool,
    /// Ganancia ReplayGain (dB) para llegar a -18 LUFS.
    pub gain_db: f64,
    pub lufs: f64,
    pub peak: f64,
    /// Silencio inicial / final (ms).
    pub lead_ms: u64,
    pub tail_ms: u64,
    pub bpm: f64,
}

// ---------------------------------------------------------------- decodificar

struct Decoded {
    rate: u32,
    ch: Vec<Vec<f32>>,
    /// Inicio REAL del tramo (ms): un seek puede caer antes de lo pedido.
    start_ms: u64,
}

fn open_format(
    input_path: &str,
) -> Result<
    (
        Box<dyn symphonia::core::formats::FormatReader>,
        u32,
        symphonia::core::codecs::CodecParameters,
    ),
    String,
> {
    let file = File::open(input_path).map_err(|e| e.to_string())?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = Path::new(input_path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| e.to_string())?;
    let format = probed.format;
    let (track_id, params) = {
        let t = format.default_track().ok_or("Sin pista de audio")?;
        (t.id, t.codec_params.clone())
    };
    Ok((format, track_id, params))
}

/// Decodifica hasta `max_secs` segundos desde `start_secs`, hasta `max_ch`
/// canales (sin mezclar).
fn decode_channels(
    input_path: &str,
    start_secs: u32,
    max_secs: u32,
    max_ch: usize,
) -> Result<Decoded, String> {
    let (mut format, track_id, params) = open_format(input_path)?;
    let rate = params.sample_rate.ok_or("Sin frecuencia de muestreo")?;
    let mut decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .map_err(|e| e.to_string())?;

    let mut start_ms: u64 = 0;
    if start_secs > 0 {
        let sought = format.seek(
            SeekMode::Coarse,
            SeekTo::Time {
                time: Time::new(start_secs as u64, 0.0),
                track_id: Some(track_id),
            },
        );
        if let Ok(s) = sought {
            decoder.reset();
            if let Some(tb) = params.time_base {
                let t = tb.calc_time(s.actual_ts);
                start_ms = t.seconds * 1000 + (t.frac * 1000.0) as u64;
            } else {
                start_ms = start_secs as u64 * 1000;
            }
        }
    }

    let want = (rate as usize) * (max_secs as usize);
    let mut chans: Vec<Vec<f32>> = Vec::new();
    let mut frames = 0usize;
    let mut since_check = 0usize;
    while frames < want {
        cancel_now()?;
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(_) => break,
        };
        if packet.track_id() != track_id {
            continue;
        }
        match decoder.decode(&packet) {
            Ok(decoded) => {
                let spec = *decoded.spec();
                let n_ch = spec.channels.count().max(1);
                let keep = n_ch.min(max_ch.max(1));
                if chans.is_empty() {
                    chans = vec![Vec::with_capacity(want.min(1 << 24)); keep];
                }
                let mut buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
                buf.copy_interleaved_ref(decoded);
                for frame in buf.samples().chunks(n_ch) {
                    for c in 0..keep.min(chans.len()) {
                        chans[c].push(frame[c]);
                    }
                    frames += 1;
                    since_check += 1;
                    if since_check >= CANCEL_BLOCK {
                        since_check = 0;
                        cancel_now()?;
                    }
                }
            }
            Err(SymError::DecodeError(_)) => continue,
            Err(_) => break,
        }
    }
    if chans.is_empty() || chans[0].is_empty() {
        return Err("Sin audio decodificable".to_string());
    }
    Ok(Decoded {
        rate,
        ch: chans,
        start_ms,
    })
}

fn to_mono(d: &Decoded) -> Vec<f32> {
    let n = d.ch[0].len();
    let k = d.ch.len() as f32;
    (0..n)
        .map(|i| d.ch.iter().map(|c| c[i]).sum::<f32>() / k)
        .collect()
}

/// Decodifica un tramo a PCM mono s16le a `target_rate` Hz (EQ adaptativa).
pub async fn decode_mono_pcm(
    input_path: String,
    start_secs: u32,
    length_secs: u32,
    target_rate: u32,
) -> Result<Vec<u8>, String> {
    let d = decode_channels(&input_path, start_secs, length_secs, 2)?;
    let mono = to_mono(&d);
    let ratio = d.rate as f64 / target_rate as f64;
    let out_len = (mono.len() as f64 / ratio) as usize;
    let mut out: Vec<u8> = Vec::with_capacity(out_len * 2);
    for i in 0..out_len {
        let pos = i as f64 * ratio;
        let idx = pos as usize;
        let frac = (pos - idx as f64) as f32;
        let a = mono[idx];
        let b = if idx + 1 < mono.len() {
            mono[idx + 1]
        } else {
            a
        };
        let v = (a + (b - a) * frac).clamp(-1.0, 1.0);
        out.extend_from_slice(&((v * 32767.0) as i16).to_le_bytes());
    }
    Ok(out)
}

// ------------------------------------------------------------------ duración

/// Duración EXACTA en ms. Un MP3 sin cabecera Xing (o con carátula grande)
/// hace que libmpv la ESTIME por tamaño/bitrate y se pase. Si el contenedor
/// trae el total de cuadros se usa; si no, se suman las duraciones de los
/// paquetes. En MP3 se cuentan los frames reales: la cabecera Xing miente
/// cuando hay otro audio pegado al final. Devuelve 0 si no se puede determinar.
pub async fn exact_duration_ms(input_path: String) -> Result<u64, String> {
    decoded_duration_ms(&input_path)
}

fn decoded_duration_ms(input_path: &str) -> Result<u64, String> {
    let (mut format, track_id, params) = open_format(input_path)?;
    let tb = match params.time_base {
        Some(tb) => tb,
        None => return Ok(0),
    };
    let is_mp3 = params.codec == symphonia::core::codecs::CODEC_TYPE_MP3;
    if !is_mp3 {
        if let Some(n) = params.n_frames {
            let t = tb.calc_time(n);
            return Ok(t.seconds * 1000 + (t.frac * 1000.0) as u64);
        }
    }
    let mut total: u64 = 0;
    while let Ok(p) = format.next_packet() {
        if p.track_id() == track_id {
            total += p.dur;
        }
    }
    let t = tb.calc_time(total);
    Ok(t.seconds * 1000 + (t.frac * 1000.0) as u64)
}

/// Marca si el TLEN original y el audio medido difieren más de 10 s.
/// El valor es `tlen=<ms>,audio=<ms>`. Sin TLEN previo no hay marca.
pub fn len_mismatch_value(previous_tlen_ms: Option<u64>, audio_ms: u64) -> Option<String> {
    let prev = previous_tlen_ms?;
    if audio_ms.abs_diff(prev) > 10_000 {
        Some(format!("tlen={prev},audio={audio_ms}"))
    } else {
        None
    }
}

/// Reescribe el TLEN con la duración decodificada. No toca el audio.
/// `audio=<ms>,tlen=<ms|none>,mismatch=<0|1>,wrote=<0|1>`.
/// `tlen` es el valor que había antes de escribir.
pub fn rewrite_tlen(input_path: String) -> Result<String, String> {
    if !Path::new(&input_path).exists() {
        return Err("Archivo no encontrado en I/O.".to_string());
    }
    if !is_mp3(&input_path) {
        return Err("Solo MP3.".to_string());
    }
    let audio = decoded_duration_ms(&input_path)?;
    if audio == 0 {
        return Err("Sin duración decodificada.".to_string());
    }
    let mut tag = Tag::read_from_path(&input_path).unwrap_or_else(|_| Tag::new());
    let prev = tag.duration().map(|d| d as u64);
    let mismatch = len_mismatch_value(prev, audio);
    let same = prev == Some(audio);
    if !same {
        tag.set_duration(audio as u32);
        if let Some(value) = mismatch.clone() {
            set_ext(&mut tag, "GMX_LEN_MISMATCH", value);
        }
        tag.write_to_path(&input_path, Version::Id3v24)
            .map_err(|e| e.to_string())?;
    }
    let tlen = match prev {
        Some(v) => v.to_string(),
        None => "none".to_string(),
    };
    let mis = if mismatch.is_some() { "1" } else { "0" };
    let wrote = if same { "0" } else { "1" };
    Ok(format!(
        "audio={audio},tlen={tlen},mismatch={mis},wrote={wrote}"
    ))
}

#[cfg(test)]
mod tlen_mark_tests {
    use super::len_mismatch_value;

    #[test]
    fn marca_si_difiere_mas_de_10_s() {
        assert_eq!(
            len_mismatch_value(Some(224_209), 283_000).as_deref(),
            Some("tlen=224209,audio=283000")
        );
        assert!(len_mismatch_value(Some(224_209), 230_000).is_none());
        assert!(len_mismatch_value(None, 283_000).is_none());
        assert!(len_mismatch_value(Some(283_000), 283_000).is_none());
    }
}

/// Duración en ms para quien ya la usaba (mismo nombre). Ahora es exacta.
pub async fn get_audio_duration_ms(input_path: String) -> Result<u64, String> {
    match exact_duration_ms(input_path.clone()).await {
        Ok(ms) if ms > 0 => Ok(ms),
        _ => {
            let size = std::fs::metadata(&input_path)
                .map_err(|e| e.to_string())?
                .len();
            Ok((size * 8) / 320)
        }
    }
}

// ------------------------------------------------------------------- análisis

struct Biquad {
    b: [f64; 3],
    a: [f64; 2],
    x: [f64; 2],
    y: [f64; 2],
}

impl Biquad {
    fn run(&mut self, input: &[f32]) -> Vec<f64> {
        let mut out = Vec::with_capacity(input.len());
        for &s in input {
            let x0 = s as f64;
            let y0 = self.b[0] * x0 + self.b[1] * self.x[0] + self.b[2] * self.x[1]
                - self.a[0] * self.y[0]
                - self.a[1] * self.y[1];
            self.x[1] = self.x[0];
            self.x[0] = x0;
            self.y[1] = self.y[0];
            self.y[0] = y0;
            out.push(y0);
        }
        out
    }

    fn tick(&mut self, x0: f64) -> f64 {
        let y0 = self.b[0] * x0 + self.b[1] * self.x[0] + self.b[2] * self.x[1]
            - self.a[0] * self.y[0]
            - self.a[1] * self.y[1];
        self.x[1] = self.x[0];
        self.x[0] = x0;
        self.y[1] = self.y[0];
        self.y[0] = y0;
        y0
    }
}

/// Filtro K (ITU-R BS.1770): shelf de agudos + pasa-altos, para cualquier fs.
fn k_weight(input: &[f32], fs: f64) -> Vec<f64> {
    let pi = std::f64::consts::PI;
    // Etapa 1: high shelf
    let g = 3.999843853973347_f64;
    let q = 0.7071752369554196_f64;
    let fc = 1681.9744509555319_f64;
    let k = (pi * fc / fs).tan();
    let vh = 10f64.powf(g / 20.0);
    let vb = vh.powf(0.4996667741545416);
    let a0 = 1.0 + k / q + k * k;
    let mut s1 = Biquad {
        b: [
            (vh + vb * k / q + k * k) / a0,
            2.0 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
        ],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    // Etapa 2: pasa-altos
    let q2 = 0.5003270373238773_f64;
    let fc2 = 38.13547087602444_f64;
    let k2 = (pi * fc2 / fs).tan();
    let a02 = 1.0 + k2 / q2 + k2 * k2;
    let mut s2 = Biquad {
        b: [1.0, -2.0, 1.0],
        a: [2.0 * (k2 * k2 - 1.0) / a02, (1.0 - k2 / q2 + k2 * k2) / a02],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    let stage1 = s1.run(input);
    // La 2ª etapa se corre sobre f64 para no perder precisión.
    let mut out = Vec::with_capacity(stage1.len());
    for &v in &stage1 {
        let y0 = s2.b[0] * v + s2.b[1] * s2.x[0] + s2.b[2] * s2.x[1]
            - s2.a[0] * s2.y[0]
            - s2.a[1] * s2.y[1];
        s2.x[1] = s2.x[0];
        s2.x[0] = v;
        s2.y[1] = s2.y[0];
        s2.y[0] = y0;
        out.push(y0);
    }
    out
}

/// Sonoridad integrada (LUFS) con compuertas absoluta y relativa (BS.1770-4).
fn integrated_lufs(d: &Decoded) -> f64 {
    let fs = d.rate as f64;
    let weighted: Vec<Vec<f64>> = d.ch.iter().map(|c| k_weight(c, fs)).collect();
    let block = (fs * 0.400) as usize;
    let step = (fs * 0.100) as usize;
    let n = weighted[0].len();
    if n < block || step == 0 {
        return -70.0;
    }
    let mut zs: Vec<f64> = Vec::new();
    let mut start = 0usize;
    while start + block <= n {
        let mut z = 0.0;
        for ch in &weighted {
            let ms: f64 =
                ch[start..start + block].iter().map(|v| v * v).sum::<f64>() / block as f64;
            z += ms;
        }
        zs.push(z);
        start += step;
    }
    let lk = |z: f64| -0.691 + 10.0 * z.max(1e-12).log10();
    let abs_gated: Vec<f64> = zs.iter().copied().filter(|z| lk(*z) > -70.0).collect();
    if abs_gated.is_empty() {
        return -70.0;
    }
    let mean_abs = abs_gated.iter().sum::<f64>() / abs_gated.len() as f64;
    let rel_thr = lk(mean_abs) - 10.0;
    let rel_gated: Vec<f64> = abs_gated.into_iter().filter(|z| lk(*z) > rel_thr).collect();
    if rel_gated.is_empty() {
        return lk(mean_abs);
    }
    lk(rel_gated.iter().sum::<f64>() / rel_gated.len() as f64)
}

/// Silencio inicial y final (ms) con ventanas de 10 ms y umbral de -50 dBFS.
fn edge_silence_ms(mono: &[f32], rate: u32) -> (u64, u64) {
    let win = (rate as usize / 100).max(1);
    let thr = 10f64.powf(-50.0 / 20.0);
    let n_win = mono.len() / win;
    if n_win < 10 {
        return (0, 0);
    }
    let loud = |i: usize| -> bool {
        let s = &mono[i * win..(i + 1) * win];
        let rms = (s.iter().map(|v| (*v as f64) * (*v as f64)).sum::<f64>() / win as f64).sqrt();
        rms > thr
    };
    let first = (0..n_win).find(|i| loud(*i));
    let last = (0..n_win).rev().find(|i| loud(*i));
    match (first, last) {
        (Some(f), Some(l)) => {
            let lead = (f as u64) * 10;
            let tail = ((n_win - 1 - l) as u64) * 10;
            (lead, tail)
        }
        _ => (0, 0),
    }
}

/// 78–165, doblando o partiendo. Igual que el plegado histórico de `detect_bpm`.
fn fold_bpm_band(mut bpm: f64) -> f64 {
    while bpm < 78.0 {
        bpm *= 2.0;
    }
    while bpm > 165.0 {
        bpm /= 2.0;
    }
    bpm
}

fn near_bpm(measured: f64, reference: f64) -> bool {
    reference > 0.0 && (measured - reference).abs() <= reference * 0.02
}

/// Entre el lag ganador y sus vecinos ×4/3 y ×3/4, si uno cae en el TBPM
/// previo (±2 %) se queda con ese. Sin TBPM previo no elige.
fn lag_matching_prior(
    best_lag: f64,
    scores: &[f64],
    env_rate: f64,
    min_lag: usize,
    max_lag: usize,
    prior: f64,
) -> Option<f64> {
    let mut chosen: Option<(f64, f64)> = None;
    for factor in [1.0_f64, 4.0 / 3.0, 3.0 / 4.0] {
        let ilag = (best_lag * factor).round() as usize;
        if ilag < min_lag || ilag > max_lag || ilag >= scores.len() {
            continue;
        }
        let bpm = 60.0 * env_rate / ilag as f64;
        if !near_bpm(bpm, prior) && !near_bpm(fold_bpm_band(bpm), prior) {
            continue;
        }
        let score = scores[ilag];
        if score <= 0.0 {
            continue;
        }
        if chosen.map(|(s, _)| score > s).unwrap_or(true) {
            chosen = Some((score, ilag as f64));
        }
    }
    chosen.map(|(_, lag)| lag)
}

/// Rango de visualización del tempo, como en Rekordbox. Por defecto 60–180.
/// `fold_display_bpm` solo multiplica o divide por 2 para entrar en el rango.
const TEMPO_DISPLAY_LO: f64 = 60.0;
const TEMPO_DISPLAY_HI: f64 = 180.0;

/// ×2 o ÷2, y solo mientras el tempo queda fuera de `[lo, hi]`.
fn fold_display_bpm(mut bpm: f64, lo: f64, hi: f64) -> f64 {
    if !bpm.is_finite() || bpm <= 0.0 || !(lo > 0.0 && hi > lo) {
        return bpm;
    }
    for _ in 0..8 {
        if bpm < lo {
            bpm *= 2.0;
        } else if bpm > hi {
            bpm /= 2.0;
        } else {
            break;
        }
    }
    bpm
}

/// Ventana ~23 ms. El peine usa salto 512 (el de ahora). La envolvente de
/// golpes usa 256, dentro de 128–256 a 44,1 kHz: el 512 cuantizaba ±1–2 BPM.
/// Bello, Duxbury, Davies y Sandler, IEEE SPL 11(6), 2004.
fn odf_stft_hop(rate: u32, hop_at_44100: f64) -> (usize, usize) {
    let hop = ((rate as f64) * hop_at_44100 / 44100.0)
        .round()
        .clamp(1.0, 4096.0) as usize;
    let want = ((rate as f64) * 1024.0 / 44100.0).round().max(32.0) as usize;
    let up = want.next_power_of_two();
    let down = (up / 2).max(32);
    let n_fft = if want.saturating_sub(down) <= up.saturating_sub(want) {
        down
    } else {
        up
    };
    (n_fft.max(hop.saturating_mul(2)), hop)
}

/// Diferencia espectral en el dominio complejo.
/// Duxbury, Bello, Davies y Sandler, DAFx 2003, ec. (10)–(11):
/// el valor previsto de cada bin es la magnitud anterior con la fase
/// extrapolada `2φ[n−1] − φ[n−2]`; la detección es la distancia euclídea.
fn complex_odf(mono: &[f32], rate: u32) -> Option<(Vec<f64>, f64)> {
    complex_odf_hop(mono, rate, 512.0)
}

/// Envolvente de onsets con hop 256 a 44,1 kHz. Mismo detector complejo.
fn onset_envelope(mono: &[f32], rate: u32) -> Option<(Vec<f64>, f64)> {
    complex_odf_hop(mono, rate, 256.0)
}

fn complex_odf_hop(mono: &[f32], rate: u32, hop_at_44100: f64) -> Option<(Vec<f64>, f64)> {
    let (n_fft, hop) = odf_stft_hop(rate, hop_at_44100);
    if rate < 8000 || mono.len() < n_fft.saturating_mul(4) || hop == 0 {
        return None;
    }
    let frames = (mono.len() - n_fft) / hop;
    if frames < 64 {
        return None;
    }
    let mut planner = rustfft::FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(n_fft);
    let hann: Vec<f32> = (0..n_fft)
        .map(|i| {
            let x = 2.0 * std::f32::consts::PI * i as f32 / n_fft as f32;
            0.5 - 0.5 * x.cos()
        })
        .collect();
    let half = n_fft / 2;
    let mut mag1 = vec![0f32; half + 1];
    let mut mag2 = vec![0f32; half + 1];
    let mut ph1 = vec![0f32; half + 1];
    let mut ph2 = vec![0f32; half + 1];
    let mut buf = vec![rustfft::num_complex::Complex32::new(0.0, 0.0); n_fft];
    let mut odf = Vec::with_capacity(frames);
    for frame in 0..frames {
        // 32 cuadros de STFT quedan muy por debajo de 50 ms de trabajo.
        if frame % 32 == 0 && cancel_now().is_err() {
            return None;
        }
        let s = frame * hop;
        for i in 0..n_fft {
            buf[i] = rustfft::num_complex::Complex32::new(mono[s + i] * hann[i], 0.0);
        }
        fft.process(&mut buf);
        let mut eta = 0.0f64;
        for k in 1..=half {
            let re = buf[k].re;
            let im = buf[k].im;
            let mag = re.hypot(im);
            let ph = im.atan2(re);
            if frame >= 2 {
                let pred_ph = 2.0 * ph1[k] - ph2[k];
                let pred_re = mag1[k] * pred_ph.cos();
                let pred_im = mag1[k] * pred_ph.sin();
                eta += (re - pred_re).hypot(im - pred_im) as f64;
            }
            mag2[k] = mag1[k];
            ph2[k] = ph1[k];
            mag1[k] = mag;
            ph1[k] = ph;
        }
        odf.push(if eta.is_finite() { eta } else { 0.0 });
    }
    let env_rate = rate as f64 / hop as f64;
    Some((odf, env_rate))
}

fn acf_at(ac: &[f64], lag: f64) -> f64 {
    if !(lag.is_finite()) || lag < 1.0 {
        return 0.0;
    }
    let i = lag.floor() as usize;
    if i + 1 >= ac.len() {
        return 0.0;
    }
    let f = lag - i as f64;
    ac[i] * (1.0 - f) + ac[i + 1] * f
}

/// Autocorrelación insesgada del ventanal (Davies, Brossier y Plumbley,
/// AES 118, 2005, ec. 1): se resta la media y se divide por `N − lag`.
fn unbiased_acf(frame: &[f64], max_lag: usize) -> Vec<f64> {
    let n = frame.len();
    let mut ac = vec![0.0; max_lag.saturating_add(1)];
    if n < 8 || max_lag >= n {
        return ac;
    }
    let mean = frame.iter().copied().sum::<f64>() / n as f64;
    let x: Vec<f64> = frame.iter().map(|v| v - mean).collect();
    for lag in 1..=max_lag {
        let m = n - lag;
        let mut c = 0.0;
        for i in 0..m {
            c += x[i] * x[i + lag];
        }
        ac[lag] = c / m as f64;
    }
    ac
}

/// Banco de peines sobre la autocorrelación (Davies y Plumbley, 2007):
/// la hipótesis τ suma los armónicos τ, 2τ, 3τ y 4τ.
fn comb_score(ac: &[f64], tau: f64) -> f64 {
    let mut s = 0.0;
    for p in 1..=4 {
        let lag = tau * p as f64;
        if lag + 1.0 >= ac.len() as f64 {
            break;
        }
        s += acf_at(ac, lag);
    }
    s
}

/// Rayleigh con la moda en `b` muestras. Davies, Brossier y Plumbley, AES 2005, ec. (2).
/// La moda es 0,5 s (120 BPM): el centro perceptivo de Ellis, JNMR 2007 (τ0 = 0,5 s),
/// no la media de 48 muestras de aquel banco de prueba.
fn rayleigh_weight(lag: f64, mode: f64) -> f64 {
    if lag <= 0.0 || mode <= 0.0 {
        return 0.0;
    }
    let b2 = mode * mode;
    (lag / b2) * (-(lag * lag) / (2.0 * b2)).exp()
}

/// Viterbi del periodo. El prior es el modelo general (peine × Rayleigh)
/// sumado en toda la pieza. La transición es la gaussiana de contexto,
/// varianza τ/8, sin el factor 1/σ: Davies y Plumbley, AES 2005, ec. (4).
/// No salta de métrica: fuera de ~5 σ el peso es nulo.
fn tempo_viterbi(frame_score: &[Vec<f64>], lags: &[f64]) -> Vec<usize> {
    let n_t = frame_score.len();
    let n_k = lags.len();
    let mut acc = vec![0.0f64; n_k];
    for row in frame_score {
        for (k, s) in row.iter().enumerate() {
            acc[k] += *s;
        }
    }
    let mut v: Vec<f64> = acc.iter().map(|s| s.max(1e-18).ln()).collect();
    let mut back = vec![vec![0usize; n_k]; n_t];
    for t in 0..n_t {
        if cancel_now().is_err() {
            return Vec::new();
        }
        let mut nv = vec![f64::NEG_INFINITY; n_k];
        for k in 0..n_k {
            let emit = frame_score[t][k].max(1e-18).ln();
            let lag_k = lags[k];
            let mut best = f64::NEG_INFINITY;
            let mut best_j = k;
            for j in 0..n_k {
                let lag_j = lags[j];
                let var = (lag_j / 8.0).max(0.25);
                let diff = lag_k - lag_j;
                if diff * diff > 25.0 * var {
                    continue;
                }
                let s = v[j] - (diff * diff) / (2.0 * var);
                if s > best {
                    best = s;
                    best_j = j;
                }
            }
            nv[k] = emit + best;
            back[t][k] = best_j;
        }
        v = nv;
    }
    let mut k = 0usize;
    let mut best = f64::NEG_INFINITY;
    for i in 0..n_k {
        if v[i] > best {
            best = v[i];
            k = i;
        }
    }
    let mut path = vec![0usize; n_t];
    for t in (0..n_t).rev() {
        path[t] = k;
        k = back[t][k];
    }
    path
}

fn median_index(path: &[usize]) -> usize {
    if path.is_empty() {
        return 0;
    }
    let mut v = path.to_vec();
    v.sort_unstable();
    v[v.len() / 2]
}

fn parabolic_lag(acc: &[f64], lags: &[f64], around: usize) -> f64 {
    if lags.is_empty() || acc.len() != lags.len() {
        return 0.0;
    }
    let lo = around.saturating_sub(4);
    let hi = (around + 4).min(lags.len() - 1);
    let mut bi = around.min(lags.len() - 1);
    for j in lo..=hi {
        if acc[j] > acc[bi] {
            bi = j;
        }
    }
    let mut lag = lags[bi];
    if bi > 0 && bi + 1 < acc.len() {
        let (a, b, c) = (acc[bi - 1], acc[bi], acc[bi + 1]);
        let denom = a - 2.0 * b + c;
        if denom.abs() > 1e-18 {
            let step = lags[bi] - lags[bi - 1];
            lag += step * (0.5 * (a - c) / denom).clamp(-0.5, 0.5);
        }
    }
    lag.max(1.0)
}

/// Programación dinámica de Ellis, JNMR 2007. α = 680.
/// Transición −α (ln(Δt / τ))², buscando entre 0,5 τ y 2 τ.
/// La envolvente se suaviza con una gaussiana de ancho τ/32 y se
/// normaliza a media 1 para que α pese como en el paper.
fn ellis_beats(odf: &[f64], period: f64) -> Vec<usize> {
    let n = odf.len();
    if n < 16 || period < 2.0 {
        return Vec::new();
    }
    let sigma = (period / 32.0).max(0.5);
    let rad = (3.0 * sigma).ceil() as isize;
    let mut kernel = Vec::with_capacity((rad * 2 + 1) as usize);
    let mut ksum = 0.0;
    for d in -rad..=rad {
        let w = (-0.5 * (d as f64 / sigma).powi(2)).exp();
        kernel.push(w);
        ksum += w;
    }
    let mut local = vec![0.0; n];
    for i in 0..n {
        if i % CANCEL_BLOCK == 0 && cancel_now().is_err() {
            return Vec::new();
        }
        let mut s = 0.0;
        for (ki, &w) in kernel.iter().enumerate() {
            let j = i as isize + (ki as isize - rad);
            if j >= 0 {
                let j = j as usize;
                if j < n {
                    s += odf[j] * w;
                }
            }
        }
        local[i] = s / ksum;
    }
    let mean = local.iter().sum::<f64>() / n as f64;
    if mean > 1e-12 {
        for v in &mut local {
            *v /= mean;
        }
    }
    let alpha = 680.0f64;
    let lo = (period * 0.5).round().max(1.0) as usize;
    let hi = ((period * 2.0).round() as usize).max(lo + 1);
    let mut cum = vec![0.0f64; n];
    let mut back = vec![0usize; n];
    for i in 0..n {
        if i % CANCEL_BLOCK == 0 && cancel_now().is_err() {
            return Vec::new();
        }
        let j_hi = i.saturating_sub(lo);
        let j_lo = i.saturating_sub(hi);
        if i > hi && j_lo < j_hi {
            let mut best = f64::NEG_INFINITY;
            let mut best_j = i;
            for j in j_lo..j_hi {
                let dt = (i - j) as f64;
                let log_r = (dt / period).ln();
                let s = cum[j] - alpha * log_r * log_r;
                if s > best {
                    best = s;
                    best_j = j;
                }
            }
            cum[i] = local[i] + best;
            back[i] = best_j;
        } else {
            cum[i] = local[i];
            back[i] = i;
        }
    }
    let tail = n.saturating_sub(hi.max(1));
    let mut end = tail;
    let mut best_c = f64::NEG_INFINITY;
    for i in tail..n {
        if cum[i] > best_c {
            best_c = cum[i];
            end = i;
        }
    }
    let mut beats = Vec::new();
    let mut i = end;
    for _ in 0..n {
        beats.push(i);
        let j = back[i];
        if j >= i {
            break;
        }
        i = j;
    }
    beats.reverse();
    beats
}

/// El doble del peine, si pasa de 150, solo se queda con evidencia ≥ 1,7×.
fn apply_double_guard(comb: f64, chosen: f64, ratio: f64) -> f64 {
    let doubled = comb > 0.0 && (chosen - comb * 2.0).abs() <= (comb * 2.0).abs() * 1e-3;
    if chosen > 150.0 && doubled && ratio < 1.7 {
        comb
    } else {
        chosen
    }
}

/// 60,25 → 120,5 no pasa de 150. 180 no es el doble de un peine que ya vale 180.
/// Despacito (88,93 ×2) vuelve al peine si la evidencia no llega a 1,7.
fn guard_double_time(env: &[f64], env_rate: f64, comb: f64, chosen: f64) -> f64 {
    let doubled = comb > 0.0 && (chosen - comb * 2.0).abs() <= (comb * 2.0).abs() * 1e-3;
    if !(chosen > 150.0 && doubled) {
        return chosen;
    }
    let ev_c = crate::bpm_exact::onset_evidence(env, env_rate * 60.0 / comb);
    let ev_d = crate::bpm_exact::onset_evidence(env, env_rate * 60.0 / chosen);
    let ratio = if ev_c > 1e-12 {
        ev_d / ev_c
    } else if ev_d > 1e-12 {
        f64::INFINITY
    } else {
        0.0
    };
    apply_double_guard(comb, chosen, ratio)
}

/// TempoTrackV2 en limpio, desde los papers (qm-dsp es GPL; aquí no hay código suyo).
///
/// 1. Detección de onsets en el dominio complejo (Duxbury 2003 / Bello 2004).
/// 2. Autocorrelación insesgada por ventanas de 512 muestras (6 s) cada 128 (1,5 s).
/// 3. Banco de peines × Rayleigh con moda en 120 BPM.
/// 4. Viterbi de contexto (varianza τ/8) con prior del modelo general sobre la pieza.
/// 5. Beat tracking por programación dinámica (Ellis 2007, α = 680).
/// 6. Octava de visualización: ×2 o ÷2 solo para entrar en 60–180.
fn estimate_tempo_track(mono: &[f32], rate: u32) -> Option<f64> {
    estimate_tempo_in(mono, rate, TEMPO_DISPLAY_LO, TEMPO_DISPLAY_HI).map(|g| g.bpm)
}

fn estimate_tempo_in(
    mono: &[f32],
    rate: u32,
    display_lo: f64,
    display_hi: f64,
) -> Option<crate::bpm_exact::TempoGrid> {
    let debug = std::env::var_os("GMX_BPM_DEBUG").is_some();
    let (odf, env_rate) = complex_odf(mono, rate)?;
    // Inducción más ancha que la visualización, para que el peine vea el tactus
    // y sus armónicos. El plegado a 60–180 es aparte y solo usa ×2 / ÷2.
    let min_lag = (env_rate * 60.0 / 240.0).round().max(2.0) as usize;
    let max_lag = (env_rate * 60.0 / 40.0).round() as usize;
    if min_lag >= max_lag {
        return None;
    }
    // Medio frame: un lag entero puede caer más cerca del armónico lento que del tactus.
    let mut lags = Vec::new();
    let mut lag = min_lag as f64;
    while lag <= max_lag as f64 {
        lags.push(lag);
        lag += 0.5;
    }
    let n_win = 512usize;
    let hop_w = 128usize;
    let mut starts: Vec<usize> = Vec::new();
    if odf.len() <= n_win {
        if odf.len() > max_lag + 8 {
            starts.push(0);
        }
    } else {
        let mut s = 0usize;
        while s + n_win <= odf.len() {
            starts.push(s);
            s += hop_w;
        }
        let tail = odf.len() - n_win;
        if starts.last().copied() != Some(tail) {
            starts.push(tail);
        }
    }
    if starts.is_empty() {
        return None;
    }
    let mode = 0.5 * env_rate;
    let mut frames: Vec<Vec<f64>> = Vec::with_capacity(starts.len());
    let mut comb_acc = vec![0.0f64; lags.len()];
    for &s in &starts {
        if cancel_now().is_err() {
            return None;
        }
        let end = (s + n_win).min(odf.len());
        let frame = &odf[s..end];
        let ac_max = max_lag.saturating_mul(4).min(frame.len().saturating_sub(2));
        if ac_max <= min_lag {
            continue;
        }
        let ac = unbiased_acf(frame, ac_max);
        let mut row = vec![0.0; lags.len()];
        for (i, &lag) in lags.iter().enumerate() {
            let c = comb_score(&ac, lag).max(0.0);
            comb_acc[i] += c;
            row[i] = c * rayleigh_weight(lag, mode);
        }
        frames.push(row);
    }
    if frames.is_empty() {
        return None;
    }
    let mut acc = vec![0.0f64; lags.len()];
    for row in &frames {
        for (i, s) in row.iter().enumerate() {
            acc[i] += *s;
        }
    }
    let path = tempo_viterbi(&frames, &lags);
    if path.is_empty() || cancel_now().is_err() {
        return None;
    }
    let path_i = median_index(&path);
    let mut peak_i = 0usize;
    for i in 1..acc.len() {
        if acc[i] > acc[peak_i] {
            peak_i = i;
        }
    }
    // El modelo general (suma del peine × Rayleigh) elige el nivel métrico.
    // El Viterbi solo sigue un desvío de unos puntos; un salto de octava
    // en el camino logarítmico no pisa esa suma.
    let peak_bpm = 60.0 * env_rate / lags[peak_i].max(1.0);
    let path_bpm = 60.0 * env_rate / lags[path_i].max(1.0);
    let around = if (path_bpm - peak_bpm).abs() <= peak_bpm * 0.04 {
        path_i
    } else {
        peak_i
    };
    let lag = parabolic_lag(&acc, &lags, around);
    if lag < 1.0 {
        return None;
    }
    let coarse_raw = 60.0 * env_rate / lag;
    // El peine solo elige la octava. El número sale de la recta de los golpes.
    let coarse = fold_display_bpm(coarse_raw, display_lo, display_hi);
    if !(coarse.is_finite() && coarse > 0.0) {
        return None;
    }
    let (fine, fine_rate) = onset_envelope(mono, rate).unwrap_or((odf.clone(), env_rate));
    // ×2, ×1/2, ×4/3 y ×3/4 solo si superan al peine por más de 1,5×.
    // Por debajo de 75, ×1,5 (6/8, 12/8). No hay ×2 ahí: rompe 60,25 y 62.
    // Por encima de 150, el doble del peine solo se queda si la evidencia
    // llega a 1,7× (Despacito se queda en 88,93; Happy en 160 pasa).
    let chosen = crate::bpm_exact::choose_metric(&fine, fine_rate, coarse);
    let metric = crate::bpm_exact::fold_compound(
        &fine,
        fine_rate,
        guard_double_time(&fine, fine_rate, coarse, chosen),
    );
    // Un tono de 2 s no arma rejilla: evidencia baja y menos de 8 ventanas.
    // Una canción larga con peine claro pasa aunque la evidencia quede
    // entre 0,003 y 0,05 (Perfect, Shape of You).
    let evidence = crate::bpm_exact::onset_evidence(&fine, fine_rate * 60.0 / metric);
    let comb_peak = comb_acc.iter().copied().fold(0.0_f64, f64::max);
    let comb_mean = if comb_acc.is_empty() {
        0.0
    } else {
        comb_acc.iter().sum::<f64>() / comb_acc.len() as f64
    };
    if crate::bpm_exact::tempo_rejected(evidence, comb_peak, comb_mean, frames.len()) {
        return None;
    }
    let beats = ellis_beats(&fine, fine_rate * 60.0 / metric);
    if cancel_now().is_err() || beats.is_empty() {
        return None;
    }
    // Un seno de 2 s arma 4 golpes espurios en una sola ventana. Sin 8 golpes
    // y sin 8 ventanas no hay tempo (el test del tono puro sigue en blanco).
    if frames.len() < 8 && beats.len() < 8 {
        return None;
    }
    let grid = crate::bpm_exact::grid_from_onsets(&fine, &beats, fine_rate, metric)?;
    if debug {
        let mut order: Vec<usize> = (0..lags.len()).collect();
        order.sort_by(|&a, &b| {
            acc[b]
                .partial_cmp(&acc[a])
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let top: Vec<String> = order
            .into_iter()
            .take(6)
            .map(|i| format!("{:.1}:{:.3}", 60.0 * env_rate / lags[i], acc[i]))
            .collect();
        let mut order_c: Vec<usize> = (0..lags.len()).collect();
        order_c.sort_by(|&a, &b| {
            comb_acc[b]
                .partial_cmp(&comb_acc[a])
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let top_c: Vec<String> = order_c
            .into_iter()
            .take(6)
            .map(|i| format!("{:.1}:{:.3}", 60.0 * env_rate / lags[i], comb_acc[i]))
            .collect();
        eprintln!(
            "tempo qm rate {rate} env {env_rate:.4} odf {} wins {} top [{}] peine [{}] viterbi_lag {:.1} pico_lag {:.2} octava {coarse:.2} bpm {:.2} golpes {} tramos {}",
            odf.len(),
            starts.len(),
            top.join(" "),
            top_c.join(" "),
            lags.get(around).copied().unwrap_or(0.0),
            lag,
            grid.bpm,
            beats.len(),
            grid.segments.len()
        );
    }
    Some(grid)
}

/// BPM de toda la señal. La etiqueta previa no entra: el peine solo elige
/// la octava y la recta de los golpes da el número.
fn detect_bpm(mono: &[f32], rate: u32, prior: Option<f64>) -> Option<f64> {
    let _ = prior;
    estimate_tempo_track(mono, rate).and_then(fix_bpm_range)
}

fn measure_tempo_grid(mono: &[f32], rate: u32) -> Option<crate::bpm_exact::TempoGrid> {
    estimate_tempo_in(mono, rate, TEMPO_DISPLAY_LO, TEMPO_DISPLAY_HI)
}

/// Rejilla de golpes de un tramo: BPM medido y posición (ms absolutos en la
/// pista) de un golpe fuerte. Los demás golpes: `beat_ms + k * 60000 / bpm`.
pub struct BeatGrid {
    pub ok: bool,
    pub bpm: f64,
    pub beat_ms: f64,
}

/// Mide BPM y fase de golpes en `span_secs` segundos a partir de `from_ms`.
/// Sirve para que la mezcla de Live DJ entre "en el golpe" (no solo igualar BPM).
pub async fn beat_grid(input_path: String, from_ms: u64, span_secs: u32) -> BeatGrid {
    let none = BeatGrid {
        ok: false,
        bpm: 0.0,
        beat_ms: 0.0,
    };
    let d = match decode_channels(
        &input_path,
        (from_ms / 1000) as u32,
        span_secs.clamp(4, 30),
        2,
    ) {
        Ok(d) => d,
        Err(_) => return none,
    };
    let mono = to_mono(&d);
    let grid = match measure_tempo_grid(&mono, d.rate) {
        Some(g) if g.bpm > 40.0 && g.period_ms > 0.0 => g,
        _ => return none,
    };
    // El tramo medido usa su propia recta. Si hay deriva, el primer tramo
    // es el que cubre el inicio de la ventana.
    let (anchor_ms, bpm) = match grid.segments.first() {
        Some(seg) if seg.period_ms > 0.0 => (seg.anchor_ms, 60000.0 / seg.period_ms),
        _ => (grid.anchor_ms, grid.bpm),
    };
    BeatGrid {
        ok: true,
        bpm,
        beat_ms: d.start_ms as f64 + anchor_ms,
    }
}

struct Analysis {
    lufs: f64,
    peak: f64,
    lead_ms: u64,
    tail_ms: u64,
    grid: Option<crate::bpm_exact::TempoGrid>,
}

fn analyze_file(input_path: &str) -> Result<Analysis, String> {
    if !on_worker_thread() {
        let path = input_path.to_string();
        return run_on_master_worker(move || analyze_file(&path));
    }
    let _prio = PriorityGuard::enter();
    let _watch = CancelWatch::enter();
    cancel_now()?;
    let d = decode_channels(input_path, 0, MAX_ANALYZE_SECS, 2)?;
    let mut peak = 0.0f64;
    for c in &d.ch {
        for v in c {
            let a = (*v as f64).abs();
            if a > peak {
                peak = a;
            }
        }
    }
    let lufs = integrated_lufs(&d);
    let mono = to_mono(&d);
    let (lead_ms, tail_ms) = edge_silence_ms(&mono, d.rate);
    let grid = measure_tempo_grid(&mono, d.rate);
    Ok(Analysis {
        lufs,
        peak,
        lead_ms,
        tail_ms,
        grid,
    })
}

// ------------------------------------------------------------------ etiquetas

fn ext_text(tag: &Tag, key: &str) -> Option<String> {
    tag.extended_texts()
        .find(|e| e.description.eq_ignore_ascii_case(key))
        .map(|e| e.value.clone())
}

fn set_ext(tag: &mut Tag, key: &str, value: String) {
    tag.remove_extended_text(Some(key), None);
    tag.add_frame(ExtendedText {
        description: key.to_string(),
        value,
    });
}

fn num_from(s: &str) -> f64 {
    let t: String = s
        .chars()
        .filter(|c| c.is_ascii_digit() || *c == '.' || *c == '-')
        .collect();
    t.parse::<f64>().unwrap_or(0.0)
}

/// `173.12` con punto. Nunca `17312` ni `173,12`.
fn format_tbpm(bpm: f64) -> String {
    format!("{:.2}", bpm)
}

/// Número de un TBPM ya escrito.
///
/// `144`, `144.00`, espacios y nulos. La coma decimal (`146,70`) vale como
/// punto. Sin separador, un entero fuera de tempo que partido por 100 cae
/// en 40–250 es BPM×100 (`17312` = 173,12, `09548` = 95,48, `08635`, `08571`).
/// `144` se queda en 144.
fn parse_tbpm_text(raw: &str) -> Option<(f64, String)> {
    let token = raw
        .split('\0')
        .map(str::trim)
        .find(|s| !s.is_empty())?
        .trim_matches(|c: char| c == '\u{feff}' || c.is_whitespace());
    if token.is_empty() {
        return None;
    }
    let mut num = String::new();
    for c in token.chars() {
        if c.is_ascii_digit() || c == '.' || c == ',' || c == '-' {
            if c == ',' && num.contains('.') {
                break;
            }
            num.push(if c == ',' { '.' } else { c });
        } else if !num.is_empty() {
            break;
        }
    }
    let value: f64 = num.parse().ok()?;
    if !(value.is_finite() && value > 0.0) {
        return None;
    }
    let has_sep = token.contains('.') || token.contains(',');
    let value = if !has_sep && value > 300.0 {
        let scaled = value / 100.0;
        if (40.0..=250.0).contains(&scaled) {
            scaled
        } else {
            value
        }
    } else {
        value
    };
    Some((value, token.to_string()))
}

fn decode_tbpm_body(encoding: u8, body: &[u8]) -> Option<(f64, String)> {
    let text = match encoding {
        0 => body.iter().map(|b| *b as char).collect::<String>(),
        3 => String::from_utf8(body.to_vec()).ok()?,
        1 => {
            if body.len() < 2 {
                return None;
            }
            let (bom_le, data) = if body[0] == 0xFF && body[1] == 0xFE {
                (true, &body[2..])
            } else if body[0] == 0xFE && body[1] == 0xFF {
                (false, &body[2..])
            } else {
                (true, body)
            };
            utf16_units(data, bom_le)?
        }
        2 => utf16_units(body, false)?,
        _ => return None,
    };
    parse_tbpm_text(&text)
}

fn utf16_units(data: &[u8], little: bool) -> Option<String> {
    let mut units = Vec::with_capacity(data.len() / 2);
    for chunk in data.chunks_exact(2) {
        let u = if little {
            u16::from_le_bytes([chunk[0], chunk[1]])
        } else {
            u16::from_be_bytes([chunk[0], chunk[1]])
        };
        units.push(u);
    }
    String::from_utf16(&units).ok()
}

/// Frame TBPM (o TBP de v2.2) en un ID3v2.2/2.3/2.4, sin pasar por la crate.
fn tbpm_in_id3(data: &[u8]) -> Option<(f64, String)> {
    if data.len() < 10 || &data[0..3] != b"ID3" {
        return None;
    }
    let ver = data[3];
    if ver < 2 || ver > 4 {
        return None;
    }
    let mut pos = 10usize;
    let end = (10 + syncsafe_u32(&data[6..10])).min(data.len());
    if ver >= 3 && data[5] & 0x40 != 0 && pos + 4 <= end {
        let ext = if ver == 4 {
            syncsafe_u32(&data[pos..pos + 4])
        } else {
            u32::from_be_bytes(data[pos..pos + 4].try_into().ok()?) as usize
        };
        pos = pos.saturating_add(ext).min(end);
    }
    let hdr = if ver == 2 { 6 } else { 10 };
    while pos + hdr <= end {
        if data[pos] == 0 {
            break;
        }
        let (id, size) = if ver == 2 {
            let id = std::str::from_utf8(&data[pos..pos + 3]).ok()?;
            let size = ((data[pos + 3] as usize) << 16)
                | ((data[pos + 4] as usize) << 8)
                | data[pos + 5] as usize;
            (id, size)
        } else {
            let id = std::str::from_utf8(&data[pos..pos + 4]).ok()?;
            let size = if ver == 4 {
                syncsafe_u32(&data[pos + 4..pos + 8])
            } else {
                u32::from_be_bytes(data[pos + 4..pos + 8].try_into().ok()?) as usize
            };
            (id, size)
        };
        let body = pos + hdr;
        let body_end = body.saturating_add(size).min(end);
        if id == "TBPM" || id == "TBP" {
            if body + 1 <= body_end {
                return decode_tbpm_body(data[body], &data[body + 1..body_end]);
            }
            return None;
        }
        if size == 0 {
            break;
        }
        pos = body_end;
    }
    None
}

struct StoredBpm {
    value: f64,
    /// Texto original del frame. El medidor ya no lo copia: lo lee el test
    /// de parseo y quien inspecciona el tag.
    #[allow(dead_code)]
    token: String,
    /// El frame ya está cargado en el tag.
    #[allow(dead_code)]
    in_tag: bool,
}

/// TBPM que el archivo ya tiene. La crate primero; si no lo ve, los bytes.
fn stored_bpm(path: &str, tag: &Tag) -> Option<StoredBpm> {
    if let Some(text) = tag.get("TBPM").and_then(|f| f.content().text()) {
        if let Some((value, token)) = parse_tbpm_text(text) {
            return Some(StoredBpm {
                value,
                token,
                in_tag: true,
            });
        }
    }
    let data = std::fs::read(path).ok()?;
    let (value, token) = tbpm_in_id3(&data)?;
    Some(StoredBpm {
        value,
        token,
        in_tag: false,
    })
}

fn is_mp3(path: &str) -> bool {
    path.to_lowercase().ends_with(".mp3")
}

/// Lee lo que dejó el masterizado (sin decodificar). Sirve a Live DJ y Automix.
pub async fn read_master_tags(input_path: String) -> MasterTags {
    let empty = MasterTags {
        analyzed: false,
        gain_db: 0.0,
        lufs: 0.0,
        peak: 0.0,
        lead_ms: 0,
        tail_ms: 0,
        bpm: 0.0,
    };
    if !is_mp3(&input_path) {
        return empty;
    }
    let tag = match Tag::read_from_path(&input_path) {
        Ok(t) => t,
        Err(_) => return empty,
    };
    let bpm = stored_bpm(&input_path, &tag)
        .map(|s| s.value)
        .unwrap_or(0.0);
    if !is_mastered(&tag) {
        return MasterTags { bpm, ..empty };
    }
    MasterTags {
        analyzed: true,
        gain_db: ext_text(&tag, "REPLAYGAIN_TRACK_GAIN")
            .map(|s| num_from(&s))
            .unwrap_or(0.0),
        lufs: ext_any(&tag, KEY_LUFS, OLD_LUFS)
            .map(|s| num_from(&s))
            .unwrap_or(0.0),
        peak: ext_text(&tag, "REPLAYGAIN_TRACK_PEAK")
            .map(|s| num_from(&s))
            .unwrap_or(0.0),
        lead_ms: ext_any(&tag, KEY_LEAD, OLD_LEAD)
            .map(|s| num_from(&s) as u64)
            .unwrap_or(0),
        tail_ms: ext_any(&tag, KEY_TAIL, OLD_TAIL)
            .map(|s| num_from(&s) as u64)
            .unwrap_or(0),
        bpm,
    }
}

/// Analiza y guarda las etiquetas. `Ok(true)` = la pista queda analizada (o ya
/// lo estaba). `Ok(false)` = formato no soportado para etiquetas (no se sella).
fn analyze_and_tag(input_path: &str, force: bool) -> Result<bool, String> {
    if !Path::new(input_path).exists() {
        return Err("Archivo no encontrado en I/O.".to_string());
    }
    if !is_mp3(input_path) {
        return Ok(false);
    }
    let mut tag = Tag::read_from_path(input_path).unwrap_or_else(|_| Tag::new());
    if !force && is_mastered(&tag) && analysis_current(&tag) {
        return Ok(true);
    }
    if !force && is_mastered(&tag) {
        refresh_analysis_tags(input_path)?;
        return Ok(true);
    }
    let a = analyze_file(input_path)?;
    let gain = (RG_REFERENCE_LUFS - a.lufs).clamp(-24.0, 24.0);
    set_ext(&mut tag, "REPLAYGAIN_TRACK_GAIN", format!("{:.2} dB", gain));
    set_ext(&mut tag, "REPLAYGAIN_TRACK_PEAK", format!("{:.6}", a.peak));
    set_ext(&mut tag, KEY_LUFS, format!("{:.2}", a.lufs));
    set_ext(&mut tag, KEY_LEAD, a.lead_ms.to_string());
    set_ext(&mut tag, KEY_TAIL, a.tail_ms.to_string());
    if let Some(grid) = &a.grid {
        let old = stored_bpm(input_path, &tag).map(|s| s.value).unwrap_or(0.0);
        stamp_grid(&mut tag, grid, "FULL");
        let name = Path::new(input_path)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(input_path);
        eprintln!("BPM_FIX {name} {old:.2}->{:.2}", grid.bpm);
    }
    if let Ok(audio) = decoded_duration_ms(input_path) {
        write_measured_duration(&mut tag, audio);
    }
    set_ext(&mut tag, KEY_V, MASTER_VERSION.to_string());
    tag.write_to_path(input_path, Version::Id3v24)
        .map_err(|e| format!("Fallo I/O al guardar etiquetas: {}", e))?;
    Ok(true)
}

/// Masterizado de una pista: volumen + silencios + BPM, sin recodificar.
/// (Mismo nombre y firma que antes; ya no usa FFmpeg.)
pub async fn process_full_pipeline(input_path: String, is_megamix: bool) -> Result<bool, String> {
    if is_megamix {
        return Ok(true);
    }
    analyze_and_tag(&input_path, false)
}

/// Solo volumen (ReplayGain). Misma salida que `process_full_pipeline`.
pub async fn normalize_lufs(input_path: String) -> Result<bool, String> {
    analyze_and_tag(&input_path, false)
}

/// Solo silencios de inicio/fin (se guardan como cue, no se corta el archivo).
pub async fn process_auto_trim(input_path: String) -> Result<bool, String> {
    analyze_and_tag(&input_path, false)
}

pub async fn auto_detect_and_inject_bpm(input_path: String) -> Result<f64, String> {
    if !on_worker_thread() {
        return run_on_master_worker(move || auto_detect_body(input_path));
    }
    auto_detect_body(input_path)
}

fn auto_detect_body(input_path: String) -> Result<f64, String> {
    if !Path::new(&input_path).exists() {
        return Err("VETO I/O: Archivo no encontrado.".into());
    }
    let _prio = PriorityGuard::enter();
    let _watch = CancelWatch::enter();
    cancel_now()?;
    if is_mp3(&input_path) {
        return refresh_analysis_tags(&input_path);
    }
    let d = decode_channels(&input_path, 0, MAX_ANALYZE_SECS, 2)
        .map_err(|e| format!("Fallo DSP: {}", e))?;
    let grid = measure_tempo_grid(&to_mono(&d), d.rate)
        .ok_or("Anomalía determinista: Sin periodicidad".to_string())?;
    Ok(grid.bpm)
}

// --------------------------------------------------------------------- género

pub async fn read_audio_genre(input_path: String) -> String {
    let path = Path::new(&input_path);
    let path_str = path.to_string_lossy().to_lowercase();

    if path_str.contains("salsa") {
        return "salsa".to_string();
    }
    if path_str.contains("merengues") || path_str.contains("merengue") {
        return "merengue".to_string();
    }
    if path_str.contains("cumbias") || path_str.contains("cumbia") {
        return "cumbia".to_string();
    }
    if path_str.contains("nacional") {
        return "nacional".to_string();
    }
    if path_str.contains("vallenatos") || path_str.contains("vallenato") {
        return "vallenato".to_string();
    }
    if path_str.contains("guaracha") {
        return "guaracha".to_string();
    }
    if path_str.contains("80s") {
        return "80s".to_string();
    }
    if path_str.contains("rock") {
        return "rock".to_string();
    }
    if path_str.contains("baladas") || path_str.contains("balada") {
        return "balada".to_string();
    }
    if path_str.contains("española") || path_str.contains("espanola") {
        return "española".to_string();
    }
    if path_str.contains("bachatas") || path_str.contains("bachata") {
        return "bachata".to_string();
    }
    if path_str.contains("actualidad") {
        return "actualidad".to_string();
    }
    if path_str.contains("fiesta") {
        return "fiesta".to_string();
    }

    if let Ok(tag) = id3::Tag::read_from_path(path) {
        if let Some(genre) = tag.genre() {
            let genre_lower = genre.to_lowercase();
            if genre_lower.contains("salsa") {
                return "salsa".to_string();
            }
            if genre_lower.contains("merengue") {
                return "merengue".to_string();
            }
            if genre_lower.contains("cumbia") {
                return "cumbia".to_string();
            }
            if genre_lower.contains("rock") {
                return "rock".to_string();
            }
            if genre_lower.contains("electro")
                || genre_lower.contains("house")
                || genre_lower.contains("pop")
            {
                return "actualidad".to_string();
            }
            return genre_lower;
        }
    }
    "desconocido".to_string()
}

// --------------------------------------------------------------------- sello

pub async fn inject_watermark(input_path: String) -> Result<bool, String> {
    let path = std::path::Path::new(&input_path);
    if !path.exists() {
        return Err("File not found".to_string());
    }

    let mut tag = id3::Tag::read_from_path(path).unwrap_or_else(|_| id3::Tag::new());
    tag.remove_comment(None, Some(SEAL_TEXT));
    tag.add_frame(id3::frame::Comment {
        lang: "spa".to_string(),
        description: "".to_string(),
        text: SEAL_TEXT.to_string(),
    });

    match tag.write_to_path(path, id3::Version::Id3v24) {
        Ok(_) => Ok(true),
        Err(e) => Err(format!("Failed to write ID3 tag: {}", e)),
    }
}

pub async fn check_watermark(input_path: String) -> Result<bool, String> {
    let path = Path::new(&input_path);
    if !path.exists() {
        return Err("File not found".to_string());
    }

    if let Ok(tag) = id3::Tag::read_from_path(path) {
        if tag.comments().any(|c| c.text == SEAL_TEXT) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Reset de SONIDO: quita el sello y las etiquetas de masterizado (ReplayGain,
/// GMX_* y las DJS_* anteriores). No toca letras (.lrc) ni el resto de las etiquetas.
pub async fn clear_watermark(input_path: String) -> Result<bool, String> {
    let path = Path::new(&input_path);
    if !path.exists() {
        return Err("File not found".to_string());
    }
    if !is_mp3(&input_path) {
        return Ok(true);
    }
    let mut tag = match Tag::read_from_path(path) {
        Ok(t) => t,
        Err(_) => return Ok(true),
    };
    tag.remove_comment(None, Some(SEAL_TEXT));
    let legacy_m3 = format!("{}_M3", legacy_brand());
    let legacy_m3_v2 = format!("{}_M3_V2", legacy_brand());
    for key in [
        "REPLAYGAIN_TRACK_GAIN",
        "REPLAYGAIN_TRACK_PEAK",
        KEY_V,
        KEY_LUFS,
        KEY_LEAD,
        KEY_TAIL,
        OLD_V,
        OLD_LUFS,
        OLD_LEAD,
        OLD_TAIL,
        "GatoMix_M3",
        "GatoMix_M3_V2",
        legacy_m3.as_str(),
        legacy_m3_v2.as_str(),
        // El corte (GMX_TRIM_MS / GMX_TRIM_TAIL_MS), el shift y el respaldo
        // NO se borran: si se olvidan, la siguiente pasada cortaría otra vez.
        "GMX_LUFS_DONE",
        "GMX_BPM_OK",
        "GMX_BPM_SCOPE",
        "GMX_NAME_OK",
        "GMX_LYR",
        "GMX_LYR_START_MS",
        "GMX_K",
        "GMX_TYPE",
    ] {
        tag.remove_extended_text(Some(key), None);
    }
    tag.write_to_path(path, Version::Id3v24)
        .map_err(|e| format!("Fallo I/O: {}", e))?;
    Ok(true)
}

// ════════════════════════════════════════════════════════════════════════
//  CODIFICADOR MP3 (LAME) + SONDA DE OUTRO + GRABADOR MASTER-OUT
//  Todo en proceso: cero binarios externos en las 4 plataformas.
// ════════════════════════════════════════════════════════════════════════

fn lame_bitrate(kbps: u32) -> mp3lame_encoder::Bitrate {
    use mp3lame_encoder::Bitrate as B;
    match kbps {
        0..=96 => B::Kbps96,
        97..=128 => B::Kbps128,
        129..=160 => B::Kbps160,
        161..=192 => B::Kbps192,
        193..=256 => B::Kbps256,
        _ => B::Kbps320,
    }
}

/// Resampleo lineal con estado (continuo entre bloques).
struct Resampler {
    ratio: f64,
    pos: f64,
    last: (f32, f32),
    has_last: bool,
}

impl Resampler {
    fn new(from: u32, to: u32) -> Self {
        Resampler {
            ratio: from as f64 / to as f64,
            pos: 0.0,
            last: (0.0, 0.0),
            has_last: false,
        }
    }

    fn process(&mut self, input: &[(f32, f32)], out: &mut Vec<(f32, f32)>) {
        if input.is_empty() {
            return;
        }
        let mut seq: Vec<(f32, f32)> = Vec::with_capacity(input.len() + 1);
        if self.has_last {
            seq.push(self.last);
        }
        seq.extend_from_slice(input);
        while self.pos + 1.0 < seq.len() as f64 {
            let i = self.pos as usize;
            let f = (self.pos - i as f64) as f32;
            let a = seq[i];
            let b = seq[i + 1];
            out.push((a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f));
            self.pos += self.ratio;
        }
        self.pos -= (seq.len() - 1) as f64;
        self.last = seq[seq.len() - 1];
        self.has_last = true;
    }
}

/// Destino MP3: recibe PCM float entrelazado y escribe un MP3 CBR.
struct Mp3Sink {
    enc: mp3lame_encoder::Encoder,
    out: std::io::BufWriter<File>,
    stereo: bool,
    rs: Option<Resampler>,
}

fn dbg_err<E: std::fmt::Debug>(e: E) -> String {
    format!("{:?}", e)
}

impl Mp3Sink {
    fn new(path: &str, src_rate: u32, stereo: bool, kbps: u32) -> Result<Self, String> {
        Self::open(path, src_rate, stereo, lame_bitrate(kbps))
    }

    /// Igual que [new], pero nunca elige un bitrate POR ENCIMA del de origen.
    fn new_no_upsample(path: &str, src_rate: u32, stereo: bool, kbps: u32) -> Result<Self, String> {
        Self::open(path, src_rate, stereo, bitrate_at_most(kbps))
    }

    fn open(
        path: &str,
        src_rate: u32,
        stereo: bool,
        brate: mp3lame_encoder::Bitrate,
    ) -> Result<Self, String> {
        let rate = match src_rate {
            32000 | 44100 | 48000 => src_rate,
            r if r > 48000 && r % 48000 == 0 => 48000,
            _ => 44100,
        };
        let mut b = mp3lame_encoder::Builder::new().ok_or("No se pudo crear LAME")?;
        b.set_num_channels(if stereo { 2 } else { 1 })
            .map_err(dbg_err)?;
        b.set_sample_rate(rate).map_err(dbg_err)?;
        b.set_brate(brate).map_err(dbg_err)?;
        b.set_quality(mp3lame_encoder::Quality::Best)
            .map_err(dbg_err)?;
        // El primer frame queda reservado para el tag Info/LAME. Sin esto el
        // decodificador no sabe cuántas muestras de arranque saltarse.
        b.set_to_write_vbr_tag(true).map_err(dbg_err)?;
        let enc = b.build().map_err(dbg_err)?;
        if let Some(dir) = Path::new(path).parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let f = File::create(path).map_err(|e| e.to_string())?;
        Ok(Mp3Sink {
            enc,
            out: std::io::BufWriter::with_capacity(1 << 18, f),
            stereo,
            rs: if rate != src_rate {
                Some(Resampler::new(src_rate, rate))
            } else {
                None
            },
        })
    }

    /// `inter` = muestras entrelazadas con `src_ch` canales (se usan L y R).
    fn push(&mut self, inter: &[f32], src_ch: usize) -> Result<(), String> {
        use std::io::Write;
        let src_ch = src_ch.max(1);
        let mut frames: Vec<(f32, f32)> = Vec::with_capacity(inter.len() / src_ch);
        for fr in inter.chunks_exact(src_ch) {
            let l = fr[0];
            let r = if src_ch > 1 { fr[1] } else { l };
            frames.push((l, r));
        }
        let frames = match self.rs.as_mut() {
            Some(rs) => {
                let mut o = Vec::with_capacity(frames.len() + 8);
                rs.process(&frames, &mut o);
                o
            }
            None => frames,
        };
        if frames.is_empty() {
            return Ok(());
        }
        let q = |x: f32| (x.clamp(-1.0, 1.0) * 32767.0).round() as i16;
        let mut out: Vec<u8> = Vec::new();
        out.reserve(mp3lame_encoder::max_required_buffer_size(frames.len()));
        let n = if self.stereo {
            let mut pcm: Vec<i16> = Vec::with_capacity(frames.len() * 2);
            for (l, r) in &frames {
                pcm.push(q(*l));
                pcm.push(q(*r));
            }
            self.enc
                .encode(
                    mp3lame_encoder::InterleavedPcm(&pcm),
                    out.spare_capacity_mut(),
                )
                .map_err(dbg_err)?
        } else {
            let pcm: Vec<i16> = frames.iter().map(|(l, r)| q((*l + *r) * 0.5)).collect();
            self.enc
                .encode(mp3lame_encoder::MonoPcm(&pcm), out.spare_capacity_mut())
                .map_err(dbg_err)?
        };
        unsafe { out.set_len(n) };
        self.out.write_all(&out).map_err(|e| e.to_string())
    }

    /// Cierra el MP3 y reescribe el tag LAME/Info con el delay y el padding
    /// reales. libmpv (FFmpeg) se salta esas muestras: el audio decodificado
    /// no gana retardo. `residual_ms` es lo que quedaría si el reproductor
    /// ignorara el tag; con el tag escrito es 0.
    fn finish(mut self) -> Result<GaplessTag, String> {
        use std::io::{Seek, SeekFrom, Write};
        use std::mem::MaybeUninit;
        let mut tail: Vec<u8> = Vec::new();
        tail.reserve(16384);
        // FlushGap cuenta el padding final. FlushNoGap lo dejaba en cero y
        // el tag de arranque nunca se reescribía.
        let n = self
            .enc
            .flush::<mp3lame_encoder::FlushGap>(tail.spare_capacity_mut())
            .map_err(dbg_err)?;
        unsafe { tail.set_len(n) };
        self.out.write_all(&tail).map_err(|e| e.to_string())?;
        self.out.flush().map_err(|e| e.to_string())?;

        let tag_len = self.enc.lame_tag_size();
        if tag_len == 0 {
            return Err("LAME no reservó el tag gapless.".to_string());
        }
        let mut raw = vec![MaybeUninit::<u8>::uninit(); tag_len];
        let written = self
            .enc
            .lame_tag_encode(&mut raw)
            .ok_or("No se pudo armar el tag LAME")?;
        let nbytes = written.get();
        let tag: Vec<u8> = raw
            .into_iter()
            .take(nbytes)
            .map(|b| unsafe { b.assume_init() })
            .collect();
        let (delay, padding) =
            read_lame_delay_padding(&tag).ok_or("El tag LAME no trae delay ni padding")?;
        let file = self.out.get_mut();
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        file.write_all(&tag).map_err(|e| e.to_string())?;
        file.flush().map_err(|e| e.to_string())?;
        Ok(GaplessTag {
            delay_samples: delay,
            padding_samples: padding,
            // libmpv (FFmpeg) se salta `delay` muestras y el padding final.
            // Con el tag escrito el audio que suena no trae retardo extra.
            residual_ms: 0,
        })
    }
}

/// El test de alineación lee `delay_samples` y `padding_samples`.
#[allow(dead_code)]
struct GaplessTag {
    delay_samples: u32,
    padding_samples: u32,
    residual_ms: u32,
}

/// Delay y padding empaquetados por LAME, 3 bytes a 21 del texto "LAME".
/// El número sale del tag, no de una constante.
fn read_lame_delay_padding(buf: &[u8]) -> Option<(u32, u32)> {
    let pos = buf.windows(4).position(|w| w == b"LAME")?;
    let b = buf.get(pos + 21..pos + 24)?;
    let delay = ((b[0] as u32) << 4) + ((b[1] as u32) >> 4);
    let padding = ((b[1] as u32 & 0x0F) << 8) + b[2] as u32;
    if delay == 0 || delay > 3000 || padding > 3000 {
        return None;
    }
    Some((delay, padding))
}

/// Convierte CUALQUIER audio decodificable (m4a/AAC, MP3, FLAC, WAV, OGG…)
/// a MP3 CBR con LAME. `master` aplica el mismo corte y −14 LUFS que
/// Masterizar, en esta única codificación, y deja las marcas GMX. No escribe
/// el BPM: eso sigue en `master_rewrite`.
pub fn encode_to_mp3(
    input_path: String,
    output_path: String,
    bitrate_kbps: u32,
    master: bool,
) -> Result<bool, String> {
    if master {
        encode_mastered_mp3(&input_path, &output_path, bitrate_kbps)
    } else {
        encode_plain_mp3(input_path, output_path, bitrate_kbps)
    }
}

fn encode_plain_mp3(
    input_path: String,
    output_path: String,
    bitrate_kbps: u32,
) -> Result<bool, String> {
    let (mut format, track_id, params) = open_format(&input_path)?;
    let rate = params.sample_rate.ok_or("Sin frecuencia de muestreo")?;
    let mut decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .map_err(|e| format!("Códec no soportado: {e}"))?;

    let tmp = format!("{output_path}.part");
    let mut sink: Option<Mp3Sink> = None;
    let mut wrote = false;
    let res: Result<(), String> = (|| {
        loop {
            let packet = match format.next_packet() {
                Ok(p) => p,
                Err(_) => break,
            };
            if packet.track_id() != track_id {
                continue;
            }
            match decoder.decode(&packet) {
                Ok(decoded) => {
                    let spec = *decoded.spec();
                    let n_ch = spec.channels.count().max(1);
                    if sink.is_none() {
                        sink = Some(Mp3Sink::new(&tmp, rate, n_ch > 1, bitrate_kbps)?);
                    }
                    let mut buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
                    buf.copy_interleaved_ref(decoded);
                    sink.as_mut().unwrap().push(buf.samples(), n_ch)?;
                    wrote = true;
                }
                Err(SymError::DecodeError(_)) => continue,
                Err(_) => break,
            }
        }
        Ok(())
    })();
    let fin = match sink {
        Some(s) => s.finish().map(|_| ()),
        None => Err("Sin audio decodificable".to_string()),
    };
    if let Err(e) = res.and(fin) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    if !wrote {
        let _ = std::fs::remove_file(&tmp);
        return Err("Sin audio decodificable".to_string());
    }
    let _ = std::fs::remove_file(&output_path);
    std::fs::rename(&tmp, &output_path).map_err(|e| e.to_string())?;
    Ok(true)
}

/// AAC/M4A → MP3 con el corte y el −14 en la misma codificación LAME.
/// El bitrate es el que pidió Descargas (no el promedio del AAC). Sin TBPM:
/// Masterizar lo mide después, sin volver a codificar si las marcas ya están.
fn encode_mastered_mp3(input: &str, output: &str, kbps: u32) -> Result<bool, String> {
    let take = read_audio(input, true)?;
    let m = &take.measure;
    if blocking_decode_errors(m) > 0 {
        encode_plain_mp3(input.to_string(), output.to_string(), kbps)?;
        let mut tag = Tag::read_from_path(output).unwrap_or_else(|_| Tag::new());
        set_ext(
            &mut tag,
            KEY_REASON,
            format!("decode_errors={}", m.decode_errors),
        );
        set_ext(&mut tag, KEY_V, SCHEMA_V2.to_string());
        tag.write_to_path(output, Version::Id3v24)
            .map_err(|e| e.to_string())?;
        return Ok(true);
    }
    let plan = plan_span(m, true, true, -1, -1, 0.0);
    let tmp = format!("{output}.part");
    encode_master_span(
        &take.pcm,
        &tmp,
        m.rate,
        m.channels,
        m.samples,
        plan.head_s,
        plan.tail_s,
        plan.gain,
        plan.lufs_encode,
        kbps,
    )
    .map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e
    })?;
    let mut tag = Tag::new();
    set_ext(&mut tag, KEY_TRIM, plan.cut_head_ms.to_string());
    set_ext(&mut tag, KEY_TRIM_TAIL, plan.cut_tail_ms.to_string());
    set_ext(&mut tag, KEY_LEAD, plan.new_lead_ms.to_string());
    set_ext(&mut tag, KEY_TAIL, plan.new_tail_ms.to_string());
    if plan.lufs_encode || plan.lufs_seal {
        set_ext(&mut tag, KEY_LUFS, format!("{:.2}", plan.lufs));
        set_ext(&mut tag, KEY_LUFS_DONE, "-14".to_string());
    }
    if plan.lufs_encode {
        set_ext(&mut tag, "REPLAYGAIN_TRACK_GAIN", "-4.00 dB".to_string());
        set_ext(
            &mut tag,
            "REPLAYGAIN_TRACK_PEAK",
            format!("{TP_CEILING:.6}"),
        );
    }
    tag.remove_extended_text(Some(KEY_REASON), None);
    set_ext(&mut tag, KEY_V, SCHEMA_V2.to_string());
    tag.write_to_path(&tmp, Version::Id3v24).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e.to_string()
    })?;
    let _ = std::fs::remove_file(output);
    std::fs::rename(&tmp, output).map_err(|e| e.to_string())?;
    Ok(true)
}

// ════════════════════════════════════════════════════════════════════════
//  master_rewrite — recorte real + −14 LUFS en UNA codificación LAME.
//  Sin EQ. Silencio −50 dBFS. Cabeza: deja ~150 ms. Cola: fade 300 ms.
//  True peak −1 dBTP con limitador suave (look-ahead 5 ms).
//  Bitrate original, tope 320, nunca hacia arriba.
// ════════════════════════════════════════════════════════════════════════

const KEY_TYPE: &str = "GMX_TYPE";
const KEY_NAME_OK: &str = "GMX_NAME_OK";
const KEY_LYR: &str = "GMX_LYR";
const KEY_LYR_START: &str = "GMX_LYR_START_MS";
const KEY_LYR_CHECK: &str = "GMX_LYR_CHECK";
const KEY_TRIM: &str = "GMX_TRIM_MS";
const KEY_TRIM_TAIL: &str = "GMX_TRIM_TAIL_MS";
const KEY_LRC_SHIFT: &str = "GMX_LRC_SHIFT";
const KEY_BPM_OK: &str = "GMX_BPM_OK";
const KEY_BPM_SCOPE: &str = "GMX_BPM_SCOPE";
/// Versión del medidor de BPM, rejilla y duración. 3031 = recta de golpes.
const KEY_ANALYSIS: &str = "GMX_ANALYSIS";
const ANALYSIS_V: &str = "3031";
const KEY_GRID: &str = "GMX_GRID";
const KEY_LUFS_DONE: &str = "GMX_LUFS_DONE";
const KEY_K: &str = "GMX_K";
const KEY_BACKUP: &str = "GMX_BACKUP";
/// Motivo cuando el audio no se toca. Ej.: `decode_errors=3`.
const KEY_REASON: &str = "GMX_REASON";
/// Paquetes rotos tolerados (pocos) en una pasada que sí normalizó.
const KEY_DECODE_TOL: &str = "GMX_DECODE_TOL";
const SCHEMA_V2: &str = "2";
const TARGET_LUFS: f64 = -14.0;
const HEAD_KEEP_MS: u64 = 150;
const TAIL_FADE_MS: u64 = 300;
/// −1 dBTP. Por encima de esto el master vuelve a codificar.
const TP_CEILING: f32 = 0.8912509381337456;
/// Techo inicial del limitador (−2,5 dBFS). A 320 kbps el MP3 pasa
/// unos 1,5 dB del pico del PCM; −1,5 dBFS llegaba a −0,9 dBTP.
const TP_LIMIT: f32 = 0.7498942093324558;
/// No bajar el techo de aquí (−6 dBFS): por debajo el limitador aplasta.
const TP_LIMIT_FLOOR: f32 = 0.5011872336272722;
/// El LUFS medido al decodificar, y el del MP3 ya codificado, caen aquí.
const LUFS_TOL: f64 = 0.3;

/// Hay que recodificar el −14. La tolerancia para saltar es ±0,3. Un pico
/// por encima de −1 dBTP también obliga. Los frames dañados no entran.
fn lufs_encode_decision(do_lufs: bool, lufs: f64, peak: f32, decode_errors: u32) -> bool {
    let delta = ((TARGET_LUFS - lufs).abs() * 100.0).round() / 100.0;
    do_lufs && decode_errors == 0 && lufs >= -60.0 && (delta > LUFS_TOL || peak > TP_CEILING)
}

/// Audio perdido como máximo cuando se toleran paquetes rotos (1 s).
const DECODE_TOL_MAX_MS: u64 = 1000;
/// Y nunca más de 0,5 % de la duración decodificada (1/200).
const DECODE_TOL_FRACTION_DEN: u64 = 200;

/// Paquetes rotos que se pueden ignorar al normalizar. Cada paquete MP3
/// rechazado son 1152 muestras (~26 ms a 44,1 kHz) que el decodificador ya
/// salta: con pocos (p. ej. un primer frame basura) el −14 es seguro. Con
/// muchos (78, 200…) se perderían segundos de audio y la letra se correría:
/// el audio queda intacto y se marca `decode_errors=N`.
fn decode_errors_tolerable(errors: u32, samples: u64, rate: u32) -> bool {
    if errors == 0 {
        return true;
    }
    if rate == 0 || samples == 0 {
        return false;
    }
    let lost_ms = errors as u64 * 1152 * 1000 / rate as u64;
    let dur_ms = samples * 1000 / rate as u64;
    lost_ms <= DECODE_TOL_MAX_MS && lost_ms * DECODE_TOL_FRACTION_DEN <= dur_ms
}

/// Paquetes rotos (de reservorio) en el silencio de cabeza o cola.
fn count_silent_edge_errors(
    err_pos: &[(u64, bool)],
    first_loud: u64,
    has_loud: bool,
    last_loud: u64,
    guard: u64,
) -> u32 {
    err_pos
        .iter()
        .filter(|&&(p, reservoir)| {
            reservoir && (p <= first_loud || (has_loud && p >= last_loud + guard))
        })
        .count() as u32
}

/// Errores que bloquean el audio (0 si son tolerables).
fn blocking_decode_errors(m: &StreamMeasure) -> u32 {
    let inner = m.decode_errors.saturating_sub(m.silent_edge_errors);
    if decode_errors_tolerable(inner, m.samples, m.rate) {
        0
    } else {
        inner
    }
}

fn bitrate_at_most(kbps: u32) -> mp3lame_encoder::Bitrate {
    use mp3lame_encoder::Bitrate as B;
    // Hacia arriba, al peldaño MPEG que LAME escribe. El master no baja
    // del promedio de origen. Tope 320.
    match cap_kbps(kbps as f64) {
        32 => B::Kbps32,
        40 => B::Kbps40,
        48 => B::Kbps48,
        64 => B::Kbps64,
        80 => B::Kbps80,
        96 => B::Kbps96,
        112 => B::Kbps112,
        128 => B::Kbps128,
        160 => B::Kbps160,
        192 => B::Kbps192,
        224 => B::Kbps224,
        256 => B::Kbps256,
        _ => B::Kbps320,
    }
}

/// Misma curva K que `k_weight` (BS.1770), sample a sample.
fn k_stages(fs: f64) -> (Biquad, Biquad) {
    let pi = std::f64::consts::PI;
    let g = 3.999843853973347_f64;
    let q = 0.7071752369554196_f64;
    let fc = 1681.9744509555319_f64;
    let k = (pi * fc / fs).tan();
    let vh = 10f64.powf(g / 20.0);
    let vb = vh.powf(0.4996667741545416);
    let a0 = 1.0 + k / q + k * k;
    let s1 = Biquad {
        b: [
            (vh + vb * k / q + k * k) / a0,
            2.0 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
        ],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    let q2 = 0.5003270373238773_f64;
    let fc2 = 38.13547087602444_f64;
    let k2 = (pi * fc2 / fs).tan();
    let a02 = 1.0 + k2 / q2 + k2 * k2;
    let s2 = Biquad {
        b: [1.0, -2.0, 1.0],
        a: [2.0 * (k2 * k2 - 1.0) / a02, (1.0 - k2 / q2 + k2 * k2) / a02],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    (s1, s2)
}

fn k_one(s1: &mut Biquad, s2: &mut Biquad, x: f32) -> f64 {
    s2.tick(s1.tick(x as f64))
}

struct StreamMeasure {
    rate: u32,
    channels: usize,
    samples: u64,
    mono_ms: Vec<f32>,
    k_ms: Vec<f64>,
    /// Pico verdadero medido (4×). Por encima de −1 dBTP obliga a recodificar.
    true_peak: f32,
    /// Paquetes MP3 que el decodificador rechazó. >0: no se recodifica.
    decode_errors: u32,
    /// De esos, los que caen en el silencio de cabeza/cola (no bloquean).
    silent_edge_errors: u32,
}

/// −60 dBFS: umbral de "hay sonido" para clasificar errores de borde.
const EDGE_LOUD: f32 = 0.001;

fn consider_peak(hist: &mut [f32; 4], sample: f32, peak: &mut f32) {
    hist[0] = hist[1];
    hist[1] = hist[2];
    hist[2] = hist[3];
    hist[3] = sample;
    let (y0, y1, y2, y3) = (
        hist[0] as f64,
        hist[1] as f64,
        hist[2] as f64,
        hist[3] as f64,
    );
    *peak = peak.max(y1.abs() as f32).max(y2.abs() as f32);
    for t in [0.25_f64, 0.5, 0.75] {
        let t2 = t * t;
        let t3 = t2 * t;
        let v = 0.5
            * ((2.0 * y1)
                + (-y0 + y2) * t
                + (2.0 * y0 - 5.0 * y1 + 4.0 * y2 - y3) * t2
                + (-y0 + 3.0 * y1 - 3.0 * y2 + y3) * t3);
        *peak = peak.max(v.abs() as f32);
    }
}

/// Delay y padding que el reproductor (libmpv / FFmpeg) no hace sonar.
/// Cabeza: delay del tag LAME + 528 + 1 (retardo del decodificador MPEG-1
/// Layer III). Cola: padding del mismo tag. Sin tag, no se salta nada.
fn lame_player_skip(path: &str) -> (u64, u32) {
    let Ok(data) = std::fs::read(path) else {
        return (0, 0);
    };
    match read_lame_delay_padding(&data) {
        Some((delay, padding)) => (delay as u64 + 528 + 1, padding),
        None => (0, 0),
    }
}

/// Decodifica la pista. Devuelve cuántos paquetes se descartaron por
/// `DecodeError` (el audio de esos paquetes no entra en el PCM).
/// Con `gapless`, el PCM es el que suena: sin el priming ni el padding.
fn decode_frames(
    input_path: &str,
    gapless: bool,
    on_frame: impl FnMut(u32, usize, &[f32]) -> Result<(), String>,
) -> Result<u32, String> {
    let mut sink = Vec::new();
    decode_frames_ex(input_path, gapless, on_frame, &mut sink)
}

/// Igual que `decode_frames`, y anota en `err_pos` la posición (en frames
/// del PCM entregado) de cada paquete rechazado.
fn decode_frames_ex(
    input_path: &str,
    gapless: bool,
    mut on_frame: impl FnMut(u32, usize, &[f32]) -> Result<(), String>,
    err_pos: &mut Vec<(u64, bool)>,
) -> Result<u32, String> {
    let (mut format, track_id, params) = open_format(input_path)?;
    let rate = params.sample_rate.ok_or("Sin frecuencia de muestreo")?;
    let mut decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .map_err(|e| format!("Códec no soportado: {e}"))?;
    let (skip_head, skip_tail) = if gapless {
        lame_player_skip(input_path)
    } else {
        (0, 0)
    };
    let mut skipped = 0u32;
    let mut seen: u64 = 0;
    let mut width = 0usize;
    let mut hold: std::collections::VecDeque<f32> = std::collections::VecDeque::new();
    let mut since_check = 0usize;
    loop {
        // Cada paquete (MP3 ~1152, AAC 1024) es menos de 50 ms. Si un
        // paquete trajera un bloque enorme, se corta cada 8192 muestras.
        cancel_now()?;
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(_) => break,
        };
        if packet.track_id() != track_id {
            continue;
        }
        match decoder.decode(&packet) {
            Ok(decoded) => {
                let spec = *decoded.spec();
                let n_ch = spec.channels.count().max(1);
                let mut buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
                buf.copy_interleaved_ref(decoded);
                if width == 0 {
                    width = n_ch;
                }
                let tail_samples = skip_tail as usize * width.max(1);
                let mut emit: Vec<f32> = Vec::new();
                for frame in buf.samples().chunks(n_ch) {
                    if seen < skip_head {
                        seen += 1;
                        continue;
                    }
                    seen += 1;
                    since_check += 1;
                    if since_check >= CANCEL_BLOCK {
                        since_check = 0;
                        cancel_now()?;
                    }
                    if tail_samples > 0 {
                        hold.extend(frame.iter().copied());
                        while hold.len() > tail_samples {
                            for _ in 0..width {
                                if let Some(s) = hold.pop_front() {
                                    emit.push(s);
                                }
                            }
                        }
                    } else {
                        emit.extend_from_slice(frame);
                    }
                }
                if !emit.is_empty() {
                    on_frame(rate, n_ch, &emit)?;
                }
            }
            Err(SymError::DecodeError(msg)) => {
                skipped += 1;
                // Solo "main_data offset" es el reservorio de bits sin datos
                // previos (típico de frames de silencio); lo demás es basura.
                let reservoir = msg.contains("main_data");
                err_pos.push((seen.saturating_sub(skip_head), reservoir));
                continue;
            }
            Err(_) => break,
        }
    }
    Ok(skipped)
}

fn measure_stream(input_path: &str) -> Result<StreamMeasure, String> {
    Ok(read_audio(input_path, false)?.measure)
}

struct AudioTake {
    measure: StreamMeasure,
    /// PCM entrelazado (los mismos frames que midió `measure`). Vacío si
    /// no se pidió guardarlo.
    pcm: Vec<f32>,
}

/// Una pasada: decodifica, mide sonoridad y silencios, y opcionalmente
/// se queda el PCM para codificar y medir el BPM sin volver a abrir el archivo.
fn read_audio(input_path: &str, keep_pcm: bool) -> Result<AudioTake, String> {
    let mut rate = 0u32;
    let mut channels = 1usize;
    let mut samples = 0u64;
    let mut mono_ms: Vec<f32> = Vec::new();
    let mut k_ms: Vec<f64> = Vec::new();
    let mut acc_m = 0.0f64;
    let mut acc_k = 0.0f64;
    let mut acc_n = 0usize;
    let mut win = 1usize;
    let mut filt: Option<(Biquad, Biquad, Biquad, Biquad)> = None;
    let mut peak = 0.0f32;
    let mut hl = [0f32; 4];
    let mut hr = [0f32; 4];
    let mut pcm: Vec<f32> = Vec::new();

    let mut err_pos: Vec<(u64, bool)> = Vec::new();
    let mut first_loud: Option<u64> = None;
    let mut last_loud: u64 = 0;
    let decode_errors = decode_frames_ex(
        input_path,
        true,
        |r, nch, inter| {
            if filt.is_none() {
                rate = r;
                channels = nch.max(1);
                win = (r as usize / 100).max(1);
                let (a, b) = k_stages(r as f64);
                let (c, d) = k_stages(r as f64);
                filt = Some((a, b, c, d));
            }
            if keep_pcm {
                pcm.extend_from_slice(inter);
            }
            let (s1l, s2l, s1r, s2r) = filt.as_mut().unwrap();
            let nch = nch.max(1);
            for frame in inter.chunks(nch) {
                let l = frame[0];
                let rgt = if nch > 1 { frame[1] } else { l };
                let mono = (l as f64 + rgt as f64) * 0.5;
                if l.abs() > EDGE_LOUD || rgt.abs() > EDGE_LOUD {
                    if first_loud.is_none() {
                        first_loud = Some(samples);
                    }
                    last_loud = samples;
                }
                acc_m += mono * mono;
                let kl = k_one(s1l, s2l, l);
                let kr = if nch > 1 { k_one(s1r, s2r, rgt) } else { kl };
                acc_k += kl * kl + kr * kr;
                consider_peak(&mut hl, l, &mut peak);
                if nch > 1 {
                    consider_peak(&mut hr, rgt, &mut peak);
                }
                acc_n += 1;
                samples += 1;
                if acc_n >= win {
                    mono_ms.push((acc_m / acc_n as f64) as f32);
                    k_ms.push(acc_k / acc_n as f64);
                    acc_m = 0.0;
                    acc_k = 0.0;
                    acc_n = 0;
                }
            }
            Ok(())
        },
        &mut err_pos,
    )?;
    if samples == 0 || rate == 0 {
        return Err("Sin audio decodificable".to_string());
    }
    // Paquetes rechazados dentro del silencio digital de la cabeza o de la
    // cola (antes del primer / después del último sonido > −60 dBFS): suelen
    // ser frames de relleno con reservorio inválido. No se oyen y el corte
    // los quita; no deben bloquear el −14.
    // Cola: además el sonido tuvo que acabar ≥ 250 ms antes del error (la
    // pista ya se había apagado), para no perdonar un corte en plena música.
    let fl = first_loud.unwrap_or(u64::MAX);
    let guard = rate as u64 / 4;
    let silent_edge_errors =
        count_silent_edge_errors(&err_pos, fl, first_loud.is_some(), last_loud, guard);
    let width = channels.max(1);
    if keep_pcm && pcm.len() != samples as usize * width {
        return Err("El PCM no coincide con el conteo de muestras.".to_string());
    }
    if !keep_pcm {
        pcm.clear();
    }
    Ok(AudioTake {
        measure: StreamMeasure {
            rate,
            channels,
            samples,
            mono_ms,
            k_ms,
            true_peak: peak,
            decode_errors,
            silent_edge_errors,
        },
        pcm,
    })
}

fn edges_from(mono_ms: &[f32]) -> (u64, u64) {
    let thr = 10f64.powf(-50.0 / 20.0);
    let thr2 = (thr * thr) as f32;
    let n = mono_ms.len();
    if n < 10 {
        return (0, 0);
    }
    let loud = |i: usize| mono_ms[i] > thr2;
    let first = (0..n).find(|i| loud(*i));
    let last = (0..n).rev().find(|i| loud(*i));
    match (first, last) {
        (Some(f), Some(l)) => ((f as u64) * 10, ((n - 1 - l) as u64) * 10),
        _ => (0, 0),
    }
}

fn lufs_of(k_ms: &[f64]) -> f64 {
    if k_ms.len() < 40 {
        return -70.0;
    }
    let mut zs: Vec<f64> = Vec::new();
    let mut i = 0usize;
    while i + 40 <= k_ms.len() {
        let z = k_ms[i..i + 40].iter().sum::<f64>() / 40.0;
        zs.push(z);
        i += 10;
    }
    let lk = |z: f64| -0.691 + 10.0 * z.max(1e-12).log10();
    let abs: Vec<f64> = zs.into_iter().filter(|z| lk(*z) > -70.0).collect();
    if abs.is_empty() {
        return -70.0;
    }
    let mean = abs.iter().sum::<f64>() / abs.len() as f64;
    let rel_thr = lk(mean) - 10.0;
    let rel: Vec<f64> = abs.into_iter().filter(|z| lk(*z) > rel_thr).collect();
    if rel.is_empty() {
        return lk(mean);
    }
    lk(rel.iter().sum::<f64>() / rel.len() as f64)
}

fn ms_to_samples(ms: u64, rate: u32) -> u64 {
    ms.saturating_mul(rate as u64) / 1000
}

/// 60–200. ×100 de un ID3 (11499 → 114.99) antes de doblar o partir.
fn fix_bpm_range(bpm: f64) -> Option<f64> {
    if !bpm.is_finite() || bpm <= 0.0 {
        return None;
    }
    let mut b = bpm;
    if b > 300.0 {
        let scaled = b / 100.0;
        if (60.0..=200.0).contains(&scaled) {
            b = scaled;
        }
    }
    for _ in 0..6 {
        if b > 200.0 && b / 2.0 >= 60.0 {
            b /= 2.0;
        } else if b < 60.0 && b * 2.0 <= 200.0 {
            b *= 2.0;
        } else {
            break;
        }
    }
    if (60.0..=200.0).contains(&b) {
        Some((b * 100.0).round() / 100.0)
    } else {
        None
    }
}

/// El medido gana. La etiqueta previa no se confirma ni se conserva como
/// resultado: si no hay medición, no hay BPM nuevo (0 = no escribir).
fn resolve_bpm(measured: Option<f64>, _existing: f64) -> f64 {
    match measured {
        Some(b) if b.is_finite() && b > 0.0 => (b * 100.0).round() / 100.0,
        _ => 0.0,
    }
}

fn analysis_current(tag: &Tag) -> bool {
    ext_text(tag, KEY_ANALYSIS).as_deref() == Some(ANALYSIS_V)
}

/// Audio ya masterizado: hay corte decidido y el −14 está sellado.
fn audio_mastered(tag: &Tag) -> bool {
    ext_text(tag, KEY_TRIM).is_some() && ext_text(tag, KEY_LUFS_DONE).as_deref() == Some("-14")
}

fn stamp_grid(tag: &mut Tag, grid: &crate::bpm_exact::TempoGrid, scope: &str) {
    tag.set_text("TBPM", format_tbpm(grid.bpm));
    set_ext(tag, KEY_GRID, crate::bpm_exact::encode_grid(grid));
    set_ext(tag, KEY_BPM_OK, "1".to_string());
    set_ext(tag, KEY_BPM_SCOPE, scope.to_string());
    set_ext(tag, KEY_ANALYSIS, ANALYSIS_V.to_string());
}

fn write_measured_duration(tag: &mut Tag, audio_ms: u64) {
    if audio_ms == 0 {
        return;
    }
    let prev = tag.duration().map(|d| d as u64);
    if prev == Some(audio_ms) {
        return;
    }
    tag.set_duration(audio_ms as u32);
    if let Some(value) = len_mismatch_value(prev, audio_ms) {
        set_ext(tag, "GMX_LEN_MISMATCH", value);
    }
}

/// BPM + rejilla + TLEN. No recodifica. Si la versión ya es la actual, no abre el audio.
fn refresh_analysis_tags(path: &str) -> Result<f64, String> {
    if !on_worker_thread() {
        let owned = path.to_string();
        return run_on_master_worker(move || refresh_analysis_tags(&owned));
    }
    if !Path::new(path).exists() {
        return Err("Archivo no encontrado en I/O.".to_string());
    }
    if !is_mp3(path) {
        return Err("Solo MP3.".to_string());
    }
    let mut tag = Tag::read_from_path(path).unwrap_or_else(|_| Tag::new());
    let old = stored_bpm(path, &tag).map(|s| s.value).unwrap_or(0.0);
    // Versión actual con BPM ya escrito: no se abre el audio. BPM 0 (o
    // ausente) se vuelve a medir aunque GMX_ANALYSIS esté al día.
    if analysis_current(&tag) && old > 0.0 {
        return Ok(old);
    }
    let audio = decoded_duration_ms(path)?;
    let grid = measure_path_grid(path, false).ok_or("Sin periodicidad".to_string())?;
    stamp_grid(&mut tag, &grid, "FULL");
    write_measured_duration(&mut tag, audio);
    tag.write_to_path(path, Version::Id3v24)
        .map_err(|e| format!("Fallo I/O al guardar etiquetas: {e}"))?;
    let name = Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(path);
    eprintln!("BPM_FIX {name} {old:.2}->{:.2}", grid.bpm);
    Ok(grid.bpm)
}

fn measure_path_grid(path: &str, intro: bool) -> Option<crate::bpm_exact::TempoGrid> {
    let span = if intro { 60u32 } else { MAX_ANALYZE_SECS };
    let d = decode_channels(path, 0, span, 2).ok()?;
    measure_tempo_grid(&to_mono(&d), d.rate)
}

/// BPM del PCM ya decodificado, en el tramo que se conserva (sin reabrir el archivo).
fn grid_from_pcm(
    pcm: &[f32],
    channels: usize,
    rate: u32,
    head: u64,
    tail: u64,
    intro: bool,
) -> Option<crate::bpm_exact::TempoGrid> {
    let nch = channels.max(1);
    if rate == 0 || pcm.len() < nch {
        return None;
    }
    let frames = pcm.len() / nch;
    let end = frames.saturating_sub(tail as usize);
    let start = (head as usize).min(end);
    let cap = if intro {
        rate as usize * 60
    } else {
        rate as usize * MAX_ANALYZE_SECS as usize
    };
    let stop = end.min(start.saturating_add(cap));
    if stop <= start {
        return None;
    }
    let mut mono = Vec::with_capacity(stop - start);
    for i in start..stop {
        let base = i * nch;
        let mut s = 0.0f32;
        for c in 0..nch {
            s += pcm.get(base + c).copied().unwrap_or(0.0);
        }
        mono.push(s / nch as f32);
    }
    measure_tempo_grid(&mono, rate)
}

fn rewrite_from_tags(tag: &Tag, bpm: f64) -> MasterRewrite {
    MasterRewrite {
        trim_head_ms: 0,
        trim_tail_ms: 0,
        lead_ms: ext_text(tag, KEY_LEAD)
            .map(|s| num_from(&s) as u32)
            .unwrap_or(0),
        tail_ms: ext_text(tag, KEY_TAIL)
            .map(|s| num_from(&s) as u32)
            .unwrap_or(0),
        bpm,
        lufs: ext_text(tag, KEY_LUFS).map(|s| num_from(&s)).unwrap_or(0.0),
        lufs_applied: false,
        bitrate_kbps: 0,
        rewritten: false,
        residual_ms: 0,
    }
}

fn syncsafe_u32(b: &[u8]) -> usize {
    ((b[0] as usize & 0x7f) << 21)
        | ((b[1] as usize & 0x7f) << 14)
        | ((b[2] as usize & 0x7f) << 7)
        | (b[3] as usize & 0x7f)
}

fn id3v2_prefix_len(data: &[u8]) -> usize {
    if data.len() < 10 || &data[0..3] != b"ID3" {
        return 0;
    }
    let mut n = 10 + syncsafe_u32(&data[6..10]);
    if data[5] & 0x10 != 0 {
        n += 10;
    }
    if n > data.len() {
        0
    } else {
        n
    }
}

fn ape_suffix_len(data: &[u8], end: usize) -> usize {
    if end < 32 || end > data.len() {
        return 0;
    }
    let f = end - 32;
    if &data[f..f + 8] != b"APETAGEX" {
        return 0;
    }
    let size = u32::from_le_bytes(data[f + 12..f + 16].try_into().unwrap_or([0; 4])) as usize;
    let flags = u32::from_le_bytes(data[f + 20..f + 24].try_into().unwrap_or([0; 4]));
    let mut n = size;
    if flags & 0x8000_0000 != 0 {
        n += 32;
    }
    if n == 0 || n > end {
        0
    } else {
        n
    }
}

/// Inicio y fin (exclusivo) de los bytes de audio: fuera quedan ID3v2, ID3v1 y APE.
fn audio_byte_range(data: &[u8]) -> (usize, usize) {
    let mut start = id3v2_prefix_len(data);
    let mut end = data.len();
    if end.saturating_sub(start) >= 128 && &data[end - 128..end - 125] == b"TAG" {
        end -= 128;
    }
    end = end.saturating_sub(ape_suffix_len(data, end));
    if start > end {
        start = end;
    }
    (start, end)
}

fn kbps_of_audio(audio_len: u64, samples: u64, rate: u32) -> u32 {
    if samples == 0 || rate == 0 || audio_len == 0 {
        return 128;
    }
    let secs = samples as f64 / rate as f64;
    if secs < 0.4 {
        return 128;
    }
    ((audio_len as f64 * 8.0) / secs / 1000.0).round() as u32
}

/// Promedio exacto en kbps: (bytes de audio × 8) / duración.
fn kbps_exact(audio_len: u64, samples: u64, rate: u32) -> f64 {
    if samples == 0 || rate == 0 || audio_len == 0 {
        return 128.0;
    }
    let secs = samples as f64 / rate as f64;
    if secs < 0.4 {
        return 128.0;
    }
    (audio_len as f64 * 8.0) / secs / 1000.0
}

/// Peldaños MPEG-1 Layer III que LAME puede escribir. Sin 56: el enum no lo tiene.
const MPEG_KBPS: [u32; 13] = [32, 40, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];

/// Al peldaño siguiente, nunca por debajo. Tope 320.
fn round_up_mpeg_kbps(kbps: f64) -> u32 {
    if !kbps.is_finite() || kbps <= 0.0 {
        return 128;
    }
    for &step in &MPEG_KBPS {
        if (step as f64) + 1e-6 >= kbps {
            return step;
        }
    }
    320
}

fn cap_kbps(avg_kbps: f64) -> u32 {
    round_up_mpeg_kbps(avg_kbps).min(320)
}

/// Bytes que declara Xing/Info o VBRI, si el primer frame los trae.
fn vbr_header_bytes(audio: &[u8]) -> Option<u64> {
    let last = audio.len().saturating_sub(4).min(8192);
    let mut i = 0usize;
    while i < last {
        if audio[i] == 0xFF && audio[i + 1] & 0xE0 == 0xE0 {
            let ver = (audio[i + 1] >> 3) & 0x03;
            let layer = (audio[i + 1] >> 1) & 0x03;
            let br = (audio[i + 2] >> 4) & 0x0F;
            if ver != 0x01 && layer == 0x01 && br != 0 && br != 0x0F {
                return xing_or_vbri_bytes(audio, i);
            }
        }
        i += 1;
    }
    None
}

fn xing_or_vbri_bytes(audio: &[u8], off: usize) -> Option<u64> {
    if off + 4 > audio.len() {
        return None;
    }
    let ver = (audio[off + 1] >> 3) & 0x03;
    let mono = (audio[off + 3] >> 6) & 0x03 == 0x03;
    let side = if ver == 0x03 {
        if mono {
            17
        } else {
            32
        }
    } else if mono {
        9
    } else {
        17
    };
    let xing_at = off + 4 + side;
    if audio.len() >= xing_at + 16
        && (&audio[xing_at..xing_at + 4] == b"Xing" || &audio[xing_at..xing_at + 4] == b"Info")
    {
        let flags = u32::from_be_bytes(audio[xing_at + 4..xing_at + 8].try_into().ok()?);
        let mut p = xing_at + 8;
        if flags & 0x01 != 0 {
            p += 4;
        }
        if flags & 0x02 != 0 && audio.len() >= p + 4 {
            let bytes = u32::from_be_bytes(audio[p..p + 4].try_into().ok()?);
            if bytes > 0 {
                return Some(bytes as u64);
            }
        }
    }
    let vbri_at = off + 36;
    if audio.len() >= vbri_at + 14 && &audio[vbri_at..vbri_at + 4] == b"VBRI" {
        let bytes = u32::from_be_bytes(audio[vbri_at + 10..vbri_at + 14].try_into().ok()?);
        if bytes > 0 {
            return Some(bytes as u64);
        }
    }
    None
}

fn average_from_audio(audio: &[u8], samples: u64, rate: u32) -> u32 {
    let bytes = vbr_header_bytes(audio).unwrap_or(audio.len() as u64);
    cap_kbps(kbps_exact(bytes, samples, rate))
}

/// Bitrate del primer frame MPEG válido (CBR del codec). No mira el tamaño del archivo.
fn mpeg_bitrate_kbps(audio: &[u8]) -> Option<u32> {
    const V1_L3: [u32; 16] = [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
    ];
    const V2_L3: [u32; 16] = [
        0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
    ];
    let last = audio.len().saturating_sub(4).min(8192);
    let mut i = 0usize;
    while i < last {
        if audio[i] == 0xFF && audio[i + 1] & 0xE0 == 0xE0 {
            let ver = (audio[i + 1] >> 3) & 0x03;
            let layer = (audio[i + 1] >> 1) & 0x03;
            let br = (audio[i + 2] >> 4) & 0x0F;
            if ver != 0x01 && layer == 0x01 && br != 0 && br != 0x0F {
                let table = if ver == 0x03 { &V1_L3 } else { &V2_L3 };
                let kbps = table[br as usize];
                if kbps > 0 {
                    return Some(kbps);
                }
            }
        }
        i += 1;
    }
    None
}

fn average_kbps(path: &str, samples: u64, rate: u32) -> u32 {
    let data = match std::fs::read(path) {
        Ok(d) if !d.is_empty() => d,
        _ => return 128,
    };
    let (start, end) = audio_byte_range(&data);
    if start >= end {
        return 128;
    }
    average_from_audio(&data[start..end], samples, rate)
}

struct LookLim {
    n: usize,
    gain: f32,
    att: f32,
    rel: f32,
    ceiling: f32,
    bl: std::collections::VecDeque<f32>,
    br: std::collections::VecDeque<f32>,
    hl: [f32; 4],
    hr: [f32; 4],
    /// (índice, pico interpolado de esa muestra). El frente es el máximo.
    maxq: std::collections::VecDeque<(u64, f32)>,
    seq: u64,
}

/// Pico interpolado de UNA muestra (la misma cuenta que un paso de `consider_peak`).
fn interp_peak(hist: &mut [f32; 4], sample: f32) -> f32 {
    hist[0] = hist[1];
    hist[1] = hist[2];
    hist[2] = hist[3];
    hist[3] = sample;
    let (y0, y1, y2, y3) = (
        hist[0] as f64,
        hist[1] as f64,
        hist[2] as f64,
        hist[3] as f64,
    );
    let mut peak = (y1.abs() as f32).max(y2.abs() as f32);
    for t in [0.25_f64, 0.5, 0.75] {
        let t2 = t * t;
        let t3 = t2 * t;
        let v = 0.5
            * ((2.0 * y1)
                + (-y0 + y2) * t
                + (2.0 * y0 - 5.0 * y1 + 4.0 * y2 - y3) * t2
                + (-y0 + 3.0 * y1 - 3.0 * y2 + y3) * t3);
        peak = peak.max(v.abs() as f32);
    }
    peak
}

/// Las 3 primeras muestras del buffer se interpolan contra ceros (el escaneo
/// viejo reiniciaba el historial). El resto ya quedó medido al entrar.
fn edge_true_peak(buf: &std::collections::VecDeque<f32>) -> f32 {
    let mut hist = [0f32; 4];
    let mut peak = 0.0f32;
    let n = buf.len().min(3);
    for i in 0..n {
        let s = buf.get(i).copied().unwrap_or(0.0);
        peak = peak.max(interp_peak(&mut hist, s));
    }
    peak
}

impl LookLim {
    fn new(rate: u32, ceiling: f32) -> Self {
        let n = ((rate as usize) * 5 / 1000).max(8);
        let att = 1.0 - (-1.0_f32 / (0.001 * rate as f32)).exp();
        let rel = 1.0 - (-1.0_f32 / (0.080 * rate as f32)).exp();
        Self {
            n,
            gain: 1.0,
            att,
            rel,
            ceiling,
            bl: std::collections::VecDeque::new(),
            br: std::collections::VecDeque::new(),
            hl: [0.0; 4],
            hr: [0.0; 4],
            maxq: std::collections::VecDeque::new(),
            seq: 0,
        }
    }

    fn push(&mut self, l: f32, r: f32) -> Option<(f32, f32)> {
        self.bl.push_back(l);
        self.br.push_back(r);
        let p = interp_peak(&mut self.hl, l).max(interp_peak(&mut self.hr, r));
        let idx = self.seq;
        self.seq += 1;
        while self.maxq.back().map(|(_, v)| *v <= p).unwrap_or(false) {
            self.maxq.pop_back();
        }
        self.maxq.push_back((idx, p));
        if self.bl.len() <= self.n {
            return None;
        }
        let len = self.bl.len() as u64;
        let oldest = self.seq - len;
        let stable_from = oldest + 3;
        while self
            .maxq
            .front()
            .map(|(i, _)| *i < stable_from)
            .unwrap_or(false)
        {
            self.maxq.pop_front();
        }
        let peak = self
            .maxq
            .front()
            .map(|(_, v)| *v)
            .unwrap_or(0.0)
            .max(edge_true_peak(&self.bl))
            .max(edge_true_peak(&self.br));
        let target = if peak > self.ceiling {
            self.ceiling / peak
        } else {
            1.0
        };
        let c = if target < self.gain {
            self.att
        } else {
            self.rel
        };
        self.gain += (target - self.gain) * c;
        Some((
            self.bl.pop_front().unwrap_or(0.0) * self.gain,
            self.br.pop_front().unwrap_or(0.0) * self.gain,
        ))
    }

    fn flush(mut self) -> Vec<(f32, f32)> {
        let mut o = Vec::with_capacity(self.bl.len());
        while let Some(l) = self.bl.pop_front() {
            let r = self.br.pop_front().unwrap_or(l);
            o.push((l * self.gain, r * self.gain));
        }
        o
    }
}

fn gain_for(lufs: f64, do_lufs: bool) -> f32 {
    if !do_lufs || lufs < -60.0 {
        return 1.0;
    }
    let db = (TARGET_LUFS - lufs).clamp(-24.0, 24.0);
    10f32.powf((db / 20.0) as f32)
}

struct EncodeTimes {
    limit_ms: u128,
    encode_ms: u128,
    verify_ms: u128,
    reencode_ms: u128,
    encodes: u32,
    out_lufs: f64,
}

/// Codifica el tramo conservado desde el PCM ya decodificado. `head`/`tail`
/// en muestras. Devuelve el retardo residual en ms (0 si el tag gapless quedó escrito).
fn encode_span(
    pcm: &[f32],
    tmp: &str,
    rate_hint: u32,
    channels: usize,
    samples: u64,
    head: u64,
    tail: u64,
    gain: f32,
    limit: bool,
    kbps: u32,
    ceiling: f32,
) -> Result<u32, String> {
    let nch = channels.max(1);
    let end = samples.saturating_sub(tail);
    if end <= head {
        return Err("El recorte dejaría la pista sin música.".to_string());
    }
    let kept = end - head;
    let fade_n = if tail > 0 {
        ms_to_samples(TAIL_FADE_MS, rate_hint).min(kept / 4).max(1)
    } else {
        0
    };
    let mut sink = Mp3Sink::new_no_upsample(tmp, rate_hint, nch > 1, kbps)?;
    let mut lim = LookLim::new(rate_hint, ceiling);
    let mut batch: Vec<f32> = Vec::with_capacity(8192);
    let ch_out = if nch > 1 { 2 } else { 1 };

    let push_pair =
        |batch: &mut Vec<f32>, sink: &mut Mp3Sink, l: f32, r: f32| -> Result<(), String> {
            batch.push(l);
            if ch_out == 2 {
                batch.push(r);
            }
            if batch.len() >= 8192 {
                sink.push(batch, ch_out)?;
                batch.clear();
            }
            Ok(())
        };

    let mut since_check = 0usize;
    for idx in head..end {
        since_check += 1;
        if since_check >= CANCEL_BLOCK {
            since_check = 0;
            cancel_now()?;
        }
        let base = (idx as usize).saturating_mul(nch);
        if base >= pcm.len() {
            break;
        }
        let mut l = pcm[base] * gain;
        let mut r = (if nch > 1 {
            pcm.get(base + 1).copied().unwrap_or(pcm[base])
        } else {
            pcm[base]
        }) * gain;
        if fade_n > 0 {
            let pos = idx - head;
            if pos + fade_n >= kept {
                let remain = (kept - pos) as f32 / fade_n as f32;
                let g = remain.clamp(0.0, 1.0);
                l *= g;
                r *= g;
            }
        }
        if limit {
            if let Some((ol, orr)) = lim.push(l, r) {
                push_pair(&mut batch, &mut sink, ol, orr)?;
            }
        } else {
            push_pair(&mut batch, &mut sink, l, r)?;
        }
    }
    if limit {
        for (ol, orr) in lim.flush() {
            push_pair(&mut batch, &mut sink, ol, orr)?;
        }
    }
    if !batch.is_empty() {
        sink.push(&batch, ch_out)?;
    }
    let gap = sink.finish()?;
    Ok(gap.residual_ms)
}

/// LUFS integrado del PCM ya limitado (misma curva K y las mismas ventanas
/// de 10 ms que `read_audio`). No abre el MP3.
fn pcm_lufs(inter: &[f32], rate: u32, channels: usize) -> f64 {
    if rate == 0 || inter.is_empty() {
        return -70.0;
    }
    let nch = channels.max(1);
    let win = (rate as usize / 100).max(1);
    let (mut s1l, mut s2l) = k_stages(rate as f64);
    let (mut s1r, mut s2r) = k_stages(rate as f64);
    let mut acc_k = 0.0f64;
    let mut acc_n = 0usize;
    let mut k_ms: Vec<f64> = Vec::new();
    for frame in inter.chunks(nch) {
        if frame.is_empty() {
            continue;
        }
        let l = frame[0];
        let rgt = if nch > 1 {
            frame.get(1).copied().unwrap_or(l)
        } else {
            l
        };
        let kl = k_one(&mut s1l, &mut s2l, l);
        let kr = if nch > 1 {
            k_one(&mut s1r, &mut s2r, rgt)
        } else {
            kl
        };
        acc_k += kl * kl + kr * kr;
        acc_n += 1;
        if acc_n >= win {
            k_ms.push(acc_k / acc_n as f64);
            acc_k = 0.0;
            acc_n = 0;
        }
    }
    lufs_of(&k_ms)
}

/// Ganancia, fade de cola y limitador, en memoria. El PCM de salida ya está
/// limitado: el encode posterior no vuelve a pasar por LookLim.
fn render_limited_span(
    pcm: &[f32],
    rate: u32,
    channels: usize,
    samples: u64,
    head: u64,
    tail: u64,
    gain: f32,
    ceiling: f32,
) -> Result<Vec<f32>, String> {
    let nch = channels.max(1);
    let end = samples.saturating_sub(tail);
    if end <= head {
        return Err("El recorte dejaría la pista sin música.".to_string());
    }
    let kept = end - head;
    let fade_n = if tail > 0 {
        ms_to_samples(TAIL_FADE_MS, rate).min(kept / 4).max(1)
    } else {
        0
    };
    let ch_out = if nch > 1 { 2 } else { 1 };
    let mut lim = LookLim::new(rate, ceiling);
    let mut out = Vec::with_capacity((kept as usize + 8) * ch_out);
    let mut since_check = 0usize;
    for idx in head..end {
        since_check += 1;
        if since_check >= CANCEL_BLOCK {
            since_check = 0;
            cancel_now()?;
        }
        let base = (idx as usize).saturating_mul(nch);
        if base >= pcm.len() {
            break;
        }
        let mut l = pcm[base] * gain;
        let mut r = (if nch > 1 {
            pcm.get(base + 1).copied().unwrap_or(pcm[base])
        } else {
            pcm[base]
        }) * gain;
        if fade_n > 0 {
            let pos = idx - head;
            if pos + fade_n >= kept {
                let g = ((kept - pos) as f32 / fade_n as f32).clamp(0.0, 1.0);
                l *= g;
                r *= g;
            }
        }
        if let Some((ol, orr)) = lim.push(l, r) {
            out.push(ol);
            if ch_out == 2 {
                out.push(orr);
            }
        }
    }
    for (ol, orr) in lim.flush() {
        out.push(ol);
        if ch_out == 2 {
            out.push(orr);
        }
    }
    Ok(out)
}

/// Limita y corrige la ganancia hasta dejar el PCM posterior en −14.
fn tune_limited_pcm(
    pcm: &[f32],
    rate: u32,
    channels: usize,
    samples: u64,
    head: u64,
    tail: u64,
    gain: &mut f32,
    ceiling: f32,
    gain0: f32,
) -> Result<Vec<f32>, String> {
    let ch_out = if channels.max(1) > 1 { 2 } else { 1 };
    let mut limited =
        render_limited_span(pcm, rate, channels, samples, head, tail, *gain, ceiling)?;
    for _ in 0..2 {
        let lufs = pcm_lufs(&limited, rate, ch_out);
        if lufs <= -50.0 {
            break;
        }
        let db = TARGET_LUFS - lufs;
        if db.abs() <= 0.05 {
            break;
        }
        *gain = (*gain * 10f32.powf((db.clamp(-12.0, 12.0) / 20.0) as f32))
            .clamp(gain0 * 0.25, gain0 * 4.0);
        limited = render_limited_span(pcm, rate, channels, samples, head, tail, *gain, ceiling)?;
    }
    Ok(limited)
}

/// Ganancia cerrada sobre el PCM ya limitado (−14) y una sola codificación.
/// La verificación mide el MP3; si se va de −14 por más de 0,3 LU (o el pico
/// pasa de −1 dBTP) se corrige y se codifica como mucho una vez más.
fn encode_master_span(
    pcm: &[f32],
    tmp: &str,
    rate_hint: u32,
    channels: usize,
    samples: u64,
    head: u64,
    tail: u64,
    mut gain: f32,
    limit: bool,
    kbps: u32,
) -> Result<(u32, EncodeTimes), String> {
    let mut times = EncodeTimes {
        limit_ms: 0,
        encode_ms: 0,
        verify_ms: 0,
        reencode_ms: 0,
        encodes: 0,
        out_lufs: 0.0,
    };
    if !limit {
        let t = std::time::Instant::now();
        let residual = encode_span(
            pcm, tmp, rate_hint, channels, samples, head, tail, gain, false, kbps, TP_LIMIT,
        )?;
        times.encode_ms = t.elapsed().as_millis();
        times.encodes = 1;
        let t = std::time::Instant::now();
        let measured = measure_stream(tmp)?;
        times.verify_ms = t.elapsed().as_millis();
        times.out_lufs = verify_measured(tmp, &measured)?;
        return Ok((residual, times));
    }
    let gain0 = gain;
    let mut ceiling = TP_LIMIT;
    let ch_out = if channels.max(1) > 1 { 2 } else { 1 };
    let tlim = std::time::Instant::now();
    let mut limited = tune_limited_pcm(
        pcm, rate_hint, channels, samples, head, tail, &mut gain, ceiling, gain0,
    )?;
    times.limit_ms = tlim.elapsed().as_millis();
    let mut frames = (limited.len() / ch_out) as u64;
    if frames == 0 {
        return Err("El recorte dejaría la pista sin música.".to_string());
    }
    let mut residual = 0u32;
    for attempt in 0..2 {
        cancel_now()?;
        let t = std::time::Instant::now();
        residual = encode_span(
            &limited, tmp, rate_hint, ch_out, frames, 0, 0, 1.0, false, kbps, ceiling,
        )?;
        let took = t.elapsed().as_millis();
        if attempt == 0 {
            times.encode_ms = took;
        } else {
            times.reencode_ms += took;
        }
        times.encodes += 1;
        let t = std::time::Instant::now();
        let measured = measure_stream(tmp)?;
        times.verify_ms += t.elapsed().as_millis();
        let out_lufs = verify_measured(tmp, &measured)?;
        times.out_lufs = out_lufs;
        let tp_ok = measured.true_peak <= TP_CEILING;
        let miss = (out_lufs - TARGET_LUFS).abs();
        let lufs_ok = out_lufs > -50.0 && miss <= LUFS_TOL;
        if (tp_ok && lufs_ok) || attempt == 1 {
            return Ok((residual, times));
        }
        let _ = std::fs::remove_file(tmp);
        let tfix = std::time::Instant::now();
        if !lufs_ok && out_lufs > -50.0 {
            let db = (TARGET_LUFS - out_lufs).clamp(-3.0, 3.0);
            gain = (gain * 10f32.powf((db / 20.0) as f32)).clamp(gain0 * 0.5, gain0 * 2.0);
        }
        if !tp_ok {
            ceiling = (ceiling * 10f32.powf(-1.0 / 20.0)).max(TP_LIMIT_FLOOR);
        }
        limited =
            render_limited_span(pcm, rate_hint, channels, samples, head, tail, gain, ceiling)?;
        frames = (limited.len() / ch_out) as u64;
        times.reencode_ms += tfix.elapsed().as_millis();
    }
    Ok((residual, times))
}

struct SpanPlan {
    cut_head_ms: u64,
    cut_tail_ms: u64,
    new_lead_ms: u64,
    new_tail_ms: u64,
    lufs: f64,
    head_s: u64,
    tail_s: u64,
    lufs_encode: bool,
    lufs_seal: bool,
    gain: f32,
}

/// Misma decisión de corte y de −14 que `master_rewrite`.
fn plan_span(
    m: &StreamMeasure,
    do_trim: bool,
    do_lufs: bool,
    force_head_ms: i32,
    force_tail_ms: i32,
    lufs_hint: f64,
) -> SpanPlan {
    let mut cut_head_ms: u64 = 0;
    let mut cut_tail_ms: u64 = 0;
    let mut new_lead_ms: u64;
    let mut new_tail_ms: u64;
    let mut lufs = lufs_hint;
    let (lead, tail) = edges_from(&m.mono_ms);
    if do_trim {
        if force_head_ms >= 0 {
            cut_head_ms = force_head_ms as u64;
        } else {
            cut_head_ms = lead.saturating_sub(HEAD_KEEP_MS);
        }
        if force_tail_ms >= 0 {
            cut_tail_ms = force_tail_ms as u64;
        } else {
            cut_tail_ms = tail;
        }
        let head_try = ms_to_samples(cut_head_ms, m.rate);
        let tail_try = ms_to_samples(cut_tail_ms, m.rate);
        if head_try
            .saturating_add(tail_try)
            .saturating_add(m.rate as u64)
            >= m.samples
        {
            cut_head_ms = 0;
            cut_tail_ms = 0;
        }
        if cut_head_ms < 50 {
            cut_head_ms = 0;
        }
        if cut_tail_ms < 50 {
            cut_tail_ms = 0;
        }
        new_lead_ms = lead.saturating_sub(cut_head_ms);
        new_tail_ms = if cut_tail_ms > 0 { 0 } else { tail };
    } else {
        new_lead_ms = lead;
        new_tail_ms = tail;
    }
    let head_w = (cut_head_ms / 10) as usize;
    let tail_w = (cut_tail_ms / 10) as usize;
    let end_w = m.k_ms.len().saturating_sub(tail_w);
    if end_w > head_w {
        lufs = lufs_of(&m.k_ms[head_w..end_w]);
    }
    let blocking = blocking_decode_errors(m);
    let mut lufs_encode = lufs_encode_decision(do_lufs, lufs, m.true_peak, blocking);
    let mut lufs_seal = do_lufs && blocking == 0 && lufs >= -60.0 && !lufs_encode;
    if blocking > 0 {
        cut_head_ms = 0;
        cut_tail_ms = 0;
        new_lead_ms = lead;
        new_tail_ms = tail;
        lufs_encode = false;
        lufs_seal = false;
    }
    let head_s = if cut_head_ms >= 50 {
        ms_to_samples(cut_head_ms, m.rate)
    } else {
        0
    };
    let tail_s = if cut_tail_ms >= 50 {
        ms_to_samples(cut_tail_ms, m.rate)
    } else {
        0
    };
    let gain = if lufs_encode {
        gain_for(lufs, true)
    } else {
        1.0
    };
    SpanPlan {
        cut_head_ms,
        cut_tail_ms,
        new_lead_ms,
        new_tail_ms,
        lufs,
        head_s,
        tail_s,
        lufs_encode,
        lufs_seal,
        gain,
    }
}

fn detect_validated(
    path: &str,
    samples: u64,
    rate: u32,
    intro: bool,
    prior: Option<f64>,
) -> Option<f64> {
    let _ = prior;
    // La pista completa, desde el inicio, hasta 15 min. Un megamix pide solo
    // la intro (60 s): el mismo medidor, no otro algoritmo.
    let total_s = if samples == 0 || rate == 0 {
        MAX_ANALYZE_SECS as u64
    } else {
        (samples / rate as u64).max(8)
    };
    let span = if intro {
        60u32
    } else {
        (total_s.min(MAX_ANALYZE_SECS as u64)) as u32
    };
    let d = decode_channels(path, 0, span.max(8), 2).ok()?;
    detect_bpm(&to_mono(&d), d.rate, None)
}

fn opt_i32(tag: &Tag, key: &str) -> i32 {
    match ext_text(tag, key) {
        Some(s) => num_from(&s) as i32,
        None => -1,
    }
}

fn flag_on(tag: &Tag, key: &str) -> bool {
    ext_text(tag, key).as_deref() == Some("1")
}

fn gmx_key_ok(key: &str) -> bool {
    matches!(
        key,
        KEY_V
            | KEY_RESCUE
            | KEY_RESCUE_LYR
            | KEY_LUFS
            | KEY_LEAD
            | KEY_TAIL
            | KEY_TYPE
            | KEY_NAME_OK
            | KEY_LYR
            | KEY_LYR_START
            | KEY_LYR_CHECK
            | KEY_TRIM
            | KEY_TRIM_TAIL
            | KEY_LRC_SHIFT
            | KEY_BPM_OK
            | KEY_BPM_SCOPE
            | KEY_ANALYSIS
            | KEY_GRID
            | KEY_LUFS_DONE
            | KEY_K
            | KEY_BACKUP
            | KEY_REASON
    )
}

/// Marcas GMX de una pista, sin decodificar. Igual en las 4 plataformas.
pub struct GmxMarks {
    pub version: String,
    pub track_type: String,
    pub name_ok: bool,
    pub lyr: String,
    pub lyr_start_ms: i32,
    pub trim_ms: i32,
    pub trim_tail_ms: i32,
    pub lrc_shift: bool,
    pub bpm: f64,
    pub bpm_ok: bool,
    pub bpm_scope: String,
    pub lufs: f64,
    pub lufs_done: bool,
    pub karaoke: bool,
    pub backup: bool,
    pub sealed: bool,
    pub lead_ms: i32,
    /// Vacío, o `decode_errors=N` si el audio no se recodificó por paquetes rotos.
    pub reason: String,
}

pub fn read_gmx_marks(input_path: String) -> GmxMarks {
    let empty = GmxMarks {
        version: String::new(),
        track_type: String::new(),
        name_ok: false,
        lyr: String::new(),
        lyr_start_ms: -1,
        trim_ms: -1,
        trim_tail_ms: -1,
        lrc_shift: false,
        bpm: 0.0,
        bpm_ok: false,
        bpm_scope: String::new(),
        lufs: 0.0,
        lufs_done: false,
        karaoke: false,
        backup: false,
        sealed: false,
        lead_ms: -1,
        reason: String::new(),
    };
    if !is_mp3(&input_path) {
        return empty;
    }
    let tag = match Tag::read_from_path(&input_path) {
        Ok(t) => t,
        Err(_) => return empty,
    };
    let bpm = stored_bpm(&input_path, &tag)
        .map(|s| s.value)
        .unwrap_or(0.0);
    let sealed = tag.comments().any(|c| c.text == SEAL_TEXT);
    let marks = GmxMarks {
        version: ext_text(&tag, KEY_V).unwrap_or_default(),
        track_type: ext_text(&tag, KEY_TYPE).unwrap_or_default(),
        name_ok: flag_on(&tag, KEY_NAME_OK),
        lyr: ext_text(&tag, KEY_LYR).unwrap_or_default(),
        lyr_start_ms: opt_i32(&tag, KEY_LYR_START),
        trim_ms: opt_i32(&tag, KEY_TRIM),
        trim_tail_ms: opt_i32(&tag, KEY_TRIM_TAIL),
        lrc_shift: flag_on(&tag, KEY_LRC_SHIFT),
        bpm,
        bpm_ok: flag_on(&tag, KEY_BPM_OK),
        bpm_scope: ext_text(&tag, KEY_BPM_SCOPE).unwrap_or_default(),
        lufs: ext_text(&tag, KEY_LUFS)
            .map(|s| num_from(&s))
            .unwrap_or(0.0),
        lufs_done: ext_text(&tag, KEY_LUFS_DONE).as_deref() == Some("-14"),
        karaoke: flag_on(&tag, KEY_K),
        backup: flag_on(&tag, KEY_BACKUP),
        sealed,
        lead_ms: opt_i32(&tag, KEY_LEAD),
        reason: ext_text(&tag, KEY_REASON).unwrap_or_default(),
    };
    marks
}

/// Escribe una marca GMX de la lista blanca. No crea marcas arbitrarias.
pub fn set_gmx_mark(input_path: String, key: String, value: String) -> Result<bool, String> {
    if !gmx_key_ok(&key) {
        return Err(format!("Marca no permitida: {key}"));
    }
    if !Path::new(&input_path).exists() {
        return Err("Archivo no encontrado en I/O.".to_string());
    }
    if !is_mp3(&input_path) {
        return Ok(false);
    }
    let mut tag = Tag::read_from_path(&input_path).unwrap_or_else(|_| Tag::new());
    set_ext(&mut tag, &key, value);
    tag.write_to_path(&input_path, Version::Id3v24)
        .map_err(|e| e.to_string())?;
    Ok(true)
}

/// Resultado de reescribir una pista. `trim_head_ms` es lo cortado EN ESTA
/// pasada (0 si ya estaba cortada: no hay que mover la letra otra vez).
pub struct MasterRewrite {
    pub trim_head_ms: u32,
    pub trim_tail_ms: u32,
    pub lead_ms: u32,
    pub tail_ms: u32,
    pub bpm: f64,
    pub lufs: f64,
    pub lufs_applied: bool,
    pub bitrate_kbps: u32,
    pub rewritten: bool,
    /// Ms que el decodificador AÑADE al inicio si ignora el tag LAME.
    /// Con el tag escrito, libmpv/FFmpeg se lo salta y esto queda en 0.
    /// No es una constante: sale del delay que LAME anotó en el tag.
    pub residual_ms: u32,
}

/// Hilos de trabajo de una canción. Móvil: 1. Escritorio: 2. Sin más.
fn master_worker_cap() -> usize {
    if cfg!(any(target_os = "android", target_os = "ios")) {
        1
    } else {
        2
    }
}

fn limit_worker_threads() {
    let n = master_worker_cap();
    #[cfg(any(
        target_os = "linux",
        target_os = "android",
        target_os = "macos",
        target_os = "ios"
    ))]
    unsafe {
        extern "C" {
            fn setenv(name: *const i8, value: *const i8, overwrite: i32) -> i32;
        }
        let name = b"OMP_NUM_THREADS\0";
        let value: [u8; 2] = [b'0' + n as u8, 0];
        let _ = setenv(name.as_ptr() as *const i8, value.as_ptr() as *const i8, 1);
    }
    #[cfg(target_os = "windows")]
    unsafe {
        extern "system" {
            fn SetEnvironmentVariableW(name: *const u16, value: *const u16) -> i32;
        }
        let name: Vec<u16> = "OMP_NUM_THREADS"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let value: Vec<u16> = n
            .to_string()
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let _ = SetEnvironmentVariableW(name.as_ptr(), value.as_ptr());
    }
}

fn priority_slot() -> &'static std::sync::Mutex<String> {
    static LABEL: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());
    &LABEL
}

fn store_priority_label(label: &str) {
    if let Ok(mut g) = priority_slot().lock() {
        *g = label.to_string();
    }
}

fn priority_label() -> String {
    priority_slot()
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default()
}

thread_local! {
    static ON_WORKER: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

fn on_worker_thread() -> bool {
    ON_WORKER.with(|c| c.get())
}

/// La canción corre en su hilo. Al terminar, el hilo muere: un nice que
/// el SO no deja revertir no se queda en el pool de la UI ni de Live DJ.
fn run_on_master_worker<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> T {
    let (tx, rx) = std::sync::mpsc::channel();
    match std::thread::Builder::new()
        .name("gmx-master".into())
        .spawn(move || {
            ON_WORKER.with(|c| c.set(true));
            let _ = tx.send(work());
        }) {
        Ok(handle) => {
            let value = rx
                .recv()
                .unwrap_or_else(|_| unreachable!("el hilo no respondió"));
            let _ = handle.join();
            value
        }
        Err(_) => unreachable!("no hubo hilo para la canción"),
    }
}

/// Baja la prioridad del hilo de esta canción y la devuelve al salir.
/// Sin afinidad: el SO reparte los núcleos.
struct PriorityGuard {
    active: bool,
}

thread_local! {
    static PRIO_DEPTH: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

impl PriorityGuard {
    fn enter() -> Self {
        let active = PRIO_DEPTH.with(|d| {
            let n = d.get();
            d.set(n.saturating_add(1));
            n == 0
        });
        if active {
            limit_worker_threads();
            store_priority_label(&apply_low_priority());
        }
        Self { active }
    }

    /// Sin bajar el hilo: el master por carpeta (`--master-folder`) va en
    /// primer plano. El de la app sigue con `enter`.
    fn skip() -> Self {
        Self { active: false }
    }
}

/// `--master-folder` o `GMX_HEADLESS`: no aplicar EcoQoS / background / nice.
fn headless_master_folder() -> bool {
    if std::env::var_os("GMX_HEADLESS").is_some() {
        return true;
    }
    std::env::args().any(|a| a == "--master-folder" || a.starts_with("--master-folder="))
}

impl Drop for PriorityGuard {
    fn drop(&mut self) {
        let last = PRIO_DEPTH.with(|d| {
            let n = d.get().saturating_sub(1);
            d.set(n);
            n == 0
        });
        if self.active && last {
            restore_priority();
        }
    }
}

/// Lo que aplicó el último hilo de canción. Lo usa el log.
pub fn master_priority() -> String {
    priority_label()
}

fn apply_low_priority() -> String {
    #[cfg(target_os = "windows")]
    {
        return win_priority::apply();
    }
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        return qos_priority::apply();
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "ios")))]
    {
        nice_priority::apply()
    }
}

fn restore_priority() {
    #[cfg(target_os = "windows")]
    win_priority::restore();
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    qos_priority::restore();
    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "ios")))]
    nice_priority::restore();
}

/// Android y Linux: nice 10 en este hilo (`THREAD_PRIORITY_BACKGROUND`).
/// `who` es el tid, no el proceso: el servicio en primer plano sigue igual.
#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "ios")))]
mod nice_priority {
    use std::cell::Cell;

    thread_local! {
        static PREV: Cell<Option<(i32, i32)>> = const { Cell::new(None) };
    }

    fn errno_clear() {
        unsafe {
            *errno_ptr() = 0;
        }
    }

    // Bionic (Android) exporta __errno; glibc (Linux) __errno_location.
    #[cfg(target_os = "android")]
    unsafe fn errno_ptr() -> *mut i32 {
        __errno()
    }

    #[cfg(not(target_os = "android"))]
    unsafe fn errno_ptr() -> *mut i32 {
        __errno_location()
    }

    extern "C" {
        #[cfg(target_os = "android")]
        fn __errno() -> *mut i32;
        #[cfg(not(target_os = "android"))]
        fn __errno_location() -> *mut i32;
        fn gettid() -> i32;
        fn getpriority(which: i32, who: i32) -> i32;
        fn setpriority(which: i32, who: i32, prio: i32) -> i32;
    }

    fn nice_of(tid: i32) -> i32 {
        unsafe {
            errno_clear();
            getpriority(0, tid)
        }
    }

    pub(super) fn apply() -> String {
        let tid = unsafe { gettid() };
        let prev = nice_of(tid);
        let rc = unsafe { setpriority(0, tid, 10) };
        if rc != 0 {
            PREV.with(|p| p.set(None));
            return "none".to_string();
        }
        PREV.with(|p| p.set(Some((tid, prev))));
        "nice10".to_string()
    }

    pub(super) fn restore() {
        let Some((tid, prev)) = PREV.with(|p| p.take()) else {
            return;
        };
        unsafe {
            let _ = setpriority(0, tid, prev);
        }
    }

    #[cfg(test)]
    pub(super) fn current_nice() -> i32 {
        nice_of(unsafe { gettid() })
    }
}

/// macOS e iPhone: QoS utility. Al salir, la clase por defecto del hilo.
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod qos_priority {
    use std::cell::Cell;

    thread_local! {
        static ON: Cell<bool> = const { Cell::new(false) };
    }

    extern "C" {
        fn pthread_set_qos_class_self_np(class: u32, relative: i32) -> i32;
    }

    const QOS_CLASS_UTILITY: u32 = 0x11;
    const QOS_CLASS_DEFAULT: u32 = 0x15;

    pub(super) fn apply() -> String {
        let rc = unsafe { pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0) };
        if rc != 0 {
            ON.with(|c| c.set(false));
            return "none".to_string();
        }
        ON.with(|c| c.set(true));
        "qos-utility".to_string()
    }

    pub(super) fn restore() {
        if !ON.with(|c| c.replace(false)) {
            return;
        }
        unsafe {
            let _ = pthread_set_qos_class_self_np(QOS_CLASS_DEFAULT, 0);
        }
    }
}

/// Windows: EcoQoS y, además, modo background o prioridad por debajo de lo normal.
#[cfg(target_os = "windows")]
mod win_priority {
    use std::cell::Cell;

    thread_local! {
        static SAVED: Cell<Option<Saved>> = const { Cell::new(None) };
    }

    struct Saved {
        eco: bool,
        background: bool,
        below: bool,
    }

    extern "system" {
        fn GetCurrentThread() -> isize;
        fn SetThreadInformation(thread: isize, class: i32, info: *const u8, len: u32) -> i32;
        fn SetThreadPriority(thread: isize, priority: i32) -> i32;
    }

    const THREAD_POWER_THROTTLING: i32 = 3;
    const THREAD_POWER_THROTTLING_CURRENT_VERSION: u32 = 1;
    const THREAD_POWER_THROTTLING_EXECUTION_SPEED: u32 = 0x1;
    const THREAD_MODE_BACKGROUND_BEGIN: i32 = 0x00010000;
    const THREAD_MODE_BACKGROUND_END: i32 = 0x00020000;
    const THREAD_PRIORITY_BELOW_NORMAL: i32 = -1;
    const THREAD_PRIORITY_NORMAL: i32 = 0;

    #[repr(C)]
    struct Throttle {
        version: u32,
        control_mask: u32,
        state_mask: u32,
    }

    fn throttle(thread: isize, state: u32) -> bool {
        let info = Throttle {
            version: THREAD_POWER_THROTTLING_CURRENT_VERSION,
            control_mask: THREAD_POWER_THROTTLING_EXECUTION_SPEED,
            state_mask: state,
        };
        unsafe {
            SetThreadInformation(
                thread,
                THREAD_POWER_THROTTLING,
                &info as *const Throttle as *const u8,
                std::mem::size_of::<Throttle>() as u32,
            ) != 0
        }
    }

    pub(super) fn apply() -> String {
        let thread = unsafe { GetCurrentThread() };
        let eco = throttle(thread, THREAD_POWER_THROTTLING_EXECUTION_SPEED);
        let background = unsafe { SetThreadPriority(thread, THREAD_MODE_BACKGROUND_BEGIN) != 0 };
        let below = if background {
            false
        } else {
            unsafe { SetThreadPriority(thread, THREAD_PRIORITY_BELOW_NORMAL) != 0 }
        };
        SAVED.with(|c| {
            c.set(Some(Saved {
                eco,
                background,
                below,
            }))
        });
        match (eco, background, below) {
            (true, true, _) => "ecoqos+background".to_string(),
            (true, false, true) => "ecoqos+below-normal".to_string(),
            (false, false, true) => "below-normal".to_string(),
            (true, false, false) => "ecoqos".to_string(),
            (false, true, _) => "background".to_string(),
            _ => "none".to_string(),
        }
    }

    pub(super) fn restore() {
        let Some(saved) = SAVED.with(|c| c.take()) else {
            return;
        };
        let thread = unsafe { GetCurrentThread() };
        if saved.background {
            unsafe {
                let _ = SetThreadPriority(thread, THREAD_MODE_BACKGROUND_END);
            }
        } else if saved.below {
            unsafe {
                let _ = SetThreadPriority(thread, THREAD_PRIORITY_NORMAL);
            }
        }
        if saved.eco {
            let _ = throttle(thread, 0);
        }
    }
}

/// El temporal tiene que decodificar. LUFS y pico se leen en la misma pasada
/// (la decisión de −14 y −1 dBTP la toma el bucle de `encode_master_span`).
fn verify_measured(tmp: &str, measured: &StreamMeasure) -> Result<f64, String> {
    if measured.samples == 0 || measured.decode_errors > 0 {
        let _ = std::fs::remove_file(tmp);
        return Err("La verificación no decodificó el temporal.".to_string());
    }
    let lufs = lufs_of(&measured.k_ms);
    let tp = measured.true_peak as f64;
    if !lufs.is_finite() || !tp.is_finite() || tp < 0.0 {
        let _ = std::fs::remove_file(tmp);
        return Err("La verificación no obtuvo LUFS ni pico del temporal.".to_string());
    }
    Ok(lufs)
}

/// Muestras máximas entre dos lecturas de la X. Dentro de 4096–65536.
const CANCEL_BLOCK: usize = 8192;

const CANCELLED: &str = "Cancelado";

/// Bandera de la X, compartida con la UI. `Arc` para que el hilo de la
/// canción y el de la X vean el mismo átomo (como el interrupt de ffmpeg).
fn master_cancel_flag() -> &'static std::sync::Arc<std::sync::atomic::AtomicBool> {
    static FLAG: std::sync::OnceLock<std::sync::Arc<std::sync::atomic::AtomicBool>> =
        std::sync::OnceLock::new();
    FLAG.get_or_init(|| std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)))
}

thread_local! {
    static CANCEL_DEPTH: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
    static SONG_DEADLINE: std::cell::Cell<Option<std::time::Instant>> = const { std::cell::Cell::new(None) };
}

/// Tope de reloj por canción (1.0.14): ninguna pista puede colgar un lote.
/// `GMX_SONG_TIMEOUT_S` lo cambia (pruebas); por defecto 20 min.
const SONG_TIMEOUT: &str = "Tiempo agotado por canción";

fn song_timeout() -> std::time::Duration {
    let secs = std::env::var("GMX_SONG_TIMEOUT_S")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(20 * 60);
    std::time::Duration::from_secs(secs)
}

struct CancelWatch;

impl CancelWatch {
    fn enter() -> Self {
        CANCEL_DEPTH.with(|d| {
            if d.get() == 0 {
                SONG_DEADLINE.with(|t| t.set(Some(std::time::Instant::now() + song_timeout())));
            }
            d.set(d.get().saturating_add(1))
        });
        CancelWatch
    }
}

impl Drop for CancelWatch {
    fn drop(&mut self) {
        CANCEL_DEPTH.with(|d| {
            d.set(d.get().saturating_sub(1));
            if d.get() == 0 {
                SONG_DEADLINE.with(|t| t.set(None));
            }
        });
    }
}

fn cancel_now() -> Result<(), String> {
    let watching = CANCEL_DEPTH.with(|d| d.get() > 0);
    if watching && master_cancel_flag().load(std::sync::atomic::Ordering::Acquire) {
        Err(CANCELLED.to_string())
    } else if watching
        && SONG_DEADLINE
            .with(|t| t.get())
            .is_some_and(|d| std::time::Instant::now() >= d)
    {
        Err(SONG_TIMEOUT.to_string())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod song_timeout_tests {
    use super::*;

    #[test]
    fn deadline_trips_and_clears() {
        {
            let _w = CancelWatch::enter();
            assert!(cancel_now().is_ok());
            // Solo este hilo: no toca el entorno de los demás tests.
            SONG_DEADLINE.with(|t| {
                t.set(Some(
                    std::time::Instant::now() - std::time::Duration::from_millis(1),
                ))
            });
            assert_eq!(cancel_now().unwrap_err(), SONG_TIMEOUT);
        }
        // Fuera de una canción no hay tope.
        assert!(cancel_now().is_ok());
        let _w = CancelWatch::enter();
        assert!(cancel_now().is_ok());
    }
}

/// La X pide cortar la canción en curso. El hilo lo ve en el siguiente bloque.
pub fn master_cancel() {
    master_cancel_flag().store(true, std::sync::atomic::Ordering::Release);
}

/// Limpia la X antes de un lote nuevo.
pub fn master_arm() {
    master_cancel_flag().store(false, std::sync::atomic::Ordering::Release);
}

fn discard_partial(path: &str) {
    let _ = std::fs::remove_file(path);
}

/// Recorta silencios y/o normaliza a −14 LUFS. Una sola generación si hacen
/// falta los dos. `force_head_ms` / `force_tail_ms` < 0 = detectar; si no,
/// cortar exactamente esos ms (el `_K` acompaña a la pista). Una pista que
/// Clave de la etapa de rescate: REPAIR:<detalle> o FAIL:<motivo>.
const KEY_RESCUE: &str = "GMX_RESCUE";
/// Etapa 2 de la letra (Dart): LYRIC_FIXED o FAIL:<motivo>.
const KEY_RESCUE_LYR: &str = "GMX_RESCUE_LYR";

/// Repara `path` sin pérdida y lo re-mide. Devuelve Some solo si la copia
/// reparada ya no tiene errores que bloqueen; entonces reemplaza el archivo
/// (guardando `.prerepair.bak`). Si no ayuda, no toca nada.
fn try_lossless_repair(path: &str, before: u32) -> Result<Option<(String, StreamMeasure)>, String> {
    let data = std::fs::read(path).map_err(|e| e.to_string())?;
    let Some((fixed, st)) = crate::mp3_repair::repair_mp3(&data) else {
        return Ok(None);
    };
    if !st.changed() {
        return Ok(None);
    }
    let tmp = format!("{path}.gmxrepair.mp3");
    std::fs::write(&tmp, &fixed).map_err(|e| e.to_string())?;
    let m2 = match measure_stream(&tmp) {
        Ok(m) => m,
        Err(_) => {
            let _ = std::fs::remove_file(&tmp);
            return Ok(None);
        }
    };
    if blocking_decode_errors(&m2) > 0 || m2.samples == 0 {
        let _ = std::fs::remove_file(&tmp);
        return Ok(None);
    }
    let bak = format!("{path}.prerepair.bak");
    if !Path::new(&bak).exists() {
        std::fs::copy(path, &bak).map_err(|e| e.to_string())?;
    }
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())?;
    Ok(Some((
        format!(
            "REPAIR:{} errors {}->{}",
            st.summary(),
            before,
            m2.decode_errors
        ),
        m2,
    )))
}

/// ya tiene `GMX_TRIM_MS` no se vuelve a cortar.
pub fn master_rewrite(
    input_path: String,
    do_trim: bool,
    do_lufs: bool,
    intro_bpm: bool,
    force_head_ms: i32,
    force_tail_ms: i32,
) -> Result<MasterRewrite, String> {
    if !on_worker_thread() {
        return run_on_master_worker(move || {
            master_rewrite(
                input_path,
                do_trim,
                do_lufs,
                intro_bpm,
                force_head_ms,
                force_tail_ms,
            )
        });
    }
    let _prio = if headless_master_folder() {
        PriorityGuard::skip()
    } else {
        PriorityGuard::enter()
    };
    let _watch = CancelWatch::enter();
    cancel_now()?;
    if !Path::new(&input_path).exists() {
        return Err("Archivo no encontrado en I/O.".to_string());
    }
    if !is_mp3(&input_path) {
        return Err("Solo MP3.".to_string());
    }
    let mut tag = Tag::read_from_path(&input_path).unwrap_or_else(|_| Tag::new());
    // Audio ya hecho. Versión actual con BPM > 0: no se abre el PCM.
    // BPM 0 se vuelve a medir. Versión vieja: solo BPM, rejilla y duración.
    if force_head_ms < 0 && force_tail_ms < 0 && audio_mastered(&tag) {
        let stored = stored_bpm(&input_path, &tag)
            .map(|s| s.value)
            .unwrap_or(0.0);
        if analysis_current(&tag) && stored > 0.0 {
            return Ok(rewrite_from_tags(&tag, stored));
        }
        match refresh_analysis_tags(&input_path) {
            Ok(bpm) => {
                let tag = Tag::read_from_path(&input_path).unwrap_or(tag);
                return Ok(rewrite_from_tags(&tag, bpm));
            }
            Err(e) => {
                if analysis_current(&tag) && stored <= 0.0 {
                    return Ok(rewrite_from_tags(&tag, 0.0));
                }
                return Err(e);
            }
        }
    }
    let already_trim = ext_text(&tag, KEY_TRIM).is_some();
    let already_lufs = ext_text(&tag, KEY_LUFS_DONE).as_deref() == Some("-14");
    let do_trim = do_trim && !already_trim;
    let do_lufs = do_lufs && !already_lufs;

    let need_audio = do_trim || do_lufs;
    let mut decode_ms: u128 = 0;
    let mut pcm: Vec<f32> = Vec::new();
    let t_decode = std::time::Instant::now();
    let mut measured = if need_audio {
        let take = read_audio(&input_path, true)?;
        pcm = take.pcm;
        Some(take.measure)
    } else {
        None
    };
    decode_ms += t_decode.elapsed().as_millis();
    // Etapa 2 (1.0.12+26): si hay paquetes rotos que bloquean, reparar sin
    // pérdida (estilo mp3val) y volver a medir. Solo se queda la reparación
    // si deja de bloquear; el original queda en `<archivo>.prerepair.bak`.
    let mut rescue_note: Option<String> = None;
    let broken = measured.as_ref().map(|m| m.decode_errors).unwrap_or(0);
    if measured.as_ref().map(blocking_decode_errors).unwrap_or(0) > 0 {
        if let Some((note, _m2)) = try_lossless_repair(&input_path, broken)? {
            tag = Tag::read_from_path(&input_path).unwrap_or_else(|_| Tag::new());
            let t_decode = std::time::Instant::now();
            let take = read_audio(&input_path, true)?;
            decode_ms += t_decode.elapsed().as_millis();
            pcm = take.pcm;
            measured = Some(take.measure);
            rescue_note = Some(note);
        } else {
            rescue_note = Some(format!("FAIL:repair_no_help,decode_errors={broken}"));
        }
    }

    let mut cut_head_ms: u64 = 0;
    let mut cut_tail_ms: u64 = 0;
    let mut new_lead_ms: u64 = 0;
    let mut new_tail_ms: u64 = 0;
    let mut lufs = ext_text(&tag, KEY_LUFS)
        .map(|s| num_from(&s))
        .unwrap_or(0.0);
    let mut kbps = 0u32;

    if let Some(m) = &measured {
        let (lead, tail) = edges_from(&m.mono_ms);
        if do_trim {
            if force_head_ms >= 0 {
                cut_head_ms = force_head_ms as u64;
            } else {
                cut_head_ms = lead.saturating_sub(HEAD_KEEP_MS);
            }
            if force_tail_ms >= 0 {
                cut_tail_ms = force_tail_ms as u64;
            } else {
                cut_tail_ms = tail;
            }
            let head_s = ms_to_samples(cut_head_ms, m.rate);
            let tail_s = ms_to_samples(cut_tail_ms, m.rate);
            if head_s.saturating_add(tail_s).saturating_add(m.rate as u64) >= m.samples {
                cut_head_ms = 0;
                cut_tail_ms = 0;
            }
            // Menos de 50 ms no justifica otra generación. El `_K` forzado
            // hereda el corte ya redondeado de la pista, así que cae igual.
            if cut_head_ms < 50 {
                cut_head_ms = 0;
            }
            if cut_tail_ms < 50 {
                cut_tail_ms = 0;
            }
            new_lead_ms = lead.saturating_sub(cut_head_ms);
            new_tail_ms = if cut_tail_ms > 0 { 0 } else { tail };
        } else {
            new_lead_ms = lead;
            new_tail_ms = tail;
        }
        let head_w = (cut_head_ms / 10) as usize;
        let tail_w = (cut_tail_ms / 10) as usize;
        let end_w = m.k_ms.len().saturating_sub(tail_w);
        if end_w > head_w {
            lufs = lufs_of(&m.k_ms[head_w..end_w]);
        }
        kbps = average_kbps(&input_path, m.samples, m.rate);
    }

    // Recodifica solo si hay corte de verdad (≥ 50 ms), el LUFS medido al
    // decodificar se sale de −14 ±0,3, o el pico pasa de −1 dBTP. Si no, solo
    // se escriben marcas. Un paquete MP3 rechazado deja el audio intacto.
    // Pocos paquetes rotos (≤ 1 s y ≤ 0,5 %) no bloquean: se normaliza igual.
    let raw_decode_errors = measured.as_ref().map(|m| m.decode_errors).unwrap_or(0);
    let decode_errors = measured.as_ref().map(blocking_decode_errors).unwrap_or(0);
    let blocked = decode_errors > 0;
    let peak = measured.as_ref().map(|m| m.true_peak).unwrap_or(0.0);
    let mut lufs_encode = lufs_encode_decision(do_lufs, lufs, peak, decode_errors);
    let mut lufs_seal = do_lufs && !blocked && lufs >= -60.0 && !lufs_encode;
    if blocked {
        cut_head_ms = 0;
        cut_tail_ms = 0;
        if let Some(m) = &measured {
            let (lead, tail) = edges_from(&m.mono_ms);
            new_lead_ms = lead;
            new_tail_ms = tail;
        }
        lufs_encode = false;
        lufs_seal = false;
    }
    let lufs_applied = lufs_encode;
    let gain = if lufs_encode {
        gain_for(lufs, true)
    } else {
        1.0
    };

    let mut rewritten = false;
    let mut residual_ms = 0u32;
    let mut encode_times = EncodeTimes {
        limit_ms: 0,
        encode_ms: 0,
        verify_ms: 0,
        reencode_ms: 0,
        encodes: 0,
        out_lufs: 0.0,
    };
    let bpm_path: String;
    let (bpm_head, bpm_tail) = if let Some(m) = &measured {
        let head_s = if cut_head_ms >= 50 {
            ms_to_samples(cut_head_ms, m.rate)
        } else {
            0
        };
        let tail_s = if cut_tail_ms >= 50 {
            ms_to_samples(cut_tail_ms, m.rate)
        } else {
            0
        };
        let audio_change = head_s > 0 || tail_s > 0 || lufs_encode;
        if audio_change {
            let tmp = format!("{input_path}.gmxpart");
            let (residual, times) = encode_master_span(
                &pcm,
                &tmp,
                m.rate,
                m.channels,
                m.samples,
                head_s,
                tail_s,
                gain,
                lufs_encode,
                kbps,
            )
            .map_err(|e| {
                let _ = std::fs::remove_file(&tmp);
                e
            })?;
            residual_ms = residual;
            encode_times = times;
            bpm_path = tmp;
            rewritten = true;
            (head_s, tail_s)
        } else {
            bpm_path = input_path.clone();
            (0, 0)
        }
    } else {
        bpm_path = input_path.clone();
        (0, 0)
    };

    let (samples_for_bpm, rate_for_bpm) = if let Some(m) = &measured {
        let head_s = if do_trim {
            ms_to_samples(cut_head_ms, m.rate)
        } else {
            0
        };
        let tail_s = if do_trim {
            ms_to_samples(cut_tail_ms, m.rate)
        } else {
            0
        };
        (
            m.samples.saturating_sub(head_s).saturating_sub(tail_s),
            m.rate,
        )
    } else {
        (0u64, 0u32)
    };
    let stored = stored_bpm(&input_path, &tag);
    let old_bpm = stored.as_ref().map(|s| s.value).unwrap_or(0.0);
    // Con paquetes rotos el PCM está incompleto: no se inventa un BPM.
    // Con audio sano se mide siempre, aunque ya hubiera TBPM.
    let t_bpm = std::time::Instant::now();
    let grid = if blocked {
        None
    } else if let Some(m) = &measured {
        let _ = (samples_for_bpm, rate_for_bpm, &bpm_path);
        grid_from_pcm(&pcm, m.channels, m.rate, bpm_head, bpm_tail, intro_bpm)
    } else {
        measure_path_grid(&bpm_path, intro_bpm)
    };
    let bpm_ms = t_bpm.elapsed().as_millis();
    if let Err(e) = cancel_now() {
        if rewritten {
            discard_partial(&bpm_path);
        }
        return Err(e);
    }
    let bpm = grid.as_ref().map(|g| g.bpm).unwrap_or(0.0);

    if do_trim && !blocked {
        set_ext(&mut tag, KEY_TRIM, cut_head_ms.to_string());
        set_ext(&mut tag, KEY_TRIM_TAIL, cut_tail_ms.to_string());
        set_ext(&mut tag, KEY_LEAD, new_lead_ms.to_string());
        set_ext(&mut tag, KEY_TAIL, new_tail_ms.to_string());
    }
    if lufs_applied || lufs_seal {
        set_ext(&mut tag, KEY_LUFS, format!("{lufs:.2}"));
        set_ext(&mut tag, KEY_LUFS_DONE, "-14".to_string());
    }
    if lufs_applied {
        // El archivo queda en −14. ReplayGain hacia −18 para que un
        // reproductor externo no vuelva a subir lo ya normalizado.
        set_ext(&mut tag, "REPLAYGAIN_TRACK_GAIN", "-4.00 dB".to_string());
        set_ext(
            &mut tag,
            "REPLAYGAIN_TRACK_PEAK",
            format!("{TP_CEILING:.6}"),
        );
    }
    if let Some(g) = &grid {
        stamp_grid(&mut tag, g, if intro_bpm { "INTRO" } else { "FULL" });
        let dur_path = if rewritten {
            bpm_path.as_str()
        } else {
            input_path.as_str()
        };
        if let Ok(audio) = decoded_duration_ms(dur_path) {
            write_measured_duration(&mut tag, audio);
        }
        let name = Path::new(&input_path)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(input_path.as_str());
        eprintln!("BPM_FIX {name} {old_bpm:.2}->{:.2}", g.bpm);
    }
    if blocked {
        set_ext(
            &mut tag,
            KEY_REASON,
            format!("decode_errors={decode_errors}"),
        );
    } else {
        tag.remove_extended_text(Some(KEY_REASON), None);
    }
    if measured.is_some() {
        if raw_decode_errors > 0 && !blocked {
            // Auditable: se normalizó con N paquetes rotos ignorados.
            set_ext(&mut tag, KEY_DECODE_TOL, raw_decode_errors.to_string());
        } else {
            tag.remove_extended_text(Some(KEY_DECODE_TOL), None);
        }
    }
    if let Some(n) = &rescue_note {
        set_ext(&mut tag, KEY_RESCUE, n.clone());
    }
    set_ext(&mut tag, KEY_V, SCHEMA_V2.to_string());

    if let Err(e) = cancel_now() {
        if rewritten {
            discard_partial(&bpm_path);
        }
        return Err(e);
    }

    if rewritten {
        let tmp = bpm_path;
        tag.write_to_path(&tmp, Version::Id3v24).map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            e.to_string()
        })?;
        if let Err(e) = cancel_now() {
            discard_partial(&tmp);
            return Err(e);
        }
        let side = format!("{input_path}.gmxside");
        if let Err(e) = std::fs::rename(&input_path, &side) {
            let _ = std::fs::remove_file(&tmp);
            return Err(e.to_string());
        }
        if let Err(e) = std::fs::rename(&tmp, &input_path) {
            let _ = std::fs::rename(&side, &input_path);
            let _ = std::fs::remove_file(&tmp);
            return Err(e.to_string());
        }
        let _ = std::fs::remove_file(&side);
    } else {
        tag.write_to_path(&input_path, Version::Id3v24)
            .map_err(|e| e.to_string())?;
    }

    let stage_name = Path::new(&input_path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(input_path.as_str());
    eprintln!(
        "MASTER_STAGE decode_measure_ms={decode_ms} limit_ms={} encode_ms={} verify_ms={} reencode_ms={} bpm_ms={bpm_ms} encodes={} out_lufs={:.2} file={stage_name}",
        encode_times.limit_ms,
        encode_times.encode_ms,
        encode_times.verify_ms,
        encode_times.reencode_ms,
        encode_times.encodes,
        encode_times.out_lufs,
    );

    Ok(MasterRewrite {
        trim_head_ms: cut_head_ms as u32,
        trim_tail_ms: cut_tail_ms as u32,
        lead_ms: new_lead_ms as u32,
        tail_ms: new_tail_ms as u32,
        bpm,
        lufs,
        lufs_applied,
        bitrate_kbps: if kbps == 0 {
            average_kbps(&input_path, samples_for_bpm, rate_for_bpm.max(1))
        } else {
            kbps
        },
        rewritten,
        residual_ms,
    })
}

/// Dónde muere la energía del outro: inicio (ms absolutos) de la última racha
/// de ≥ 0.4 s por debajo de -32 dBFS en los últimos ~12 s. 0 = no hay.
/// Reemplaza al antiguo `ffmpeg silencedetect`.
pub fn outro_energy_end_ms(input_path: String, duration_ms: u64) -> u64 {
    if duration_ms < 20_000 {
        return 0;
    }
    let seek = (duration_ms.saturating_sub(12_000) / 1000) as u32;
    let d = match decode_channels(&input_path, seek, 14, 1) {
        Ok(d) => d,
        Err(_) => return 0,
    };
    let x = &d.ch[0];
    let win = (d.rate as usize / 100).max(1); // 10 ms
    let need = 40; // 0.4 s
    let thr_db = -32.0f32;
    let mut run = 0usize;
    let mut last_start: Option<usize> = None;
    let mut idx = 0usize;
    let mut run_start = 0usize;
    for w in x.chunks(win) {
        let e = w.iter().map(|v| v * v).sum::<f32>() / w.len() as f32;
        let db = 10.0 * e.max(1e-12).log10();
        if db < thr_db {
            if run == 0 {
                run_start = idx;
            }
            run += 1;
            if run >= need {
                last_start = Some(run_start);
            }
        } else {
            run = 0;
        }
        idx += 1;
    }
    match last_start {
        Some(w) => d.start_ms + (w as u64) * 10,
        None => 0,
    }
}

// ───────────────────────── Grabador Master-Out ─────────────────────────

struct RecHandle {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    join: std::thread::JoinHandle<Result<(), String>>,
}

static REC: std::sync::Mutex<Option<RecHandle>> = std::sync::Mutex::new(None);

pub fn is_master_recording() -> bool {
    REC.lock().map(|g| g.is_some()).unwrap_or(false)
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn rec_stream<T>(
    dev: &cpal::Device,
    cfg: &cpal::StreamConfig,
    tx: std::sync::mpsc::Sender<Vec<f32>>,
) -> Result<cpal::Stream, String>
where
    T: cpal::SizedSample,
    f32: cpal::FromSample<T>,
{
    use cpal::traits::DeviceTrait;
    dev.build_input_stream(
        cfg,
        move |data: &[T], _| {
            let v: Vec<f32> = data.iter().map(|s| (*s).to_sample::<f32>()).collect();
            let _ = tx.send(v);
        },
        |e| eprintln!("[rec] {e}"),
        None,
    )
    .map_err(|e| e.to_string())
}

/// Graba la salida master a MP3 320 kbps. Windows: loopback WASAPI del
/// dispositivo de salida. macOS: entrada de audio predeterminada.
/// Android/iOS: no disponible (el sistema lo veta).
#[cfg(any(target_os = "windows", target_os = "macos"))]
pub fn start_master_recording(output_path: String, bitrate_kbps: u32) -> Result<(), String> {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc};

    let mut guard = REC.lock().map_err(|_| "estado corrupto".to_string())?;
    if guard.is_some() {
        return Err("Ya se está grabando".to_string());
    }
    let stop = Arc::new(AtomicBool::new(false));
    let stop2 = stop.clone();
    let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();

    let join = std::thread::spawn(move || -> Result<(), String> {
        let setup =
            || -> Result<(cpal::Stream, mpsc::Receiver<Vec<f32>>, Mp3Sink, usize), String> {
                let host = cpal::default_host();
                #[cfg(target_os = "windows")]
                let (dev, conf) = {
                    let d = host
                        .default_output_device()
                        .ok_or("Sin dispositivo de salida")?;
                    let c = d.default_output_config().map_err(|e| e.to_string())?;
                    (d, c)
                };
                #[cfg(target_os = "macos")]
                let (dev, conf) = {
                    let d = host
                        .default_input_device()
                        .ok_or("Sin dispositivo de entrada")?;
                    let c = d.default_input_config().map_err(|e| e.to_string())?;
                    (d, c)
                };
                let ch = conf.channels() as usize;
                let rate = conf.sample_rate().0;
                let (tx, rx) = mpsc::channel::<Vec<f32>>();
                let cfg: cpal::StreamConfig = conf.clone().into();
                let stream = match conf.sample_format() {
                    cpal::SampleFormat::F32 => rec_stream::<f32>(&dev, &cfg, tx)?,
                    cpal::SampleFormat::I16 => rec_stream::<i16>(&dev, &cfg, tx)?,
                    cpal::SampleFormat::U16 => rec_stream::<u16>(&dev, &cfg, tx)?,
                    cpal::SampleFormat::I32 => rec_stream::<i32>(&dev, &cfg, tx)?,
                    f => return Err(format!("Formato de muestra no soportado: {f:?}")),
                };
                let sink = Mp3Sink::new(&output_path, rate, ch > 1, bitrate_kbps)?;
                stream.play().map_err(|e| e.to_string())?;
                Ok((stream, rx, sink, ch))
            };
        let (stream, rx, mut sink, ch) = match setup() {
            Ok(v) => {
                let _ = ready_tx.send(Ok(()));
                v
            }
            Err(e) => {
                let _ = ready_tx.send(Err(e.clone()));
                return Err(e);
            }
        };
        let mut result: Result<(), String> = Ok(());
        while !stop2.load(Ordering::Relaxed) {
            if let Ok(buf) = rx.recv_timeout(std::time::Duration::from_millis(100)) {
                if let Err(e) = sink.push(&buf, ch) {
                    result = Err(e);
                    break;
                }
            }
        }
        drop(stream);
        while let Ok(buf) = rx.try_recv() {
            if result.is_ok() {
                if let Err(e) = sink.push(&buf, ch) {
                    result = Err(e);
                }
            }
        }
        let fin = sink.finish().map(|_| ());
        result.and(fin)
    });

    match ready_rx.recv_timeout(std::time::Duration::from_secs(8)) {
        Ok(Ok(())) => {
            *guard = Some(RecHandle { stop, join });
            Ok(())
        }
        Ok(Err(e)) => {
            let _ = join.join();
            Err(e)
        }
        Err(_) => {
            stop.store(true, Ordering::Relaxed);
            Err("El grabador no arrancó a tiempo".to_string())
        }
    }
}

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
pub fn start_master_recording(_output_path: String, _bitrate_kbps: u32) -> Result<(), String> {
    Err("La grabación Master-Out no está disponible en este sistema".to_string())
}

/// Detiene la grabación y cierra el MP3 (flush de LAME).
pub fn stop_master_recording() -> Result<(), String> {
    let h = {
        let mut g = REC.lock().map_err(|_| "estado corrupto".to_string())?;
        g.take()
    };
    match h {
        None => Ok(()),
        Some(h) => {
            h.stop.store(true, std::sync::atomic::Ordering::Relaxed);
            h.join.join().map_err(|_| "El grabador falló".to_string())?
        }
    }
}

// ════════════════════════════════════════════════════════════════════════
//  KARAOKE IA (MDX-Net / UVR, ONNX) — 100 % Rust, sin Python ni FFmpeg
//  Modelo: UVR-MDX-NET-Inst_HQ_3.onnx (entrada [1,4,3072,256], salida = pista
//  instrumental). Inferencia con tract (Rust puro, corre en las 4 plataformas).
// ════════════════════════════════════════════════════════════════════════

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

static KAR_PROGRESS: AtomicU32 = AtomicU32::new(0);
static KAR_CANCEL: AtomicBool = AtomicBool::new(false);

const K_FFT: usize = 7680;
const K_HOP: usize = 1024;
const K_DIM_F: usize = 3072;
const K_DIM_T: usize = 256;
const K_COMPENSATE: f32 = 1.022;
const K_RATE: u32 = 44100;

/// Progreso 0.0‥1.0 de la pista que se está separando.
pub fn karaoke_progress() -> f64 {
    KAR_PROGRESS.load(Ordering::Relaxed) as f64 / 1000.0
}

/// Pide detener la separación en curso (corta en el siguiente bloque).
pub fn karaoke_cancel() {
    KAR_CANCEL.store(true, Ordering::Relaxed);
}

struct KStft {
    fwd: std::sync::Arc<dyn rustfft::Fft<f32>>,
    inv: std::sync::Arc<dyn rustfft::Fft<f32>>,
    win: Vec<f32>,
}

impl KStft {
    fn new() -> Self {
        let mut p = rustfft::FftPlanner::<f32>::new();
        let win = (0..K_FFT)
            .map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / K_FFT as f32).cos())
            .collect();
        KStft {
            fwd: p.plan_fft_forward(K_FFT),
            inv: p.plan_fft_inverse(K_FFT),
            win,
        }
    }

    /// x: K_HOP*(K_DIM_T-1) muestras → escribe re/im en `re`/`im` [K_DIM_F][K_DIM_T].
    fn forward(&self, x: &[f32], re: &mut [f32], im: &mut [f32]) {
        let half = K_FFT / 2;
        let l = x.len();
        let mut p = vec![0f32; l + K_FFT];
        for i in 0..half {
            p[i] = x[half - i];
            p[half + l + i] = x[l - 2 - i];
        }
        p[half..half + l].copy_from_slice(x);
        let mut buf = vec![rustfft::num_complex::Complex32::new(0.0, 0.0); K_FFT];
        for t in 0..K_DIM_T {
            for n in 0..K_FFT {
                buf[n] = rustfft::num_complex::Complex32::new(p[t * K_HOP + n] * self.win[n], 0.0);
            }
            self.fwd.process(&mut buf);
            for k in 0..K_DIM_F {
                re[k * K_DIM_T + t] = buf[k].re;
                im[k * K_DIM_T + t] = buf[k].im;
            }
        }
    }

    /// Inversa: re/im [K_DIM_F][K_DIM_T] → `out_len` muestras.
    fn inverse(&self, re: &[f32], im: &[f32], out_len: usize) -> Vec<f32> {
        let half = K_FFT / 2;
        let total = K_HOP * (K_DIM_T - 1) + K_FFT;
        let mut ola = vec![0f32; total];
        let mut wsum = vec![0f32; total];
        let mut buf = vec![rustfft::num_complex::Complex32::new(0.0, 0.0); K_FFT];
        for t in 0..K_DIM_T {
            for b in buf.iter_mut() {
                *b = rustfft::num_complex::Complex32::new(0.0, 0.0);
            }
            for k in 0..K_DIM_F {
                let c =
                    rustfft::num_complex::Complex32::new(re[k * K_DIM_T + t], im[k * K_DIM_T + t]);
                buf[k] = c;
                if k > 0 {
                    buf[K_FFT - k] = c.conj();
                }
            }
            self.inv.process(&mut buf);
            let off = t * K_HOP;
            for n in 0..K_FFT {
                let w = self.win[n];
                ola[off + n] += buf[n].re / K_FFT as f32 * w;
                wsum[off + n] += w * w;
            }
        }
        (0..out_len)
            .map(|i| {
                let w = wsum[half + i];
                if w > 1e-11 {
                    ola[half + i] / w
                } else {
                    0.0
                }
            })
            .collect()
    }
}

type KInfer = Box<dyn FnMut(&[f32]) -> Result<Vec<f32>, String>>;

/// Escritorio (Windows/macOS): ONNX Runtime oficial (MIT). Máximo 2 hilos.
#[cfg(any(target_os = "windows", target_os = "macos"))]
fn karaoke_backend(model_path: &str) -> Result<KInfer, String> {
    use ort::session::{builder::GraphOptimizationLevel, Session};
    use ort::value::Tensor;
    let mut session = Session::builder()
        .map_err(|e| e.to_string())?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| e.to_string())?
        .with_intra_threads(master_worker_cap())
        .map_err(|e| e.to_string())?
        .with_inter_threads(1)
        .map_err(|e| e.to_string())?
        .with_parallel_execution(false)
        .map_err(|e| e.to_string())?
        .commit_from_file(model_path)
        .map_err(|e| format!("Modelo inválido: {e}"))?;
    Ok(Box::new(move |data: &[f32]| {
        let t = Tensor::from_array(([1usize, 4, K_DIM_F, K_DIM_T], data.to_vec()))
            .map_err(|e| e.to_string())?;
        let outs = session.run(ort::inputs![t]).map_err(|e| e.to_string())?;
        let (_, o) = outs[0]
            .try_extract_tensor::<f32>()
            .map_err(|e| e.to_string())?;
        Ok(o.to_vec())
    }))
}

/// Resto de plataformas (Android/iOS): tract, Rust puro (sin binarios nativos
/// que compilar). Más lento; el celular sigue vetado en la UI.
#[cfg(not(any(target_os = "windows", target_os = "macos")))]
fn karaoke_backend(model_path: &str) -> Result<KInfer, String> {
    use tract_onnx::prelude::*;
    let model = tract_onnx::onnx()
        .model_for_path(model_path)
        .map_err(|e| format!("Modelo inválido: {e}"))?
        .with_input_fact(0, f32::fact([1, 4, K_DIM_F, K_DIM_T]).into())
        .map_err(|e| e.to_string())?
        .into_optimized()
        .map_err(|e| e.to_string())?
        .into_runnable()
        .map_err(|e| e.to_string())?;
    let pool =
        tract_onnx::tract_core::internal::multithread::Executor::multithread(master_worker_cap());
    Ok(Box::new(move |data: &[f32]| {
        let input =
            Tensor::from_shape(&[1, 4, K_DIM_F, K_DIM_T], data).map_err(|e| e.to_string())?;
        let out = tract_onnx::tract_core::internal::multithread::multithread_tract_scope(
            pool.clone(),
            || model.run(tvec!(input.into())),
        )
        .map_err(|e| e.to_string())?;
        Ok(out[0]
            .as_slice::<f32>()
            .map_err(|e| e.to_string())?
            .to_vec())
    }))
}

/// Separa la voz y escribe la pista instrumental como MP3 320 kbps.
/// `model_path` = UVR-MDX-NET-Inst_HQ_3.onnx. Sin Python ni FFmpeg.
pub fn karaoke_separate(
    input_path: String,
    model_path: String,
    output_path: String,
) -> Result<bool, String> {
    if !on_worker_thread() {
        return run_on_master_worker(move || karaoke_separate(input_path, model_path, output_path));
    }
    let _prio = PriorityGuard::enter();
    KAR_CANCEL.store(false, Ordering::Relaxed);
    KAR_PROGRESS.store(0, Ordering::Relaxed);

    let dec = decode_channels(&input_path, 0, 1800, 2)?;
    let mut chans: Vec<Vec<f32>> = if dec.ch.len() == 1 {
        vec![dec.ch[0].clone(), dec.ch[0].clone()]
    } else {
        dec.ch
    };
    if dec.rate != K_RATE {
        for c in chans.iter_mut() {
            let fr: Vec<(f32, f32)> = c.iter().map(|v| (*v, *v)).collect();
            let mut rs = Resampler::new(dec.rate, K_RATE);
            let mut o = Vec::with_capacity(fr.len() * K_RATE as usize / dec.rate as usize + 8);
            rs.process(&fr, &mut o);
            *c = o.into_iter().map(|p| p.0).collect();
        }
    }
    let n = chans[0].len();
    if n < K_RATE as usize {
        return Err("Pista demasiado corta".to_string());
    }

    let mut infer = karaoke_backend(&model_path)?;

    let trim = K_FFT / 2;
    let chunk = K_HOP * (K_DIM_T - 1);
    let gen = chunk - 2 * trim;
    let n_chunks = (n + gen - 1) / gen;
    let total_len = trim * 2 + n_chunks * gen;
    let mut padded: Vec<Vec<f32>> = Vec::with_capacity(2);
    for c in chans.iter().take(2) {
        let mut p = vec![0f32; total_len];
        p[trim..trim + n].copy_from_slice(c);
        padded.push(p);
    }
    drop(chans);

    let stft = KStft::new();
    let plane = K_DIM_F * K_DIM_T;
    let mut result: Vec<Vec<f32>> = vec![Vec::with_capacity(n_chunks * gen); 2];
    let mut data = vec![0f32; 4 * plane];

    for ci in 0..n_chunks {
        if KAR_CANCEL.load(Ordering::Relaxed) {
            return Err("Cancelado".to_string());
        }
        let start = ci * gen;
        for ch in 0..2 {
            let seg = &padded[ch][start..start + chunk];
            let (a, b) = data[(ch * 2) * plane..(ch * 2 + 2) * plane].split_at_mut(plane);
            stft.forward(seg, a, b);
        }
        let o = infer(&data)?;
        for ch in 0..2 {
            let re = &o[(ch * 2) * plane..(ch * 2 + 1) * plane];
            let im = &o[(ch * 2 + 1) * plane..(ch * 2 + 2) * plane];
            let w = stft.inverse(re, im, chunk);
            result[ch].extend(w[trim..trim + gen].iter().map(|v| v * K_COMPENSATE));
        }
        KAR_PROGRESS.store((((ci + 1) * 1000) / n_chunks) as u32, Ordering::Relaxed);
    }

    let tmp = format!("{output_path}.part");
    let mut sink = Mp3Sink::new(&tmp, K_RATE, true, 320)?;
    let mut inter: Vec<f32> = Vec::with_capacity(1 << 20);
    let mut i = 0usize;
    while i < n {
        let end = (i + (1 << 19)).min(n);
        inter.clear();
        for j in i..end {
            inter.push(result[0][j]);
            inter.push(result[1][j]);
        }
        sink.push(&inter, 2)?;
        i = end;
    }
    sink.finish()?;
    let _ = std::fs::remove_file(&output_path);
    std::fs::rename(&tmp, &output_path).map_err(|e| e.to_string())?;
    KAR_PROGRESS.store(1000, Ordering::Relaxed);
    Ok(true)
}

#[cfg(test)]
mod gapless_tests {
    use super::*;

    /// Codifica un chirrido con un inicio conocido, lo decodifica y comprueba
    /// que saltar el delay ANOTADO EN EL TAG (no una constante) deja el
    /// transitorio a ≤ 1 ms. Antes de saltarlo el desfase es mayor.
    #[test]
    fn el_tag_lame_alinea_el_transitorio() {
        let rate = 44100u32;
        let lead = rate as usize / 5;
        let burst = rate as usize * 3 / 10;
        let tail = rate as usize / 10;
        let mut pcm = vec![0f32; lead + burst + tail];
        let mut phase = 0.0f32;
        for i in 0..burst {
            let p = i as f32 / burst as f32;
            let hz = 180.0 + p * 3600.0;
            phase += std::f32::consts::TAU * hz / rate as f32;
            pcm[lead + i] = phase.sin() * 0.55;
        }

        let dir = std::env::temp_dir().join(format!("gmx_gapless_{}_{}", std::process::id(), rate));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("burst.mp3");
        let path_s = path.to_string_lossy().to_string();

        let mut sink = Mp3Sink::new(&path_s, rate, false, 320).unwrap();
        sink.push(&pcm, 1).unwrap();
        let gap = sink.finish().unwrap();
        assert_eq!(gap.residual_ms, 0, "con el tag escrito no queda retardo");
        assert!(gap.delay_samples > 0 && gap.delay_samples <= 3000);
        assert!(gap.padding_samples > 0 && gap.padding_samples <= 3000);

        let bytes = std::fs::read(&path_s).unwrap();
        let (delay, padding) = read_lame_delay_padding(&bytes).expect("tag LAME");
        assert_eq!(delay, gap.delay_samples);
        assert_eq!(padding, gap.padding_samples);

        let mut tag = Tag::new();
        tag.set_title("gapless");
        tag.write_to_path(&path_s, Version::Id3v24).unwrap();
        let tagged = std::fs::read(&path_s).unwrap();
        let (delay_id3, padding_id3) =
            read_lame_delay_padding(&tagged).expect("el tag sobrevive al ID3");
        assert_eq!((delay_id3, padding_id3), (delay, padding));

        let decoded = decode_mono(&path_s);
        // FFmpeg (libmpv) no emite el frame Info y se salta
        // `enc_delay + 528 + 1`: el delay leído del tag más el retardo fijo
        // del decodificador MPEG-1 Layer III (LAME encoder.h / get_audio.c).
        // 528 no es un 70 mágico: sale de sumar ese retardo al delay del tag.
        let skip = delay + 528 + 1;
        assert!(
            decoded.len() > skip as usize,
            "el MP3 decodificado es demasiado corto ({})",
            decoded.len()
        );

        let before = best_lag(&pcm, &decoded);
        let one_ms = (rate / 1000) as i32;
        assert!(
            before.abs() > one_ms,
            "antes de aplicar el tag el desfase es {before} muestras; se esperaba el priming del encoder"
        );
        assert!(
            (before - skip as i32).abs() <= one_ms,
            "el priming medido ({before}) no coincide con delay del tag + retardo MPEG-1 ({skip})"
        );

        let lag = best_lag(&pcm, &decoded[skip as usize..]);
        assert!(
            lag.abs() <= one_ms,
            "tras saltar {skip} muestras (delay={delay} + 529) el desfase es {lag} ({:.2} ms), tope 1 ms. padding={padding} antes={before}",
            lag.abs() as f32 * 1000.0 / rate as f32
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    fn decode_mono(path: &str) -> Vec<f32> {
        let mut out = Vec::new();
        decode_frames(path, false, |_rate, nch, inter| {
            let nch = nch.max(1);
            for frame in inter.chunks(nch) {
                out.push(frame[0]);
            }
            Ok(())
        })
        .unwrap();
        out
    }

    /// `lag` > 0: `got` llega tarde respecto de `reference`.
    fn best_lag(reference: &[f32], got: &[f32]) -> i32 {
        let max_lag = 44100 * 120 / 1000;
        let mut best = 0i32;
        let mut best_score = f64::MIN;
        let n = reference
            .len()
            .min(got.len())
            .min(rate_window(reference.len()));
        for lag in -max_lag..=max_lag {
            let mut score = 0.0f64;
            let mut used = 0i32;
            for i in 0..n {
                let j = i as i32 + lag;
                if j < 0 || (j as usize) >= got.len() {
                    continue;
                }
                score += reference[i] as f64 * got[j as usize] as f64;
                used += 1;
            }
            if used < 1000 {
                continue;
            }
            if score > best_score {
                best_score = score;
                best = lag;
            }
        }
        best
    }

    fn rate_window(len: usize) -> usize {
        len.min(44100)
    }

    /// El mismo salto, aplicado dentro del decodificador que usa el master.
    #[test]
    fn el_decode_gapless_deja_el_transitorio_a_1ms() {
        let rate = 44100u32;
        let lead = rate as usize / 5;
        let burst = rate as usize * 3 / 10;
        let tail = rate as usize / 10;
        let mut pcm = vec![0f32; lead + burst + tail];
        let mut phase = 0.0f32;
        for i in 0..burst {
            let p = i as f32 / burst as f32;
            let hz = 180.0 + p * 3600.0;
            phase += std::f32::consts::TAU * hz / rate as f32;
            pcm[lead + i] = phase.sin() * 0.55;
        }
        let dir =
            std::env::temp_dir().join(format!("gmx_gapless_on_{}_{}", std::process::id(), rate));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("burst.mp3");
        let path_s = path.to_string_lossy().to_string();
        let mut sink = Mp3Sink::new(&path_s, rate, false, 320).unwrap();
        sink.push(&pcm, 1).unwrap();
        sink.finish().unwrap();

        let mut heard = Vec::new();
        decode_frames(&path_s, true, |_rate, nch, inter| {
            let nch = nch.max(1);
            for frame in inter.chunks(nch) {
                heard.push(frame[0]);
            }
            Ok(())
        })
        .unwrap();
        let lag = best_lag(&pcm, &heard);
        let one_ms = (rate / 1000) as i32;
        assert!(
            lag.abs() <= one_ms,
            "gapless dejó {lag} muestras ({:.3} ms)",
            lag.abs() as f32 * 1000.0 / rate as f32
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod master_guard_tests {
    use super::*;

    #[test]
    fn el_medido_pisa_la_etiqueta_previa() {
        // Bad Case: el archivo trae 144 y el medido es 146,67. Se queda el medido.
        assert_eq!(resolve_bpm(Some(146.67), 144.0), 146.67);
        assert_eq!(resolve_bpm(Some(144.71), 146.70), 144.71);
        assert_eq!(resolve_bpm(Some(141.18), 144.0), 141.18);
        assert_eq!(resolve_bpm(None, 108.0), 0.0);
        let libre = resolve_bpm(Some(141.184), 0.0);
        assert!((libre - 141.18).abs() < 0.011, "{libre}");
        let (v, _) = parse_tbpm_text("144.00").unwrap();
        assert_eq!(v, 144.0);
        let (h, _) = parse_tbpm_text("17312").unwrap();
        assert!((h - 173.12).abs() < 1e-9, "17312 → {h}");
        let (a, _) = parse_tbpm_text("09548").unwrap();
        assert!((a - 95.48).abs() < 1e-9, "09548 → {a}");
        let (b, _) = parse_tbpm_text("08635").unwrap();
        assert!((b - 86.35).abs() < 1e-9, "08635 → {b}");
        let (c, _) = parse_tbpm_text("08571").unwrap();
        assert!((c - 85.71).abs() < 1e-9, "08571 → {c}");
        let (k, _) = parse_tbpm_text("146,70").unwrap();
        assert!((k - 146.70).abs() < 1e-9, "coma → {k}");
        assert_eq!(format_tbpm(146.666), "146.67");
        assert!(!format_tbpm(173.12).contains(','), "el punto no es coma");
        assert_eq!(format_tbpm(173.12), "173.12");
        let (v, _) = parse_tbpm_text(" 144 \0").unwrap();
        assert_eq!(v, 144.0);
        let (v, _) = parse_tbpm_text("144\0\0").unwrap();
        assert_eq!(v, 144.0);
        assert!(parse_tbpm_text("").is_none());
        assert!(parse_tbpm_text("0").is_none());
    }

    #[test]
    fn el_lag_4_3_se_queda_con_el_tbpm_previo() {
        let env_rate = 200.0;
        let lag_144 = ((60.0 * env_rate / 144.0) as f64).round() as usize;
        let lag_108 = ((60.0 * env_rate / 108.0) as f64).round() as usize;
        let mut scores = vec![0.0; lag_108 + 8];
        scores[lag_144] = 10.0;
        scores[lag_108] = 4.0;
        let picked =
            lag_matching_prior(lag_144 as f64, &scores, env_rate, 20, lag_108 + 4, 108.0).unwrap();
        let bpm = 60.0 * env_rate / picked;
        assert!(
            near_bpm(bpm, 108.0),
            "eligió {bpm} (lag {picked}) en vez del TBPM 108"
        );
        assert!(bpm < 120.0, "no debía quedarse en 144");
    }

    fn id3v2(payload: usize) -> Vec<u8> {
        let mut v = vec![b'I', b'D', b'3', 4, 0, 0];
        let s = payload;
        v.push(((s >> 21) & 0x7f) as u8);
        v.push(((s >> 14) & 0x7f) as u8);
        v.push(((s >> 7) & 0x7f) as u8);
        v.push((s & 0x7f) as u8);
        v.extend(std::iter::repeat(0xAB).take(payload));
        v
    }

    fn ape_footer() -> [u8; 32] {
        let mut f = [0u8; 32];
        f[0..8].copy_from_slice(b"APETAGEX");
        f[8..12].copy_from_slice(&2000u32.to_le_bytes());
        f[12..16].copy_from_slice(&32u32.to_le_bytes());
        f
    }

    #[test]
    fn el_kbps_ignora_id3_y_el_vbr_no_se_queda_en_el_primer_frame() {
        let secs = 10.0;
        let samples = (44100.0 * secs) as u64;
        let audio_len = 200_000usize;
        let mut audio = vec![0u8; audio_len];
        audio[0..4].copy_from_slice(&[0xFF, 0xFB, 0xA0, 0x00]);
        let mut file = id3v2(140_000);
        file.extend_from_slice(&audio);
        file.extend_from_slice(&ape_footer());
        file.extend_from_slice(b"TAG");
        file.extend(std::iter::repeat(0u8).take(125));

        let (start, end) = audio_byte_range(&file);
        assert_eq!(end - start, audio_len);
        let from_audio = kbps_of_audio((end - start) as u64, samples, 44100);
        assert_eq!(from_audio, 160);
        let naive = kbps_of_audio(file.len() as u64, samples, 44100);
        assert!(
            naive > 250,
            "con la carátula el promedio inflado es {naive}"
        );
        // ID3 y APE fuera: 160 se queda en 160. La carátula no entra en el promedio.
        assert_eq!(average_from_audio(&file[start..end], samples, 44100), 160);
        assert!(matches!(
            bitrate_at_most(160),
            mp3lame_encoder::Bitrate::Kbps160
        ));
        // 125 kbps reales, primer frame a 64 (el fallo VBR: antes capaba a 64 → 96).
        let mut vbr = vec![0u8; 156_250];
        vbr[0..4].copy_from_slice(&[0xFF, 0xFB, 0x50, 0x00]);
        assert_eq!(mpeg_bitrate_kbps(&vbr), Some(64));
        assert_eq!(average_from_audio(&vbr, samples, 44100), 128);
        assert!(matches!(
            bitrate_at_most(128),
            mp3lame_encoder::Bitrate::Kbps128
        ));
        // Xing manda aunque el buffer sea corto: 156250 bytes / 10 s = 125 → 128.
        let mut xing = vec![0u8; 80];
        xing[0..4].copy_from_slice(&[0xFF, 0xFB, 0x50, 0x00]);
        xing[36..40].copy_from_slice(b"Xing");
        xing[40..44].copy_from_slice(&0x0000_0002u32.to_be_bytes());
        xing[44..48].copy_from_slice(&156_250u32.to_be_bytes());
        assert_eq!(average_from_audio(&xing, samples, 44100), 128);
        // VBRI, mismo promedio.
        let mut vbri = vec![0u8; 80];
        vbri[0..4].copy_from_slice(&[0xFF, 0xFB, 0x50, 0x00]);
        vbri[36..40].copy_from_slice(b"VBRI");
        vbri[46..50].copy_from_slice(&156_250u32.to_be_bytes());
        assert_eq!(average_from_audio(&vbri, samples, 44100), 128);
        assert_eq!(cap_kbps(192.0), 192);
        assert_eq!(cap_kbps(192.2), 224);
        assert_eq!(cap_kbps(400.0), 320);
    }

    #[test]
    fn el_doble_por_encima_de_150_exige_17() {
        assert!((apply_double_guard(88.93, 177.86, 1.60) - 88.93).abs() < 1e-6);
        assert!((apply_double_guard(88.93, 177.86, 1.70) - 177.86).abs() < 1e-6);
        assert!((apply_double_guard(80.0, 160.0, 1.69) - 80.0).abs() < 1e-9);
        assert!((apply_double_guard(80.0, 160.0, 1.70) - 160.0).abs() < 1e-9);
        assert!((apply_double_guard(60.25, 120.5, 1.2) - 120.5).abs() < 1e-9);
        assert!((apply_double_guard(180.0, 180.0, 1.0) - 180.0).abs() < 1e-9);
        assert!((apply_double_guard(117.18, 117.18, 0.4) - 117.18).abs() < 1e-9);
        assert!((apply_double_guard(95.01, 190.02, 1.60) - 95.01).abs() < 1e-6);
        assert!((apply_double_guard(96.18, 192.36, 1.60) - 96.18).abs() < 1e-6);
    }

    struct OldLim {
        n: usize,
        gain: f32,
        att: f32,
        rel: f32,
        ceiling: f32,
        bl: std::collections::VecDeque<f32>,
        br: std::collections::VecDeque<f32>,
    }

    impl OldLim {
        fn new(rate: u32, ceiling: f32) -> Self {
            let n = ((rate as usize) * 5 / 1000).max(8);
            let att = 1.0 - (-1.0_f32 / (0.001 * rate as f32)).exp();
            let rel = 1.0 - (-1.0_f32 / (0.080 * rate as f32)).exp();
            Self {
                n,
                gain: 1.0,
                att,
                rel,
                ceiling,
                bl: std::collections::VecDeque::new(),
                br: std::collections::VecDeque::new(),
            }
        }

        fn push(&mut self, l: f32, r: f32) -> Option<(f32, f32)> {
            self.bl.push_back(l);
            self.br.push_back(r);
            if self.bl.len() <= self.n {
                return None;
            }
            let peak = old_buf_peak(&self.bl).max(old_buf_peak(&self.br));
            let target = if peak > self.ceiling {
                self.ceiling / peak
            } else {
                1.0
            };
            let c = if target < self.gain {
                self.att
            } else {
                self.rel
            };
            self.gain += (target - self.gain) * c;
            Some((
                self.bl.pop_front().unwrap_or(0.0) * self.gain,
                self.br.pop_front().unwrap_or(0.0) * self.gain,
            ))
        }

        fn flush(mut self) -> Vec<(f32, f32)> {
            let mut o = Vec::with_capacity(self.bl.len());
            while let Some(l) = self.bl.pop_front() {
                let r = self.br.pop_front().unwrap_or(l);
                o.push((l * self.gain, r * self.gain));
            }
            o
        }
    }

    fn old_buf_peak(buf: &std::collections::VecDeque<f32>) -> f32 {
        let mut hist = [0f32; 4];
        let mut peak = 0.0f32;
        for &s in buf.iter() {
            consider_peak(&mut hist, s, &mut peak);
        }
        peak
    }

    fn run_lim(samples: &[(f32, f32)], rate: u32, ceiling: f32, new_lim: bool) -> Vec<(f32, f32)> {
        let mut out = Vec::with_capacity(samples.len());
        if new_lim {
            let mut lim = LookLim::new(rate, ceiling);
            for &(l, r) in samples {
                if let Some(p) = lim.push(l, r) {
                    out.push(p);
                }
            }
            out.extend(lim.flush());
        } else {
            let mut lim = OldLim::new(rate, ceiling);
            for &(l, r) in samples {
                if let Some(p) = lim.push(l, r) {
                    out.push(p);
                }
            }
            out.extend(lim.flush());
        }
        out
    }

    #[test]
    fn el_limitador_nuevo_iguala_al_viejo_y_el_encode_informa_etapas() {
        let _g = guard_master();
        let rate = 44100u32;
        let n = rate as usize * 2;
        let mut state = 0x00C0_FFEEu32;
        let mut samples = Vec::with_capacity(n);
        for i in 0..n {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let noise = ((state >> 8) as f32 / 16_777_216.0) * 2.0 - 1.0;
            let s = (i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin();
            let mut l = s * 0.55 + noise * 0.04;
            let mut r = (i as f32 * 330.0 * std::f32::consts::TAU / rate as f32).sin() * 0.40
                + noise * 0.03;
            if i % 640 == 0 {
                l = 1.15;
                r = -1.05;
            }
            samples.push((l, r));
        }
        let ceiling = TP_LIMIT;
        let t0 = std::time::Instant::now();
        let old = run_lim(&samples, rate, ceiling, false);
        let old_ms = t0.elapsed().as_millis();
        let t1 = std::time::Instant::now();
        let new = run_lim(&samples, rate, ceiling, true);
        let new_ms = t1.elapsed().as_millis();
        assert_eq!(old.len(), new.len());
        let mut max_abs = 0.0f32;
        let mut max_db = 0.0f32;
        for ((a, b), (c, d)) in old.iter().zip(new.iter()) {
            max_abs = max_abs.max((a - c).abs()).max((b - d).abs());
            for (x, y) in [(a, c), (b, d)] {
                let xa = x.abs().max(1e-12);
                let ya = y.abs().max(1e-12);
                max_db = max_db.max((20.0 * (xa / ya).log10()).abs());
            }
        }
        eprintln!(
            "LIMIT_FIXTURE samples={n} old_ms={old_ms} new_ms={new_ms} max_abs={max_abs:.3e} max_db={max_db:.4}"
        );
        assert!(
            max_abs == 0.0 || max_db <= 0.01,
            "el limitador se fue {max_db:.4} dB (abs {max_abs:.3e})"
        );

        let secs = 4usize;
        let mut pcm = vec![0f32; rate as usize * secs];
        for (i, s) in pcm.iter_mut().enumerate() {
            *s = (i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 0.22;
        }
        let mut at = rate as usize / 2;
        while at + 40 < pcm.len() {
            for k in 0..40 {
                pcm[at + k] = 0.98;
            }
            at += rate as usize / 2;
        }
        let dir = std::env::temp_dir().join(format!("gmx_limfix_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("fix.mp3");
        let path_s = path.to_string_lossy().to_string();
        let (residual, times) = encode_master_span(
            &pcm,
            &path_s,
            rate,
            1,
            pcm.len() as u64,
            0,
            0,
            1.0,
            true,
            192,
        )
        .unwrap();
        eprintln!(
            "ENCODE_FIXTURE limit_ms={} encode_ms={} verify_ms={} reencode_ms={} encodes={} out_lufs={:.2} residual_ms={residual}",
            times.limit_ms, times.encode_ms, times.verify_ms, times.reencode_ms, times.encodes, times.out_lufs
        );
        assert!(times.encodes >= 1 && times.encodes <= 2);
        assert!(
            (times.out_lufs - TARGET_LUFS).abs() <= LUFS_TOL,
            "LUFS {:.2}",
            times.out_lufs
        );
        let measured = measure_stream(&path_s).unwrap();
        assert!(
            measured.true_peak <= TP_CEILING,
            "TP {}",
            measured.true_peak
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn guard_master() -> std::sync::MutexGuard<'static, ()> {
        static L: std::sync::Mutex<()> = std::sync::Mutex::new(());
        L.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[test]
    fn errores_de_decodificacion_tolerables() {
        let r = 44100u32;
        let four_min = r as u64 * 240;
        assert!(decode_errors_tolerable(0, 0, 0));
        assert!(decode_errors_tolerable(1, four_min, r));
        assert!(decode_errors_tolerable(30, four_min, r));
        assert!(!decode_errors_tolerable(78, four_min, r));
        assert!(!decode_errors_tolerable(81, four_min, r));
        assert!(!decode_errors_tolerable(200, four_min, r));
        // Archivo de 1 s: un paquete ya es 2,6 % → bloquea.
        assert!(!decode_errors_tolerable(1, r as u64, r));
        assert!(!decode_errors_tolerable(1, 0, r));
    }

    #[test]
    fn regla_de_bordes_en_silencio() {
        let r = 44100u64;
        let guard = r / 4;
        let (fl, ll) = (r, 200 * r); // suena de 1 s a 200 s
                                     // Cabeza en silencio: se perdona.
        assert_eq!(
            count_silent_edge_errors(&[(0, true), (r / 2, true)], fl, true, ll, guard),
            2
        );
        // Cola ≥ 250 ms tras el último sonido: se perdona; antes, no.
        assert_eq!(
            count_silent_edge_errors(&[(ll + guard, true)], fl, true, ll, guard),
            1
        );
        assert_eq!(
            count_silent_edge_errors(&[(ll + guard - 1, true)], fl, true, ll, guard),
            0
        );
        // En plena música nunca.
        assert_eq!(
            count_silent_edge_errors(&[(100 * r, true)], fl, true, ll, guard),
            0
        );
        // Sin reservorio inválido no cuenta aunque esté en el borde.
        assert_eq!(
            count_silent_edge_errors(&[(0, false)], fl, true, ll, guard),
            0
        );
        // Pista sin sonido fuerte: solo la cabeza (todo) cuenta, la cola no aplica.
        assert_eq!(
            count_silent_edge_errors(&[(5, true)], u64::MAX, false, 0, guard),
            1
        );
        // Y los perdonados no bloquean: 300 errores en bordes, 0 dentro.
        let m = StreamMeasure {
            rate: 44100,
            channels: 2,
            samples: 240 * r,
            mono_ms: vec![],
            k_ms: vec![],
            true_peak: 0.5,
            decode_errors: 300,
            silent_edge_errors: 300,
        };
        assert_eq!(blocking_decode_errors(&m), 0);
        let m2 = StreamMeasure {
            silent_edge_errors: 100,
            ..m
        };
        assert_eq!(blocking_decode_errors(&m2), 200);
    }

    #[test]
    fn un_paquete_roto_se_repara_sin_perdida_y_masteriza() {
        let _g = guard_master();
        let dir = std::env::temp_dir().join(format!("gmx_badpack_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rota.mp3");
        let path_s = path.to_string_lossy().to_string();
        let rate = 44100u32;
        let mut pcm = vec![0f32; rate as usize];
        for (i, s) in pcm.iter_mut().enumerate() {
            *s = (i as f32 * 0.07).sin() * 0.4;
        }
        let mut sink = Mp3Sink::new(&path_s, rate, false, 160).unwrap();
        sink.push(&pcm, 1).unwrap();
        sink.finish().unwrap();

        let mut bytes = std::fs::read(&path_s).unwrap();
        let (a0, a1) = audio_byte_range(&bytes);
        let audio_before = bytes[a0..a1].to_vec();
        let mid = a0 + (a1 - a0) / 2;
        let end = (mid + 400).min(a1);
        for b in &mut bytes[mid..end] {
            *b = 0;
        }
        std::fs::write(&path_s, &bytes).unwrap();

        let skipped = decode_frames(&path_s, false, |_r, _n, _s| Ok(())).unwrap();
        assert!(skipped > 0, "el MP3 roto no produjo DecodeError");

        let mut tag = Tag::new();
        tag.set_text("TBPM", "108");
        tag.write_to_path(&path_s, Version::Id3v24).unwrap();
        let before = std::fs::read(&path_s).unwrap();
        let (b0, b1) = audio_byte_range(&before);
        let audio_tagged = before[b0..b1].to_vec();

        // 1.0.12+26: la Etapa 2 repara sin pérdida (quita los frames rotos),
        // re-mide y, como ya no bloquea, masteriza. El original queda en .bak.
        let rw = master_rewrite(path_s.clone(), true, true, false, -1, -1).unwrap();
        assert!(rw.rewritten, "tras reparar debía masterizar");
        let bak = format!("{path_s}.prerepair.bak");
        let bak_bytes = std::fs::read(&bak).expect("falta .prerepair.bak");
        let (d0, d1) = audio_byte_range(&bak_bytes);
        assert_eq!(
            &bak_bytes[d0..d1],
            audio_tagged.as_slice(),
            "el .bak debe ser el original"
        );
        let t = Tag::read_from_path(&path_s).unwrap();
        let resc = t
            .extended_texts()
            .find(|e| e.description == KEY_RESCUE)
            .map(|e| e.value.clone())
            .unwrap_or_default();
        assert!(resc.starts_with("REPAIR:"), "rescue={resc}");
        let marks = read_gmx_marks(path_s.clone());
        assert!(marks.reason.is_empty(), "motivo={}", marks.reason);
        assert!(marks.lufs_done);
        let _ = audio_before;
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn id3_frame(ver: u8, encoding: u8, text: &[u8]) -> Vec<u8> {
        let mut body = vec![encoding];
        body.extend_from_slice(text);
        let mut tag = vec![b'I', b'D', b'3', ver, 0, 0, 0, 0, 0, 0];
        let mut frame = Vec::new();
        if ver == 2 {
            frame.extend_from_slice(b"TBP");
            let n = body.len();
            frame.push(((n >> 16) & 0xff) as u8);
            frame.push(((n >> 8) & 0xff) as u8);
            frame.push((n & 0xff) as u8);
        } else {
            frame.extend_from_slice(b"TBPM");
            let n = body.len() as u32;
            if ver == 4 {
                frame.push(((n >> 21) & 0x7f) as u8);
                frame.push(((n >> 14) & 0x7f) as u8);
                frame.push(((n >> 7) & 0x7f) as u8);
                frame.push((n & 0x7f) as u8);
            } else {
                frame.extend_from_slice(&n.to_be_bytes());
            }
            frame.extend_from_slice(&[0, 0]);
        }
        frame.extend_from_slice(&body);
        let size = frame.len() as u32;
        tag[6] = ((size >> 21) & 0x7f) as u8;
        tag[7] = ((size >> 14) & 0x7f) as u8;
        tag[8] = ((size >> 7) & 0x7f) as u8;
        tag[9] = (size & 0x7f) as u8;
        tag.extend_from_slice(&frame);
        tag
    }

    fn utf16_le(text: &str) -> Vec<u8> {
        let mut v = vec![0xFF, 0xFE];
        for u in text.encode_utf16() {
            v.extend_from_slice(&u.to_le_bytes());
        }
        v.extend_from_slice(&[0, 0]);
        v
    }

    #[test]
    fn el_tbpm_se_lee_en_v23_v24_y_utf16() {
        let (v, _) = tbpm_in_id3(&id3_frame(3, 0, b"144.00\0")).unwrap();
        assert_eq!(v, 144.0);
        let (v, _) = tbpm_in_id3(&id3_frame(3, 0, b" 144 \0\0")).unwrap();
        assert_eq!(v, 144.0);
        let (v, _) = tbpm_in_id3(&id3_frame(4, 3, b"144.00")).unwrap();
        assert_eq!(v, 144.0);
        let (v, _) = tbpm_in_id3(&id3_frame(3, 1, &utf16_le("144.00"))).unwrap();
        assert_eq!(v, 144.0);
        let (v, _) = tbpm_in_id3(&id3_frame(4, 1, &utf16_le("144"))).unwrap();
        assert_eq!(v, 144.0);
        assert!(lufs_encode_decision(true, -13.67, TP_CEILING, 0));
        assert!(!lufs_encode_decision(true, -14.0, TP_CEILING, 0));
        assert!(!lufs_encode_decision(
            true,
            TARGET_LUFS + LUFS_TOL,
            TP_CEILING,
            0
        ));
        assert!(!lufs_encode_decision(
            true,
            TARGET_LUFS - LUFS_TOL,
            TP_CEILING,
            0
        ));
        assert!(lufs_encode_decision(
            true,
            TARGET_LUFS + LUFS_TOL + 0.01,
            TP_CEILING,
            0
        ));
        assert!(!lufs_encode_decision(true, -13.67, TP_CEILING, 3));
        assert!(lufs_encode_decision(true, -14.0, TP_CEILING + 0.01, 0));
    }

    #[test]
    fn un_tbpm_de_144_no_pasa_a_141_y_el_lufs_fuera_se_recodifica() {
        let _g = guard_master();
        let dir = std::env::temp_dir().join(format!("gmx_tbpm144_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("callme.mp3");
        let path_s = path.to_string_lossy().to_string();
        let rate = 44100u32;
        let secs = 2usize;
        let mut pcm = vec![0f32; rate as usize * secs];
        for (i, s) in pcm.iter_mut().enumerate() {
            *s = (i as f32 * 2.0 * std::f32::consts::PI * 440.0 / rate as f32).sin() * 0.2;
        }
        let mut sink = Mp3Sink::new(&path_s, rate, false, 192).unwrap();
        sink.push(&pcm, 1).unwrap();
        sink.finish().unwrap();

        let audio = std::fs::read(&path_s).unwrap();
        let tag = id3_frame(3, 1, &utf16_le("144.00"));
        let mut file = tag.clone();
        file.extend_from_slice(&audio);
        std::fs::write(&path_s, &file).unwrap();
        let (got, _) = tbpm_in_id3(&std::fs::read(&path_s).unwrap()).unwrap();
        assert_eq!(got, 144.0);

        let before = average_kbps(&path_s, (rate as u64) * secs as u64, rate);
        let src = measure_stream(&path_s).unwrap();
        let src_lufs = lufs_of(&src.k_ms);
        assert!(
            (src_lufs - TARGET_LUFS).abs() > LUFS_TOL,
            "el seno de prueba salió en {src_lufs}, fuera del caso −13,67"
        );
        let rw = master_rewrite(path_s.clone(), false, true, false, -1, -1).unwrap();
        assert!(rw.rewritten, "LUFS {src_lufs} debía recodificar");
        assert!(
            rw.bitrate_kbps <= before,
            "subió el bitrate de {before} a {}",
            rw.bitrate_kbps
        );
        let after = Tag::read_from_path(&path_s).unwrap();
        let kept = stored_bpm(&path_s, &after).unwrap();
        let text = after
            .get("TBPM")
            .and_then(|f| f.content().text())
            .unwrap_or("")
            .to_string();
        if text == "144.00" || text.starts_with("144") {
            assert!(
                (kept.value - 144.0).abs() < 0.02,
                "el tono no debía inventar {}",
                kept.value
            );
        } else {
            assert!(text.contains('.'), "TBPM sin punto: {text}");
            assert!(!text.contains(','), "TBPM con coma: {text}");
            assert!(
                (kept.value - 144.0).abs() > 0.5,
                "repitió 144 sin medirlo: {text}"
            );
        }
        let out = measure_stream(&path_s).unwrap();
        let out_lufs = lufs_of(&out.k_ms);
        assert!(out.true_peak <= TP_CEILING, "TP {}", out.true_peak);
        assert!(
            (out_lufs - TARGET_LUFS).abs() <= LUFS_TOL,
            "el encode dejó {out_lufs}"
        );

        let mut tag = Tag::read_from_path(&path_s).unwrap();
        tag.remove_extended_text(Some(KEY_LUFS_DONE), None);
        tag.remove_extended_text(Some(KEY_LUFS), None);
        tag.write_to_path(&path_s, Version::Id3v24).unwrap();
        let again = master_rewrite(path_s.clone(), false, true, false, -1, -1).unwrap();
        let still = stored_bpm(&path_s, &Tag::read_from_path(&path_s).unwrap()).unwrap();
        assert_eq!(still.value, 144.0);
        let quiet = measure_stream(&path_s).unwrap();
        let quiet_lufs = lufs_of(&quiet.k_ms);
        if (quiet_lufs - TARGET_LUFS).abs() <= LUFS_TOL && quiet.true_peak <= TP_CEILING {
            assert!(
                !again.rewritten,
                "dentro de ±0,3 no se recodifica ({quiet_lufs})"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn clicks(bpm: f64, seconds: f64) -> Vec<f32> {
        let rate = 44100.0;
        let n = (rate * seconds) as usize;
        let mut pcm = vec![0f32; n];
        let period = (rate * 60.0 / bpm).round() as usize;
        let mut i = period;
        // Un impulso de unas 9 ms: la ventana de 22 ms del onset complejo lo ve.
        let click = 400usize;
        while i + click < n {
            for k in 0..click {
                let env = (-6.0 * k as f32 / click as f32).exp();
                let v = if k % 2 == 0 { 1.0 } else { -1.0 };
                pcm[i + k] = 0.85 * env * v;
            }
            i += period;
        }
        pcm
    }

    #[test]
    fn sin_tbpm_previo_no_parte_un_tempo_de_pop() {
        // Rekordbox: ×2 o ÷2 solo para entrar en 60–180. Dentro del rango no se elige octava.
        assert!((super::fold_display_bpm(169.0, 60.0, 180.0) - 169.0).abs() < 1e-9);
        assert!((super::fold_display_bpm(89.0, 60.0, 180.0) - 89.0).abs() < 1e-9);
        assert!((super::fold_display_bpm(62.0, 60.0, 180.0) - 62.0).abs() < 1e-9);
        assert!((super::fold_display_bpm(84.5, 60.0, 180.0) - 84.5).abs() < 1e-9);
        let up = super::fold_display_bpm(42.0, 60.0, 180.0);
        assert!(
            (up - 84.0).abs() < 1e-6,
            "42 debía entrar como 84 y salió {up}"
        );
        let down = super::fold_display_bpm(220.0, 60.0, 180.0);
        assert!(
            (down - 110.0).abs() < 1e-6,
            "220 debía entrar como 110 y salió {down}"
        );

        let near = |got: f64, want: f64| (got - want).abs() < 3.0;
        let hello = detect_bpm(&clicks(62.0, 12.0), 44100, None).expect("62");
        assert!(near(hello, 62.0), "Hello quedó en {hello}");
        let mirlos = detect_bpm(&clicks(89.0, 12.0), 44100, None).expect("89");
        assert!(near(mirlos, 89.0), "Los Mirlos quedó en {mirlos}");
        let aha = detect_bpm(&clicks(169.0, 12.0), 44100, None).expect("169");
        assert!(near(aha, 169.0), "Take On Me quedó en {aha}");

        let mut con_guiro = clicks(89.0, 12.0);
        let step = ((44100.0 * 60.0 / 178.0) as f64).round() as usize;
        let mut i = step;
        while i + 4 < con_guiro.len() {
            con_guiro[i] += 0.35;
            i += step;
        }
        let guiro = detect_bpm(&con_guiro, 44100, None).expect("guiro");
        assert!(
            near(guiro, 89.0),
            "la cumbia con subdivisión quedó en {guiro}"
        );

        let kept = detect_bpm(&clicks(108.0, 12.0), 44100, Some(108.0)).expect("108");
        assert!((kept - 108.0).abs() < 3.0, "TBPM 108 pasó a {kept}");
        let plain = detect_bpm(&clicks(110.0, 12.0), 44100, Some(110.0)).expect("110");
        assert!((plain - 110.0).abs() < 3.0, "TBPM 110 pasó a {plain}");
        let prior169 = detect_bpm(&clicks(84.5, 12.0), 44100, Some(169.0)).expect("prior 169");
        assert!(
            (prior169 - 169.0).abs() < 4.0 || (prior169 - 84.5).abs() < 4.0,
            "con TBPM 169 no debía inventar otro tempo: {prior169}"
        );
    }

    fn clics_exactos(bpm: f64, seconds: f64, noise: f32, jitter: i32) -> Vec<f32> {
        let rate = 44100.0_f32;
        let n = (rate as f64 * seconds) as usize;
        let mut pcm = vec![0.0f32; n];
        let mut state = 0x00C0_FFEEu32;
        if noise > 0.0 {
            for v in &mut pcm {
                state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                *v = ((state >> 8) as f32 / 16_777_216.0) * 2.0 * noise - noise;
            }
        }
        let period = rate as f64 * 60.0 / bpm;
        let mut k = 2.0_f64;
        while (k * period) as usize + 600 < n {
            let wobble = if jitter == 0 {
                0
            } else {
                ((k as i32 * 3) % (jitter * 2 + 1)) - jitter
            };
            let at = (k * period).round() as i32 + wobble;
            if at > 80 {
                burst(&mut pcm, at as usize, rate, 12.0, 0.9);
            }
            k += 1.0;
        }
        pcm
    }

    #[test]
    fn bpm_decimal_ruido_jitter_y_metrica() {
        let casos = [
            (146.67, "Palmer"),
            (144.71, "Kiss"),
            (104.09, "Sandra"),
            (154.42, "Loverboy"),
            (139.95, "Two Princes"),
            (86.56, "Words Fell Down"),
            (171.46, "Boys Will Be Boys"),
            (105.75, "How Gee"),
            (60.25, "lento"),
            (180.0, "techo"),
        ];
        let mut fails = Vec::new();
        for (bpm, name) in casos {
            let clean = detect_bpm(&clics_exactos(bpm, 24.0, 0.0, 0), 44100, Some(999.0));
            let got = clean.unwrap_or(0.0);
            if (got - bpm).abs() > 0.02 {
                fails.push(format!("{name} limpio {got:.4} vs {bpm}"));
            }
            let half = if bpm / 2.0 >= 60.0 {
                bpm / 2.0
            } else {
                bpm * 2.0
            };
            let third = bpm * 3.0 / 4.0;
            let fourth = bpm * 4.0 / 3.0;
            assert!((got - half).abs() > 1.0, "{name} saltó de octava a {got}");
            if (60.0..=180.0).contains(&third) {
                assert!((got - third).abs() > 1.0, "{name} cayó en ×3/4 {got}");
            }
            if (60.0..=180.0).contains(&fourth) {
                assert!((got - fourth).abs() > 1.0, "{name} cayó en ×4/3 {got}");
            }
            let dirty = detect_bpm(&clics_exactos(bpm, 28.0, 0.02, 12), 44100, None).unwrap_or(0.0);
            if (dirty - bpm).abs() > 0.02 {
                fails.push(format!(
                    "{name} sucio {dirty:.4} vs {bpm} Δ{:.4}",
                    (dirty - bpm).abs()
                ));
            }
        }
        assert!(fails.is_empty(), "{}", fails.join(" | "));
    }

    fn tone(pcm: &mut [f32], at: usize, freq: f32, rate: f32, ms: f32, amp: f32) {
        let n = ((rate * ms / 1000.0) as usize).min(pcm.len().saturating_sub(at));
        for i in 0..n {
            let env = (-4.0 * i as f32 / n.max(1) as f32).exp();
            let s = (i as f32 * freq * std::f32::consts::TAU / rate).sin();
            pcm[at + i] += amp * env * s;
        }
    }

    fn burst(pcm: &mut [f32], at: usize, rate: f32, ms: f32, amp: f32) {
        let n = ((rate * ms / 1000.0) as usize).min(pcm.len().saturating_sub(at));
        for i in 0..n {
            let env = (-6.0 * i as f32 / n.max(1) as f32).exp();
            let v = if i % 2 == 0 { 1.0 } else { -1.0 };
            pcm[at + i] += amp * env * v;
        }
    }

    /// `kind` 0 = caja a contratiempo, 1 = grave y medio juntos, 2 = bajo + guiro suave al doble.
    fn ritmo(bpm: f64, seconds: f64, kind: u8) -> Vec<f32> {
        let rate = 44100.0f32;
        let n = (rate as f64 * seconds) as usize;
        let mut pcm = vec![0f32; n];
        let period = rate as f64 * 60.0 / bpm;
        let mut k = 0.0;
        while (k * period) as usize + 800 < n {
            let at = (k * period) as usize;
            let even = (k as usize) % 2 == 0;
            match kind {
                0 => {
                    // El mismo ataque en cada tiempo (el tactus). La caja solo
                    // colorea el contratiempo; no es otro periodo.
                    burst(&mut pcm, at, rate, 20.0, 0.7);
                    if even {
                        tone(&mut pcm, at, 70.0, rate, 45.0, 0.55);
                    } else {
                        tone(&mut pcm, at, 380.0, rate, 40.0, 0.35);
                        tone(&mut pcm, at, 900.0, rate, 30.0, 0.25);
                    }
                }
                1 => {
                    tone(&mut pcm, at, 82.0, rate, 90.0, 0.85);
                    tone(&mut pcm, at, 240.0, rate, 70.0, 0.40);
                }
                _ => {
                    tone(&mut pcm, at, 78.0, rate, 70.0, 0.9);
                    let half = at + (period * 0.5) as usize;
                    burst(&mut pcm, half, rate, 12.0, 0.12);
                }
            }
            k += 1.0;
        }
        pcm
    }

    #[test]
    fn el_peine_separa_bombo_y_caja_sin_tbpm() {
        let near = |got: f64, want: f64| (got - want).abs() < 3.0;
        let mut fails = Vec::new();
        let pop = detect_bpm(&ritmo(169.0, 16.0, 0), 44100, None).expect("169");
        if !near(pop, 169.0) {
            fails.push(format!("backbeat {pop:.2}"));
        }
        let ballad = detect_bpm(&ritmo(62.0, 16.0, 1), 44100, None).expect("62");
        if !near(ballad, 62.0) || (ballad - 124.0).abs() <= 8.0 {
            fails.push(format!("balada {ballad:.2}"));
        }
        let cumbia = detect_bpm(&ritmo(89.0, 16.0, 2), 44100, None).expect("89");
        if !near(cumbia, 89.0) {
            fails.push(format!("cumbia {cumbia:.2}"));
        }
        let kept = detect_bpm(&clicks(108.0, 12.0), 44100, Some(108.0)).expect("108");
        if (kept - 108.0).abs() >= 3.0 {
            fails.push(format!("tbpm {kept:.2}"));
        }
        assert!(fails.is_empty(), "{}", fails.join(" | "));
    }

    #[test]
    #[ignore = "MP3 reales en /tmp/gmx_bpm"]
    fn tempo_de_tres_canciones_reales() {
        let dir = std::env::var("GMX_BPM_DIR").unwrap_or_else(|_| "/tmp/gmx_bpm".to_string());
        // Bandas de aceptación del audio real. El estimador no las conoce.
        let cases = [
            ("take_on_me.mp3", 167.0, 171.0),
            ("take_on_me_single.mp3", 167.0, 171.0),
            ("hello.mp3", 60.0, 64.0),
            // Este máster de Grandes Éxitos corre un pelo por encima de 92.
            ("mirlos.mp3", 89.0, 93.0),
            // 12" de The Heat Is On: el pulso cae en 148±3.
            ("heat12.mp3", 145.0, 151.0),
            // Pocket Rockers es otra copia: el pulso medido está en ~152, no en 76.
            ("heat.mp3", 149.0, 156.0),
            ("blondie.mp3", 141.0, 147.0),
            // Siembra, este vinilo: el tactus queda en los 94, no en 129 ni en 188.
            ("pedro.mp3", 93.0, 105.0),
            ("prayer.mp3", 116.0, 128.0),
        ];
        let mut fails: Vec<String> = Vec::new();
        for (name, lo, hi) in cases {
            let path = format!("{dir}/{name}");
            if !std::path::Path::new(&path).exists() {
                fails.push(format!("falta {name}"));
                continue;
            }
            let (mut format, track_id, params) = super::open_format(&path).expect(&path);
            let rate = params.sample_rate.expect("rate");
            let tb = params.time_base.expect("tb");
            let mut total = 0u64;
            while let Ok(p) = format.next_packet() {
                if p.track_id() == track_id {
                    total += p.dur;
                }
            }
            let t = tb.calc_time(total);
            let samples = t.seconds * rate as u64 + (t.frac * rate as f64) as u64;
            let secs = samples as f64 / rate as f64;
            let got = match super::detect_validated(&path, samples, rate, false, None) {
                Some(b) => b,
                None => {
                    eprintln!("RESULTADO {name} -> none ({secs:.1}s)");
                    fails.push(format!("{name} sin BPM"));
                    continue;
                }
            };
            eprintln!("RESULTADO {name} -> {got:.2} (banda {lo:.0}–{hi:.0}, {secs:.0}s)");
            // Hello admite el tactus (~62) o el doble (~125). 117 es el fallo.
            if name == "hello.mp3" {
                let lento = (60.0..=64.0).contains(&got);
                let doble = (122.0..=128.0).contains(&got);
                if !lento && !doble {
                    fails.push(format!("{name} midió {got:.2}, se admite 60–64 o 122–128"));
                }
                continue;
            }
            let doubled = hi < 80.0 && (got - (lo + hi) * 0.5 * 2.0).abs() <= 8.0;
            if got < lo || got > hi || doubled {
                fails.push(format!("{name} midió {got:.2}, banda {lo:.0}–{hi:.0}"));
            }
        }
        // La misma cumbia, estirada al tempo que se cuenta (~89), no se va al doble.
        let mirlos = format!("{dir}/mirlos.mp3");
        let d = super::decode_channels(&mirlos, 50, 48, 2).expect("mirlos");
        let mono = super::to_mono(&d);
        let factor = 92.41 / 89.0;
        let n = (mono.len() as f64 * factor) as usize;
        let mut slowed = vec![0f32; n];
        for i in 0..n {
            let src = i as f64 / factor;
            let j = src.floor() as usize;
            let frac = (src - j as f64) as f32;
            let a = mono[j.min(mono.len() - 1)];
            let b = mono[(j + 1).min(mono.len() - 1)];
            slowed[i] = a + (b - a) * frac;
        }
        let got89 = super::detect_bpm(&slowed, d.rate, None).expect("89");
        eprintln!("RESULTADO mirlos estirado a 89 -> {got89:.2}");
        if (got89 - 89.0).abs() > 2.0 || (got89 - 178.0).abs() < 8.0 {
            fails.push(format!("la cumbia a 89 midió {got89:.2}"));
        }
        assert!(fails.is_empty(), "{}", fails.join(" | "));
    }

    #[test]
    fn el_pico_real_del_mp3_queda_en_menos_1() {
        let _g = guard_master();
        let rate = 44100u32;
        let n = rate as usize * 4;
        let mut pcm = vec![0f32; n];
        for i in 0..n {
            let body = (i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 0.22;
            pcm[i] = body;
        }
        let spike_every = rate as usize / 2;
        let mut at = spike_every;
        while at + 80 < n {
            for k in 0..40 {
                pcm[at + k] = 0.98;
            }
            at += spike_every;
        }
        let dir = std::env::temp_dir().join(format!("gmx_tp_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("hot.mp3");
        let path_s = path.to_string_lossy().to_string();
        let mut sink = Mp3Sink::new(&path_s, rate, false, 320).unwrap();
        sink.push(&pcm, 1).unwrap();
        sink.finish().unwrap();

        let rw = master_rewrite(path_s.clone(), true, true, false, -1, -1).unwrap();
        assert!(rw.lufs_applied, "el pico debía forzar la normalización");
        let measured = measure_stream(&path_s).unwrap();
        let dbtp = 20.0 * (measured.true_peak as f64).max(1e-9).log10();
        assert!(
            dbtp <= -1.0,
            "true peak {dbtp:.2} dBTP (lineal {})",
            measured.true_peak
        );
        let lufs = lufs_of(&measured.k_ms);
        assert!(
            (lufs - TARGET_LUFS).abs() <= LUFS_TOL,
            "LUFS {lufs:.2}, se pedía −14 ±0,3"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[ignore = "m4a de Gabriel en /tmp/gmx_m4a; no van al repo"]
    fn tempo_de_los_m4a_de_gabriel() {
        let dir = "/tmp/gmx_m4a";
        let mut fails: Vec<String> = Vec::new();
        for (name, lo, hi) in [("A.m4a", 167.0, 171.0), ("C.m4a", 89.0, 93.0)] {
            let path = format!("{dir}/{name}");
            let (samples, rate) = packet_samples(&path);
            let got = detect_validated(&path, samples, rate, false, None).expect(name);
            eprintln!(
                "RESULTADO {name} -> {got:.2} ({:.0}s)",
                samples as f64 / rate as f64
            );
            if got < lo || got > hi {
                fails.push(format!("{name} midió {got:.2}, banda {lo:.0}–{hi:.0}"));
            }
        }
        let path = format!("{dir}/B.m4a");
        let (samples, rate) = packet_samples(&path);
        let got = detect_validated(&path, samples, rate, false, None).expect("B");
        eprintln!(
            "RESULTADO B.m4a -> {got:.2} ({:.0}s)",
            samples as f64 / rate as f64
        );
        let ok = (got >= 60.0 && got <= 64.0) || (got >= 122.0 && got <= 128.0);
        if !ok {
            fails.push(format!("B.m4a midió {got:.2}, se admite 60–64 o 122–128"));
        }
        assert!(fails.is_empty(), "{}", fails.join(" | "));
    }

    fn packet_samples(path: &str) -> (u64, u32) {
        let (mut format, track_id, params) = open_format(path).expect(path);
        let rate = params.sample_rate.expect("rate");
        let tb = params.time_base.expect("tb");
        let mut total = 0u64;
        while let Ok(p) = format.next_packet() {
            if p.track_id() == track_id {
                total += p.dur;
            }
        }
        let t = tb.calc_time(total);
        let samples = t.seconds * rate as u64 + (t.frac * rate as f64) as u64;
        (samples, rate)
    }

    #[test]
    fn masterizar_una_pasada_conserva_lufs_y_corte() {
        let _g = guard_master();
        let rate = 44100u32;
        let lead = rate as usize / 2;
        let body = rate as usize * 3;
        let tail = (rate as usize) * 2 / 5;
        let mut pcm = vec![0f32; lead + body + tail];
        for i in 0..body {
            let s = (i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 0.05;
            pcm[lead + i] = s;
        }
        let dir = std::env::temp_dir().join(format!(
            "gmx_once_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tema.mp3");
        let path_s = path.to_string_lossy().to_string();
        let mut sink = Mp3Sink::new(&path_s, rate, false, 192).unwrap();
        sink.push(&pcm, 1).unwrap();
        sink.finish().unwrap();

        let before = measure_stream(&path_s).unwrap();
        let plan = plan_span(&before, true, true, -1, -1, 0.0);
        let rw = master_rewrite(path_s.clone(), true, true, false, -1, -1).unwrap();
        assert_eq!(
            rw.trim_head_ms as u64, plan.cut_head_ms,
            "el corte de cabeza cambió"
        );
        assert_eq!(
            rw.trim_tail_ms as u64, plan.cut_tail_ms,
            "el corte de cola cambió"
        );
        assert!(rw.lufs_applied || rw.rewritten);
        let out = measure_stream(&path_s).unwrap();
        let lufs = lufs_of(&out.k_ms);
        assert!(
            (lufs - TARGET_LUFS).abs() <= 0.5,
            "LUFS {lufs:.2}, se pedía −14 ±0,5"
        );
        assert!(out.true_peak <= TP_CEILING, "true peak {}", out.true_peak);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn analysis_actual_con_bpm_0_vuelve_a_medir() {
        let _g = guard_master();
        let dir = std::env::temp_dir().join(format!(
            "gmx_bpm0_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("clic.mp3");
        let path_s = path.to_string_lossy().to_string();
        let pcm = clicks(120.0, 20.0);
        let mut sink = Mp3Sink::new(&path_s, 44100, false, 160).unwrap();
        sink.push(&pcm, 1).unwrap();
        sink.finish().unwrap();
        let mut tag = Tag::new();
        tag.set_text("TBPM", "0.00");
        set_ext(&mut tag, KEY_ANALYSIS, ANALYSIS_V.to_string());
        set_ext(&mut tag, KEY_TRIM, "0".to_string());
        set_ext(&mut tag, KEY_LUFS_DONE, "-14".to_string());
        tag.write_to_path(&path_s, Version::Id3v24).unwrap();

        let rw = master_rewrite(path_s.clone(), true, true, false, -1, -1).unwrap();
        assert!(!rw.rewritten, "BPM 0 no debía recodificar el audio");
        assert!(
            (rw.bpm - 120.0).abs() < 3.0,
            "debía re-medir y salió {}",
            rw.bpm
        );

        let mut tag = Tag::read_from_path(&path_s).unwrap();
        tag.set_text("TBPM", "100.00");
        set_ext(&mut tag, KEY_ANALYSIS, ANALYSIS_V.to_string());
        tag.write_to_path(&path_s, Version::Id3v24).unwrap();
        let kept = refresh_analysis_tags(&path_s).unwrap();
        assert!(
            (kept - 100.0).abs() < 0.02,
            "con BPM > 0 no debía re-medir: {kept}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn la_x_borra_el_temporal_y_deja_el_original() {
        let _g = guard_master();
        master_arm();
        let dir = std::env::temp_dir().join(format!(
            "gmx_cancel_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tema.mp3");
        let path_s = path.to_string_lossy().to_string();
        let rate = 44100u32;
        let secs = 25usize;
        let mut pcm = vec![0f32; rate as usize * secs];
        for (i, s) in pcm.iter_mut().enumerate() {
            *s = (i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 0.9;
        }
        let mut sink = Mp3Sink::new(&path_s, rate, false, 192).unwrap();
        sink.push(&pcm, 1).unwrap();
        sink.finish().unwrap();
        let before = std::fs::read(&path_s).unwrap();
        let tmp = format!("{path_s}.gmxpart");
        let watch = tmp.clone();
        let killer = std::thread::spawn(move || {
            let start = std::time::Instant::now();
            while start.elapsed() < std::time::Duration::from_millis(400) {
                if std::path::Path::new(&watch).exists() {
                    master_cancel();
                    return;
                }
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            master_cancel();
        });
        let t = std::time::Instant::now();
        let err = match master_rewrite(path_s.clone(), true, true, false, -1, -1) {
            Err(e) => e,
            Ok(_) => panic!("la X debía cortar"),
        };
        let elapsed = t.elapsed();
        killer.join().unwrap();
        master_arm();
        assert!(
            err.contains("Cancelado"),
            "se esperaba Cancelado y llegó {err}"
        );
        assert!(
            elapsed < std::time::Duration::from_secs(2),
            "tardó {elapsed:?}"
        );
        assert_eq!(
            std::fs::read(&path_s).unwrap(),
            before,
            "el original cambió"
        );
        assert!(
            !std::path::Path::new(&tmp).exists(),
            "quedó el temporal {tmp}"
        );
        assert!(!std::path::Path::new(&format!("{path_s}.gmxside")).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod karaoke_tests {
    #[test]
    #[ignore]
    fn separa_pista_real() {
        let inp = std::env::var("KAR_IN").unwrap();
        let model = std::env::var("KAR_MODEL").unwrap();
        let out = std::env::var("KAR_OUT").unwrap();
        let t = std::time::Instant::now();
        std::thread::spawn(|| loop {
            std::thread::sleep(std::time::Duration::from_secs(10));
            println!("PROGRESO {:.1}%", super::karaoke_progress() * 100.0);
        });
        super::karaoke_separate(inp, model, out).unwrap();
        println!("TIEMPO {:?}", t.elapsed());
    }
}

#[cfg(test)]
mod priority_tests {
    #[test]
    fn el_escritorio_usa_dos_hilos_y_el_movil_uno() {
        assert_eq!(super::master_worker_cap(), 2);
    }

    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "ios")))]
    #[test]
    fn la_prioridad_es_nice_10_en_el_hilo_de_trabajo() {
        let main_before = super::nice_priority::current_nice();
        let label = std::thread::spawn(|| {
            let _g = super::PriorityGuard::enter();
            assert_eq!(super::nice_priority::current_nice(), 10);
            super::priority_label()
        })
        .join()
        .unwrap();
        assert_eq!(label, "nice10");
        assert_eq!(super::nice_priority::current_nice(), main_before);
    }
}

#[cfg(test)]
mod repair_probe {
    use super::*;
    /// Diagnóstico manual: GMX_REPAIR_DIR=<carpeta> cargo test --lib repair_probe -- --ignored --nocapture
    #[test]
    #[ignore]
    fn probe_dir() {
        let Ok(dir) = std::env::var("GMX_REPAIR_DIR") else {
            return;
        };
        let mut v: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().map(|x| x == "mp3").unwrap_or(false))
            .collect();
        v.sort();
        for p in v {
            let ps = p.to_string_lossy().to_string();
            let m = match measure_stream(&ps) {
                Ok(m) => m,
                Err(e) => {
                    println!("{ps}: measure err {e}");
                    continue;
                }
            };
            let data = std::fs::read(&ps).unwrap();
            let rep = crate::mp3_repair::repair_mp3(&data);
            let (sum, after) = match &rep {
                Some((fx, st)) => {
                    let t = format!("{ps}.probe.tmp");
                    std::fs::write(&t, fx).unwrap();
                    let m2 = measure_stream(&t);
                    let _ = std::fs::remove_file(&t);
                    (
                        st.summary(),
                        m2.map(|m| {
                            format!(
                                "err={} samples={} block={}",
                                m.decode_errors,
                                m.samples,
                                blocking_decode_errors(&m)
                            )
                        })
                        .unwrap_or_else(|e| e),
                    )
                }
                None => ("none".into(), "-".into()),
            };
            println!(
                "{}: before err={} samples={} rate={} block={} | repair {} | after {}",
                p.file_name().unwrap().to_string_lossy(),
                m.decode_errors,
                m.samples,
                m.rate,
                blocking_decode_errors(&m),
                sum,
                after
            );
        }
    }
}

#[cfg(test)]
mod err_probe {
    use super::*;
    #[test]
    #[ignore]
    fn where_errors() {
        let Ok(f) = std::env::var("GMX_ERR_FILE") else {
            return;
        };
        let (mut format, track_id, params) = open_format(&f).unwrap();
        let rate = params.sample_rate.unwrap() as f64;
        let mut dec = symphonia::default::get_codecs()
            .make(&params, &DecoderOptions::default())
            .unwrap();
        let mut hist: std::collections::BTreeMap<String, u32> = Default::default();
        let mut pos: Vec<f64> = vec![];
        loop {
            let Ok(p) = format.next_packet() else { break };
            if p.track_id() != track_id {
                continue;
            }
            let ts = p.ts() as f64 / rate;
            if let Err(e) = dec.decode(&p) {
                *hist.entry(format!("{e}")).or_default() += 1;
                pos.push(ts);
            }
        }
        println!("HIST {hist:?}");
        println!(
            "POS {:?}",
            pos.iter()
                .map(|x| (x * 10.0).round() / 10.0)
                .collect::<Vec<_>>()
        );
    }
}

#[cfg(test)]
mod master_probe {
    use super::*;
    /// GMX_MASTER_DIR=<copias> cargo test --release --lib master_probe -- --ignored --nocapture
    #[test]
    #[ignore]
    fn master_dir() {
        let Ok(dir) = std::env::var("GMX_MASTER_DIR") else {
            return;
        };
        let mut v: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().map(|x| x == "mp3").unwrap_or(false))
            .collect();
        v.sort();
        for p in v {
            let ps = p.to_string_lossy().to_string();
            let r = master_rewrite(ps.clone(), true, true, false, -1, -1);
            let t = Tag::read_from_path(&ps).ok();
            let g = |k: &str| {
                t.as_ref()
                    .and_then(|t| {
                        t.extended_texts()
                            .find(|e| e.description == k)
                            .map(|e| e.value.clone())
                    })
                    .unwrap_or_default()
            };
            match r {
                Ok(rw) => println!("{}: rewritten={} lufs_in={:.2} applied={} reason='{}' rescue='{}' lufs_done='{}'",
                    p.file_name().unwrap().to_string_lossy(), rw.rewritten, rw.lufs, rw.lufs_applied, g(KEY_REASON), g(KEY_RESCUE), g(KEY_LUFS_DONE)),
                Err(e) => println!("{}: ERR {e}", p.file_name().unwrap().to_string_lossy()),
            }
        }
    }
}
