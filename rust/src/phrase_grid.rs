//! Perfil de Phrase 8: RMS por frase de 8 compases y banda vocal 300 Hz–3,4 kHz.
//!
//! Misma fórmula que `lib/core/phrase_grid.dart`. Live DJ lo calcula una vez,
//! en segundo plano, sobre el PCM de `decode_mono_pcm`, y lo guarda en
//! `.gatomix.json`. El tick no entra aquí.

const VOCAL_MIN_RATIO: f64 = 0.35;
const VOCAL_MIN_RMS: f64 = 0.02;
const ENERGY_DROP: f64 = 0.55;
const FADE_MIN_MS: i64 = 8000;
const FADE_MAX_MS: i64 = 18000;

#[derive(Clone, Debug)]
pub struct PhrasePhrase {
    pub start_ms: i64,
    pub rms: f64,
    pub vocal: f64,
}

impl PhrasePhrase {
    pub fn vocal_on(&self) -> bool {
        self.vocal >= VOCAL_MIN_RATIO && self.rms >= VOCAL_MIN_RMS
    }
}

#[derive(Clone, Debug)]
pub struct PhraseTrack {
    pub bpm: f64,
    pub beat_ms: i64,
    pub duration_ms: i64,
    pub outro_ms: i64,
    pub intro_end_ms: i64,
    pub body_rms: f64,
    pub phrases: Vec<PhrasePhrase>,
}

impl PhraseTrack {
    pub fn phrase_at(&self, ms: i64) -> Option<&PhrasePhrase> {
        let mut best = None;
        for p in &self.phrases {
            if p.start_ms <= ms {
                best = Some(p);
            } else {
                break;
            }
        }
        best
    }
}

pub struct PhrasePlan {
    pub mix_out_ms: i64,
    pub cue_in_ms: i64,
    pub fade_ms: i64,
    pub energy_exit: bool,
    pub phrase_entry: bool,
    pub instrumental: bool,
}

pub fn phrase_sounding_bpm(incoming_bpm: f64, incoming_rate: f64) -> f64 {
    if !(60.0..=200.0).contains(&incoming_bpm) {
        return incoming_bpm;
    }
    if (0.88..=1.12).contains(&incoming_rate) {
        let sounded = incoming_bpm * incoming_rate;
        if (60.0..=200.0).contains(&sounded) {
            return sounded;
        }
    }
    incoming_bpm
}

pub fn phrase_grid_fade_ms(bpm: f64, instrumental: bool, duration_ms: i64) -> i64 {
    if (60.0..=200.0).contains(&bpm) {
        let bar = ((60000.0 / bpm) * 4.0).round() as i64;
        let span = bar * if instrumental { 16 } else { 8 };
        if span > 0 {
            return span.clamp(FADE_MIN_MS, FADE_MAX_MS);
        }
    }
    if duration_ms > 0 {
        return (((duration_ms as f64) * 0.06).round() as i64).clamp(FADE_MIN_MS, FADE_MAX_MS);
    }
    12000
}

pub fn phrase_cross_instrumental(
    outgoing: Option<&PhraseTrack>,
    incoming: Option<&PhraseTrack>,
    out_ms: i64,
    in_ms: i64,
) -> bool {
    let (Some(out), Some(inc)) = (outgoing, incoming) else {
        return false;
    };
    match (out.phrase_at(out_ms), inc.phrase_at(in_ms)) {
        (Some(a), Some(b)) => !a.vocal_on() && !b.vocal_on(),
        _ => false,
    }
}

pub fn plan_phrase8(
    out_duration_ms: i64,
    in_duration_ms: i64,
    fallback_mix_out_ms: i64,
    fallback_cue_ms: i64,
    incoming_bpm: f64,
    incoming_rate: f64,
    outgoing: Option<&PhraseTrack>,
    incoming: Option<&PhraseTrack>,
    lock_exit: bool,
) -> PhrasePlan {
    let mix_lo = if out_duration_ms <= 0 {
        0
    } else {
        (out_duration_ms as f64 * 0.60).round() as i64
    };
    let mix_hi = out_duration_ms - FADE_MIN_MS;
    let mut mix_out = fallback_mix_out_ms;
    let mut energy_exit = false;
    if !lock_exit {
        if let Some(out) = outgoing {
            if out.outro_ms >= mix_lo && mix_hi > mix_lo && out.outro_ms <= mix_hi {
                mix_out = out.outro_ms;
                energy_exit = true;
            }
        }
    }

    let in_bpm = if (60.0..=200.0).contains(&incoming_bpm) {
        incoming_bpm
    } else {
        incoming.map(|t| t.bpm).unwrap_or(0.0)
    };
    let cue_dur = if in_duration_ms > 0 {
        in_duration_ms
    } else {
        incoming.map(|t| t.duration_ms).unwrap_or(0)
    };
    let mut cue = fallback_cue_ms;
    let mut phrase_entry = false;
    if let Some(inc) = incoming {
        if (60.0..=200.0).contains(&in_bpm) && cue_dur > 30000 {
            if let Some(snapped) = entry_downbeat(inc, in_bpm, cue_dur, fallback_cue_ms) {
                cue = snapped;
                phrase_entry = true;
            }
        }
    }

    if let (Some(out), Some(inc)) = (outgoing, incoming) {
        if let (Some(out_ph), Some(in_ph)) = (out.phrase_at(mix_out), inc.phrase_at(cue)) {
            if out_ph.vocal_on() && in_ph.vocal_on() {
                if !lock_exit && mix_hi > mix_lo {
                    if let Some(moved) = nearest_non_vocal(out, mix_out, mix_lo, mix_hi) {
                        if moved != mix_out {
                            mix_out = moved;
                            energy_exit = out.outro_ms == moved;
                        }
                    }
                }
                if out.phrase_at(mix_out).map(|p| p.vocal_on()).unwrap_or(false) {
                    let cue_hi = if cue_dur > 0 {
                        ((cue_dur as f64) * 0.45).round() as i64
                    } else {
                        90000
                    }
                    .min(if cue_dur > 0 {
                        cue_dur - FADE_MIN_MS
                    } else {
                        90000
                    });
                    if let Some(moved_in) = nearest_non_vocal(inc, cue, 8000, cue_hi) {
                        if moved_in != cue {
                            cue = moved_in;
                            phrase_entry = true;
                        }
                    }
                }
            }
        }
    }

    let instrumental = phrase_cross_instrumental(outgoing, incoming, mix_out, cue);
    let sounded = phrase_sounding_bpm(if in_bpm >= 60.0 { in_bpm } else { incoming_bpm }, incoming_rate);
    PhrasePlan {
        mix_out_ms: mix_out,
        cue_in_ms: cue,
        fade_ms: phrase_grid_fade_ms(
            sounded,
            instrumental,
            if in_duration_ms > 0 { in_duration_ms } else { cue_dur },
        ),
        energy_exit,
        phrase_entry,
        instrumental,
    }
}

fn entry_downbeat(track: &PhraseTrack, bpm: f64, duration_ms: i64, fallback_cue_ms: i64) -> Option<i64> {
    let mut anchor = fallback_cue_ms;
    if duration_ms > 30000 && anchor < 10000 {
        anchor = 10000;
    }
    let intro = track.intro_end_ms;
    if intro >= 8000 && intro <= ((duration_ms as f64) * 0.40).round() as i64 && intro > anchor {
        anchor = intro;
    }
    let snapped = snap_up(anchor, track.beat_ms, bpm);
    let cap = ((duration_ms as f64) * 0.45).round() as i64;
    if snapped < 8000 || snapped > cap || snapped >= duration_ms - FADE_MIN_MS {
        return None;
    }
    Some(snapped)
}

fn snap_up(anchor_ms: i64, beat_ms: i64, bpm: f64) -> i64 {
    let phrase_ms = ((60000.0 / bpm) * 4.0).round() as i64 * 8;
    if phrase_ms <= 0 {
        return anchor_ms;
    }
    if anchor_ms <= beat_ms {
        return beat_ms;
    }
    let k = (anchor_ms - beat_ms + phrase_ms - 1) / phrase_ms;
    beat_ms + k * phrase_ms
}

fn nearest_non_vocal(track: &PhraseTrack, from_ms: i64, lo: i64, hi: i64) -> Option<i64> {
    if hi < lo {
        return None;
    }
    let mut best: Option<i64> = None;
    let mut best_dist = i64::MAX;
    for p in &track.phrases {
        if p.start_ms < lo || p.start_ms > hi || p.vocal_on() {
            continue;
        }
        let d = (p.start_ms - from_ms).abs();
        if best.is_none() || d < best_dist || (d == best_dist && p.start_ms < best.unwrap()) {
            best_dist = d;
            best = Some(p.start_ms);
        }
    }
    best
}

pub fn analyze_phrase_samples(samples: &[f32], sample_rate: u32, bpm: f64, beat_ms: i64) -> Option<PhraseTrack> {
    if sample_rate < 8000 || !(60.0..=200.0).contains(&bpm) || samples.is_empty() {
        return None;
    }
    let duration_ms = (samples.len() as f64 * 1000.0 / sample_rate as f64).round() as i64;
    let phrase_ms = ((60000.0 / bpm) * 4.0).round() as i64 * 8;
    if phrase_ms < 1000 || duration_ms < phrase_ms {
        return None;
    }
    let mut phrases = Vec::new();
    let mut start = beat_ms;
    while start < duration_ms {
        if start >= 0 {
            let end = (start + phrase_ms).min(duration_ms);
            if end - start < phrase_ms / 2 {
                break;
            }
            let i0 = ((start as f64) * sample_rate as f64 / 1000.0).round() as usize;
            let i1 = ((end as f64) * sample_rate as f64 / 1000.0).round() as usize;
            let i0 = i0.min(samples.len());
            let i1 = i1.clamp(i0, samples.len());
            if i1 <= i0 {
                break;
            }
            let (rms, vocal) = phrase_rms(&samples[i0..i1], sample_rate);
            phrases.push(PhrasePhrase {
                start_ms: start,
                rms,
                vocal,
            });
        }
        start += phrase_ms;
    }
    if phrases.is_empty() {
        return None;
    }
    let body: Vec<f64> = phrases
        .iter()
        .filter(|p| {
            (p.start_ms as f64) >= duration_ms as f64 * 0.15
                && (p.start_ms as f64) < duration_ms as f64 * 0.60
        })
        .map(|p| p.rms)
        .collect();
    let body_rms = if body.is_empty() {
        median(&phrases.iter().map(|p| p.rms).collect::<Vec<_>>())
    } else {
        median(&body)
    };
    let low_line = body_rms * ENERGY_DROP;
    let mut outro = -1;
    if body_rms > 0.0 {
        for i in 0..phrases.len() {
            if (phrases[i].start_ms as f64) < duration_ms as f64 / 2.0 {
                continue;
            }
            if phrases[i].rms > low_line {
                continue;
            }
            let sustained = i + 1 >= phrases.len() || phrases[i + 1].rms <= low_line;
            if !sustained {
                continue;
            }
            outro = phrases[i].start_ms;
            break;
        }
    }
    let mut intro = -1;
    if body_rms > 0.0 {
        let mut saw_low = false;
        for p in &phrases {
            if p.rms <= low_line {
                saw_low = true;
                continue;
            }
            if saw_low && p.start_ms <= ((duration_ms as f64) * 0.40).round() as i64 {
                intro = p.start_ms;
            }
            break;
        }
    }
    Some(PhraseTrack {
        bpm,
        beat_ms,
        duration_ms,
        outro_ms: outro,
        intro_end_ms: intro,
        body_rms,
        phrases,
    })
}

fn phrase_rms(samples: &[f32], rate: u32) -> (f64, f64) {
    let mut hp = Biquad::highpass(300.0, rate as f64);
    let mut lp = Biquad::lowpass(3400.0, rate as f64);
    let mut sum = 0.0;
    let mut sum_f = 0.0;
    for &x in samples {
        let x = x as f64;
        sum += x * x;
        let y = lp.tick(hp.tick(x));
        sum_f += y * y;
    }
    let n = samples.len() as f64;
    if n <= 0.0 || sum < 1e-12 {
        return (0.0, 0.0);
    }
    let rms = (sum / n).sqrt();
    let rms_f = (sum_f / n).sqrt();
    (rms, if rms <= 1e-8 { 0.0 } else { rms_f / rms })
}

fn median(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut xs = values.to_vec();
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = xs.len();
    if n % 2 == 1 {
        xs[n / 2]
    } else {
        (xs[n / 2 - 1] + xs[n / 2]) / 2.0
    }
}

struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,
}

struct Coef {
    cosw: f64,
    a0: f64,
    a1: f64,
    a2: f64,
}

impl Coef {
    fn new(fc: f64, fs: f64) -> Self {
        let w = std::f64::consts::TAU * fc / fs;
        let sinw = w.sin();
        let cosw = w.cos();
        let alpha = sinw / (2.0 * std::f64::consts::FRAC_1_SQRT_2);
        let a0 = 1.0 + alpha;
        Self {
            cosw,
            a0,
            a1: -2.0 * cosw / a0,
            a2: (1.0 - alpha) / a0,
        }
    }
}

impl Biquad {
    fn from_coef(b0: f64, b1: f64, b2: f64, c: &Coef) -> Self {
        Self {
            b0: b0 / c.a0,
            b1: b1 / c.a0,
            b2: b2 / c.a0,
            a1: c.a1,
            a2: c.a2,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
        }
    }

    fn highpass(fc: f64, fs: f64) -> Self {
        let c = Coef::new(fc, fs);
        let b0 = (1.0 + c.cosw) / 2.0;
        let b1 = -(1.0 + c.cosw);
        let b2 = (1.0 + c.cosw) / 2.0;
        Self::from_coef(b0, b1, b2, &c)
    }

    fn lowpass(fc: f64, fs: f64) -> Self {
        let c = Coef::new(fc, fs);
        let b0 = (1.0 - c.cosw) / 2.0;
        let b1 = 1.0 - c.cosw;
        let b2 = (1.0 - c.cosw) / 2.0;
        Self::from_coef(b0, b1, b2, &c)
    }

    fn tick(&mut self, x0: f64) -> f64 {
        let y0 = self.b0 * x0 + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x0;
        self.y2 = self.y1;
        self.y1 = y0;
        y0
    }
}

#[cfg(test)]
fn sine(seconds: f64, hz: f64, amp: f32, rate: u32) -> Vec<f32> {
    let n = (seconds * rate as f64).round() as usize;
    (0..n)
        .map(|i| amp * (std::f64::consts::TAU * hz * i as f64 / rate as f64).sin() as f32)
        .collect()
}

#[cfg(test)]
fn snap_mix(duration_ms: i64, bpm: f64) -> i64 {
    let dna = (duration_ms as f64 * 0.75) as i64;
    let bar = ((60000.0 / bpm) * 4.0).round() as i64;
    let phrase = bar * 8;
    let min_ms = (duration_ms as f64 * 0.60).round() as i64;
    let hard = duration_ms - 8000;
    let max_ms = dna.min(hard);
    if max_ms <= min_ms || phrase <= 0 {
        return dna;
    }
    let mut snapped = (max_ms / phrase) * phrase;
    if snapped < min_ms {
        snapped = ((min_ms + phrase - 1) / phrase) * phrase;
    }
    if snapped < min_ms || snapped > max_ms || snapped >= duration_ms - 8000 {
        return dna;
    }
    snapped
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: u32 = 22050;

    fn at(seconds: i64, bpm: f64, quiet_from: i64, quiet_until: i64) -> PhraseTrack {
        let mut samples = Vec::new();
        if quiet_until > 0 {
            samples.extend(sine(quiet_until as f64, 80.0, 0.05, RATE));
            samples.extend(sine((seconds - quiet_until) as f64, 80.0, 0.50, RATE));
        } else if quiet_from > 0 {
            samples.extend(sine(quiet_from as f64, 80.0, 0.50, RATE));
            samples.extend(sine((seconds - quiet_from) as f64, 80.0, 0.05, RATE));
        } else {
            samples.extend(sine(seconds as f64, 80.0, 0.50, RATE));
        }
        analyze_phrase_samples(&samples, RATE, bpm, 0).unwrap()
    }

    fn tone(seconds: i64, bpm: f64, hz: f64) -> PhraseTrack {
        let samples = sine(seconds as f64, hz, 0.5, RATE);
        analyze_phrase_samples(&samples, RATE, bpm, 0).unwrap()
    }

    #[test]
    fn outro_en_la_bajada_sostenida() {
        let drop = at(128, 120.0, 80, 0);
        assert_eq!(drop.outro_ms, 80000);
        let snap = snap_mix(128000, 120.0);
        let used = plan_phrase8(128000, 128000, snap, 10000, 120.0, 1.0, Some(&drop), Some(&drop), false);
        assert!(used.energy_exit);
        assert_eq!(used.mix_out_ms, 80000);
        assert_ne!(used.mix_out_ms, snap);

        let before = at(128, 120.0, 64, 0);
        assert_eq!(before.outro_ms, 64000);
        let backed = plan_phrase8(128000, 128000, snap, 10000, 120.0, 1.0, Some(&before), Some(&before), false);
        assert!(!backed.energy_exit);
        assert_eq!(backed.mix_out_ms, snap);

        let none = plan_phrase8(128000, 128000, snap, 10000, 120.0, 1.0, None, None, false);
        assert_eq!(none.mix_out_ms, snap);
        assert_eq!(none.cue_in_ms, 10000);
    }

    #[test]
    fn entrada_en_downbeat() {
        let intro = at(96, 120.0, 0, 16);
        assert_eq!(intro.intro_end_ms, 16000);
        let snap = snap_mix(96000, 120.0);
        let from_intro = plan_phrase8(96000, 96000, snap, 10000, 120.0, 1.0, Some(&intro), Some(&intro), false);
        assert!(from_intro.phrase_entry);
        assert_eq!(from_intro.cue_in_ms, 16000);

        let loud = at(96, 120.0, 0, 0);
        assert_eq!(loud.intro_end_ms, -1);
        let from_ten = plan_phrase8(96000, 96000, snap, 10000, 120.0, 1.0, Some(&loud), Some(&loud), false);
        assert_eq!(from_ten.cue_in_ms, 16000);
    }

    #[test]
    fn fade_adaptativo_y_bpm_entrante() {
        let low = tone(60, 128.0, 80.0);
        assert!(!low.phrases[0].vocal_on());
        let snap = snap_mix(60000, 128.0);
        let instrumental = plan_phrase8(60000, 60000, snap, 10000, 128.0, 1.0, Some(&low), Some(&low), false);
        assert!(instrumental.instrumental);
        assert_eq!(instrumental.fade_ms, 18000);

        let voice = tone(60, 128.0, 1000.0);
        assert!(voice.phrases[0].vocal_on());
        let vocal = plan_phrase8(60000, 60000, snap, 10000, 128.0, 1.0, Some(&voice), Some(&voice), false);
        assert!(!vocal.instrumental);
        assert_eq!(vocal.fade_ms, 15000);

        assert_eq!(phrase_grid_fade_ms(90.0, true, 200000), 18000);
        assert_eq!(phrase_grid_fade_ms(90.0, false, 200000), 18000);

        let sounded = phrase_sounding_bpm(128.0, 120.0 / 128.0);
        assert!((sounded - 120.0).abs() < 1e-9);
        let matched = plan_phrase8(
            60000,
            60000,
            snap,
            10000,
            128.0,
            120.0 / 128.0,
            Some(&voice),
            Some(&voice),
            false,
        );
        assert!(!matched.instrumental);
        assert_eq!(matched.fade_ms, 16000);
    }

    #[test]
    fn no_junta_voces() {
        let mut out = sine(64.0, 80.0, 0.5, RATE);
        out.extend(sine(16.0, 1000.0, 0.5, RATE));
        out.extend(sine(16.0, 80.0, 0.5, RATE));
        let outgoing = analyze_phrase_samples(&out, RATE, 120.0, 0).unwrap();
        let mut inc = sine(16.0, 80.0, 0.5, RATE);
        inc.extend(sine(16.0, 1000.0, 0.5, RATE));
        inc.extend(sine(16.0, 80.0, 0.5, RATE));
        inc.extend(sine(48.0, 1000.0, 0.5, RATE));
        let incoming = analyze_phrase_samples(&inc, RATE, 120.0, 0).unwrap();
        assert!(outgoing.phrase_at(64000).unwrap().vocal_on());
        assert!(!outgoing.phrase_at(80000).unwrap().vocal_on());
        assert!(incoming.phrase_at(16000).unwrap().vocal_on());
        let snap = snap_mix(96000, 120.0);
        let moved = plan_phrase8(96000, 96000, snap, 10000, 120.0, 1.0, Some(&outgoing), Some(&incoming), false);
        assert_eq!(moved.mix_out_ms, 80000);
        assert_eq!(moved.cue_in_ms, 16000);

        let all = tone(96, 120.0, 1000.0);
        let entry = plan_phrase8(96000, 96000, snap, 10000, 120.0, 1.0, Some(&all), Some(&incoming), false);
        assert_eq!(entry.mix_out_ms, snap);
        assert_eq!(entry.cue_in_ms, 32000);
        let stuck = plan_phrase8(96000, 96000, snap, 10000, 120.0, 1.0, Some(&all), Some(&all), false);
        assert_eq!(stuck.mix_out_ms, snap);
        assert_eq!(stuck.cue_in_ms, 16000);
    }
}
