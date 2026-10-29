//! BPM por la pendiente de los golpes, no por el pico del tempograma.
//!
//! La autocorrelación y el peine solo eligen la octava (el periodo con el que
//! Ellis coloca los golpes). Cada golpe se afina con interpolación parabólica
//! y el tempo es `60 / b`, con `t = a + b·k` por mínimos cuadrados. `a` es el
//! ancla de la rejilla.
//!
//! Una sola recta deja de valer cuando el tempo, medido por el término
//! cuadrático, se mueve más de 0,02 BPM de punta a punta. Ese 0,02 es la
//! tolerancia del medidor (la misma de los clics sintéticos), no un umbral
//! musical: por debajo, el cambio no se distingue del error que el método
//! declara. Un tramo solo se separa si su pendiente se conoce con error
//! estándar ≤ 0,02 BPM y las dos mitades difieren en más de eso. El error
//! estándar sale del residuo cuadrático y de `Sxx` de los índices; no hay un
//! número fijo de milisegundos.

#[derive(Clone, Debug)]
pub struct GridSeg {
    pub start_ms: f64,
    pub anchor_ms: f64,
    pub period_ms: f64,
}

#[derive(Clone, Debug)]
pub struct TempoGrid {
    /// TBPM con 2 decimales, ya en 60–180.
    pub bpm: f64,
    pub anchor_ms: f64,
    pub period_ms: f64,
    pub segments: Vec<GridSeg>,
}

#[derive(Clone, Copy)]
struct Line {
    anchor: f64,
    period: f64,
    rms: f64,
}

/// Máximo del onset en `±rad` cuadros y vértice parabólico.
pub fn refine_peak(env: &[f64], center: usize, rad: usize) -> f64 {
    if env.is_empty() {
        return 0.0;
    }
    let last = env.len() - 1;
    let best0 = center.min(last);
    let lo = best0.saturating_sub(rad.max(1));
    let hi = (best0 + rad.max(1)).min(last);
    let mut best = best0;
    for j in lo..=hi {
        if env[j] > env[best] {
            best = j;
        }
    }
    let mut t = best as f64;
    if best > 0 && best + 1 < env.len() {
        let (a, b, c) = (env[best - 1], env[best], env[best + 1]);
        let denom = a - 2.0 * b + c;
        if denom.abs() > 1e-18 {
            t += (0.5 * (a - c) / denom).clamp(-0.5, 0.5);
        }
    }
    t
}

fn line_fit(times: &[f64]) -> Option<Line> {
    let n = times.len();
    if n < 4 {
        return None;
    }
    let mut sk = 0.0;
    let mut st = 0.0;
    let mut skt = 0.0;
    let mut sk2 = 0.0;
    for (i, &t) in times.iter().enumerate() {
        if !t.is_finite() {
            return None;
        }
        let k = i as f64;
        sk += k;
        st += t;
        skt += k * t;
        sk2 += k * k;
    }
    let nf = n as f64;
    let den = nf * sk2 - sk * sk;
    if den.abs() < 1e-18 {
        return None;
    }
    let period = (nf * skt - sk * st) / den;
    let anchor = (st - period * sk) / nf;
    if !(period.is_finite() && period > 1e-4 && anchor.is_finite()) {
        return None;
    }
    let mut rss = 0.0;
    for (i, &t) in times.iter().enumerate() {
        let r = t - (anchor + period * i as f64);
        rss += r * r;
    }
    Some(Line {
        anchor,
        period,
        rms: (rss / nf).sqrt(),
    })
}

fn rss_line(times: &[f64]) -> f64 {
    match line_fit(times) {
        Some(line) => line.rms * line.rms * times.len() as f64,
        None => f64::INFINITY,
    }
}

/// Ajuste `t = a + b k + c k²`. Devuelve el cambio de BPM entre el primer
/// y el último golpe, y el RMS del residuo (ruido, sin la deriva).
fn quadratic(times: &[f64]) -> Option<(f64, f64)> {
    let n = times.len();
    if n < 6 {
        return None;
    }
    let mut s = [0.0; 5];
    let mut st = [0.0; 3];
    for (i, &t) in times.iter().enumerate() {
        let k = i as f64;
        let mut p = 1.0;
        for m in 0..5 {
            s[m] += p;
            if m < 3 {
                st[m] += p * t;
            }
            p *= k;
        }
    }
    // Normales: [n, sk, sk2; sk, sk2, sk3; sk2, sk3, sk4] · [a,b,c] = [st, skt, sk2t]
    let mut m = [
        [s[0], s[1], s[2], st[0]],
        [s[1], s[2], s[3], st[1]],
        [s[2], s[3], s[4], st[2]],
    ];
    for col in 0..3 {
        let mut piv = col;
        for r in col + 1..3 {
            if m[r][col].abs() > m[piv][col].abs() {
                piv = r;
            }
        }
        if m[piv][col].abs() < 1e-18 {
            return None;
        }
        if piv != col {
            m.swap(piv, col);
        }
        let div = m[col][col];
        for c in col..4 {
            m[col][c] /= div;
        }
        for r in 0..3 {
            if r == col {
                continue;
            }
            let f = m[r][col];
            for c in col..4 {
                m[r][c] -= f * m[col][c];
            }
        }
    }
    let (a, b, c) = (m[0][3], m[1][3], m[2][3]);
    if !a.is_finite() || !b.is_finite() || !c.is_finite() {
        return None;
    }
    let p0 = b;
    let p1 = b + 2.0 * c * (n as f64 - 1.0);
    if p0 <= 1e-4 || p1 <= 1e-4 {
        return None;
    }
    let delta = (60.0 / p1 - 60.0 / p0).abs();
    let mut rss = 0.0;
    for (i, &t) in times.iter().enumerate() {
        let k = i as f64;
        let r = t - (a + b * k + c * k * k);
        rss += r * r;
    }
    Some((delta, (rss / n as f64).sqrt()))
}

fn bpm_se(n: usize, period: f64, sigma: f64) -> f64 {
    if n < 4 || period <= 0.0 || !sigma.is_finite() {
        return f64::INFINITY;
    }
    let nf = n as f64;
    let sxx = nf * (nf * nf - 1.0) / 12.0;
    if sxx <= 0.0 {
        return f64::INFINITY;
    }
    let se_b = sigma / sxx.sqrt();
    (60.0 / (period * period)) * se_b
}

fn sample_env(env: &[f64], t: f64) -> f64 {
    if env.is_empty() || !t.is_finite() {
        return 0.0;
    }
    if t <= 0.0 {
        return env[0].max(0.0);
    }
    let i = t.floor() as usize;
    if i >= env.len() - 1 {
        return env[env.len() - 1].max(0.0);
    }
    let f = t - i as f64;
    (env[i] * (1.0 - f) + env[i + 1] * f).max(0.0)
}

/// Precisión × cobertura de una rejilla sobre la envolvente.
///
/// Precisión: fracción de golpes que caen en un onset. Cobertura: fracción
/// de onsets que caen en un golpe. Un tempo el doble acierta todos los
/// onsets pero la mitad de sus golpes van al vacío. Uno a 4/3 se desfasa.
/// No hay bonus fijo por estar cerca de 120.
pub fn onset_evidence(env: &[f64], period: f64) -> f64 {
    if env.len() < 16 || !(period >= 2.0) {
        return 0.0;
    }
    let max = env.iter().copied().fold(0.0_f64, f64::max);
    if max <= 1e-9 {
        return 0.0;
    }
    let thr = max * 0.35;
    let mut peaks = Vec::new();
    for i in 1..env.len() - 1 {
        if env[i] >= thr && env[i] >= env[i - 1] && env[i] >= env[i + 1] {
            peaks.push(i);
        }
    }
    if peaks.len() < 4 {
        return 0.0;
    }
    let nphase = period.round().clamp(2.0, 480.0) as usize;
    let step = (nphase / 96).max(1);
    let mut best = 0.0;
    let mut phase = 0usize;
    while phase < nphase {
        let mut n_beats = 0.0;
        let mut hit_beats = 0.0;
        let mut t = phase as f64;
        while t + 1.0 < env.len() as f64 {
            n_beats += 1.0;
            if sample_env(env, t) >= thr {
                hit_beats += 1.0;
            }
            t += period;
        }
        if n_beats > 4.0 {
            let mut hit_peaks = 0.0;
            for &p in &peaks {
                let k = ((p as f64 - phase as f64) / period).round();
                let beat = phase as f64 + k * period;
                if (beat - p as f64).abs() <= 1.5 {
                    hit_peaks += 1.0;
                }
            }
            let precision = hit_beats / n_beats;
            let recall = hit_peaks / peaks.len() as f64;
            let score = precision * recall;
            if score > best {
                best = score;
            }
        }
        phase += step;
    }
    best
}

/// ×2, ×1/2, ×4/3 y ×3/4 del periodo del peine, dentro de 60–180.
/// Elige el que la envolvente sostiene. Empate numérico: se queda el peine.
pub fn choose_metric(env: &[f64], env_rate: f64, coarse: f64) -> f64 {
    if !(coarse.is_finite() && coarse > 0.0) || env_rate <= 0.0 {
        return coarse;
    }
    const FACTORS: [f64; 7] = [1.0, 2.0, 0.5, 4.0 / 3.0, 3.0 / 4.0, 1.5, 2.0 / 3.0];
    let mut best_bpm = coarse;
    let mut best_s = -1.0;
    for factor in FACTORS {
        let bpm = coarse * factor;
        if !(60.0..=180.0).contains(&bpm) {
            continue;
        }
        let period = env_rate * 60.0 / bpm;
        let score = onset_evidence(env, period);
        let closer = (bpm - coarse).abs() < (best_bpm - coarse).abs() - 1e-9;
        if score > best_s + 1e-9 || ((score - best_s).abs() <= 1e-9 && closer) {
            best_s = score;
            best_bpm = bpm;
        }
    }
    best_bpm
}

/// Octava más cercana a la métrica ya elegida, dentro de 60–180.
pub fn align_octave(measured: f64, coarse: f64) -> f64 {
    if !(measured.is_finite() && measured > 0.0) {
        return measured;
    }
    if !(coarse.is_finite() && coarse > 0.0) {
        return fold_60_180(measured);
    }
    let mut best = measured;
    let mut best_d = (measured - coarse).abs();
    let consider = |x: f64, best: &mut f64, best_d: &mut f64| {
        if (60.0..=180.0).contains(&x) && (x - coarse).abs() < *best_d {
            *best = x;
            *best_d = (x - coarse).abs();
        }
    };
    let mut x = measured;
    for _ in 0..6 {
        x *= 2.0;
        if x > 180.0 + 1e-6 {
            break;
        }
        consider(x, &mut best, &mut best_d);
    }
    x = measured;
    for _ in 0..6 {
        x /= 2.0;
        if x < 60.0 - 1e-6 {
            break;
        }
        consider(x, &mut best, &mut best_d);
    }
    fold_60_180(best)
}

fn fold_60_180(mut bpm: f64) -> f64 {
    if !(bpm.is_finite() && bpm > 0.0) {
        return bpm;
    }
    // 180,002 no es la otra octava: partirlo lo dejaría en 90.
    if bpm > 180.0 && bpm <= 180.0 * 1.03 {
        return 180.0;
    }
    if bpm < 60.0 && bpm >= 60.0 / 1.03 {
        return 60.0;
    }
    for _ in 0..8 {
        if bpm > 180.0 {
            bpm /= 2.0;
        } else if bpm < 60.0 {
            bpm *= 2.0;
        } else {
            break;
        }
        if bpm > 180.0 && bpm <= 180.0 * 1.03 {
            return 180.0;
        }
        if bpm < 60.0 && bpm >= 60.0 / 1.03 {
            return 60.0;
        }
    }
    bpm
}

fn segments_of(times: &[f64], scale: f64) -> Vec<GridSeg> {
    fn rec(times: &[f64], lo: usize, hi: usize, scale: f64, out: &mut Vec<(usize, Line)>) {
        let n = hi.saturating_sub(lo);
        if n < 8 {
            if let Some(line) = line_fit(&times[lo..hi]) {
                out.push((lo, line));
            }
            return;
        }
        let slice = &times[lo..hi];
        let rms = line_fit(slice).map(|l| l.rms).unwrap_or(0.0);
        let (delta, noise) = quadratic(slice).unwrap_or((0.0, rms));
        // 196 temas de 80s Ingles: 58 tienen residuo > 60 ms (The Chain, 222 ms).
        // Por debajo de eso una recta alcanza. Por encima, o si el término
        // cuadrático mueve el tempo más de 0,02 BPM (la tolerancia del
        // medidor; Palmer va de 145,8 a 147,3), la rejilla se parte.
        let live = rms > 0.060;
        if delta <= 0.02 && !live {
            if let Some(line) = line_fit(slice) {
                out.push((lo, line));
            }
            return;
        }
        let mut best: Option<(usize, f64)> = None;
        if hi - lo > 16 {
            for mid in (lo + 8)..(hi - 8) {
                let rss = rss_line(&times[lo..mid]) + rss_line(&times[mid..hi]);
                if best.map(|(_, r)| rss < r).unwrap_or(true) {
                    best = Some((mid, rss));
                }
            }
        }
        let Some((mid, _)) = best else {
            if let Some(line) = line_fit(slice) {
                out.push((lo, line));
            }
            return;
        };
        let left = line_fit(&times[lo..mid]);
        let right = line_fit(&times[mid..hi]);
        let (Some(l), Some(r)) = (left, right) else {
            if let Some(line) = line_fit(slice) {
                out.push((lo, line));
            }
            return;
        };
        let _ = noise;
        let se_l = bpm_se(mid - lo, l.period, l.rms);
        let se_r = bpm_se(hi - mid, r.period, r.rms);
        let bpm_l = 60.0 / (l.period * scale);
        let bpm_r = 60.0 / (r.period * scale);
        let gap = (bpm_l - bpm_r).abs();
        if gap <= (se_l + se_r).max(0.02) {
            if let Some(line) = line_fit(slice) {
                out.push((lo, line));
            }
            return;
        }
        rec(times, lo, mid, scale, out);
        rec(times, mid, hi, scale, out);
    }

    let mut raw = Vec::new();
    rec(times, 0, times.len(), scale, &mut raw);
    if raw.len() < 2 {
        return Vec::new();
    }
    raw.into_iter()
        .map(|(lo, line)| {
            let period = line.period * scale;
            GridSeg {
                start_ms: times[lo] * 1000.0,
                anchor_ms: line.anchor * 1000.0,
                period_ms: period * 1000.0,
            }
        })
        .collect()
}

/// `beat_idx` son los golpes de Ellis (cuadros enteros). `coarse_bpm` es la
/// octava del peine, ya en 60–180.
pub fn grid_from_onsets(
    env: &[f64],
    beat_idx: &[usize],
    env_rate: f64,
    coarse_bpm: f64,
) -> Option<TempoGrid> {
    if beat_idx.len() < 4 || env_rate <= 0.0 || !(coarse_bpm > 0.0) {
        return None;
    }
    let period_frames = env_rate * 60.0 / coarse_bpm;
    let rad = (period_frames * 0.08).round().clamp(1.0, 6.0) as usize;
    let mut times = Vec::with_capacity(beat_idx.len());
    for &i in beat_idx {
        times.push(refine_peak(env, i, rad) / env_rate);
    }
    // El primer y el último golpe de Ellis son el borde del Viterbi, no un
    // onset medido: sesgan la pendiente. El interior es la medición.
    if times.len() > 10 {
        times.remove(0);
        times.pop();
    }
    let line = line_fit(&times)?;
    let tracked = 60.0 / line.period;
    let shown = align_octave(tracked, coarse_bpm);
    if !(shown.is_finite() && (60.0..=180.0).contains(&shown)) {
        return None;
    }
    let scale = if tracked > 0.0 { tracked / shown } else { 1.0 };
    if !(scale.is_finite() && scale > 0.0) {
        return None;
    }
    let bpm = (shown * 100.0).round() / 100.0;
    let period_ms = line.period * scale * 1000.0;
    let anchor_ms = line.anchor * 1000.0;
    let segments = segments_of(&times, scale);
    Some(TempoGrid {
        bpm,
        anchor_ms,
        period_ms,
        segments,
    })
}

/// `ancla_ms;periodo_ms` y, si hay deriva, `|inicio,ancla,periodo;...`.
pub fn encode_grid(grid: &TempoGrid) -> String {
    let mut s = format!("{:.3};{:.3}", grid.anchor_ms, grid.period_ms);
    if grid.segments.is_empty() {
        return s;
    }
    s.push('|');
    for (i, seg) in grid.segments.iter().enumerate() {
        if i > 0 {
            s.push(';');
        }
        s.push_str(&format!(
            "{:.3},{:.3},{:.3}",
            seg.start_ms, seg.anchor_ms, seg.period_ms
        ));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ideal(bpm: f64, n: usize, anchor: f64) -> Vec<f64> {
        let b = 60.0 / bpm;
        (0..n).map(|k| anchor + b * k as f64).collect()
    }

    #[test]
    fn la_recta_recupera_bpm_con_decimales() {
        for bpm in [60.25, 89.5, 108.33, 120.5, 144.71, 146.67, 169.2, 180.0] {
            let times = ideal(bpm, 48, 0.37);
            let line = line_fit(&times).unwrap();
            let got = 60.0 / line.period;
            assert!(
                (got - bpm).abs() <= 0.02,
                "{bpm} salió {got}"
            );
            assert!((line.anchor - 0.37).abs() < 1e-6, "ancla {}", line.anchor);
        }
    }

    #[test]
    fn la_octava_sigue_al_peine() {
        assert!((align_octave(73.335, 146.67) - 146.67).abs() < 1e-6);
        assert!((align_octave(146.67, 146.67) - 146.67).abs() < 1e-6);
        assert!((align_octave(293.34, 146.67) - 146.67).abs() < 1e-2);
        let slow = align_octave(72.0, 72.0);
        assert!((slow - 72.0).abs() < 1e-6, "72 no debe saltar a 144: {slow}");
        let fast = align_octave(169.0, 169.0);
        assert!((fast - 169.0).abs() < 1e-6, "169 no debe saltar a 84.5: {fast}");
        let top = align_octave(180.0, 179.92);
        assert!((top - 180.0).abs() < 0.05, "180 contra 179.92 salió {top}");
    }

    #[test]
    fn la_deriva_abre_tramos_y_el_tempo_fijo_no() {
        let steady = ideal(120.0, 80, 0.2);
        let grid = grid_from_beats_direct(&steady, 120.0);
        assert!(grid.segments.is_empty(), "tempo fijo no se parte");

        let mut drift = Vec::new();
        let mut t = 0.15;
        let n = 160;
        for k in 0..n {
            drift.push(t);
            let bpm = 120.0 + 6.0 * (k as f64) / (n as f64 - 1.0);
            t += 60.0 / bpm;
        }
        let parted = grid_from_beats_direct(&drift, 123.0);
        assert!(
            parted.segments.len() >= 2,
            "deriva de 6 BPM sin tramos: {}",
            encode_grid(&parted)
        );
        let first = 60000.0 / parted.segments.first().unwrap().period_ms;
        let last = 60000.0 / parted.segments.last().unwrap().period_ms;
        assert!(
            (first - 120.0).abs() < 1.0,
            "primer tramo {first}"
        );
        assert!((last - 126.0).abs() < 1.0, "último tramo {last}");
    }

    #[test]
    fn palmer_deriva_y_chain_pasa_de_60_ms() {
        let mut palmer = Vec::new();
        let mut t = 0.4;
        let n = 220;
        for k in 0..n {
            palmer.push(t);
            let bpm = 145.8 + 1.5 * (k as f64) / (n as f64 - 1.0);
            t += 60.0 / bpm;
        }
        let g = grid_from_beats_direct(&palmer, 146.5);
        assert!(g.segments.len() >= 2, "Palmer sin tramos");
        let first = 60000.0 / g.segments.first().unwrap().period_ms;
        let last = 60000.0 / g.segments.last().unwrap().period_ms;
        assert!((first - 145.8).abs() < 0.6, "Palmer inicio {first}");
        assert!((last - 147.3).abs() < 0.6, "Palmer fin {last}");

        let mut chain = Vec::new();
        let mut tc = 0.2;
        for k in 0..180 {
            chain.push(tc);
            let bpm = if k < 90 { 118.0 } else { 132.0 };
            tc += 60.0 / bpm;
        }
        let line = line_fit(&chain).unwrap();
        assert!(
            line.rms > 0.060,
            "The Chain de prueba quedó en {:.1} ms",
            line.rms * 1000.0
        );
        let parted = grid_from_beats_direct(&chain, 125.0);
        assert!(parted.segments.len() >= 2, "222 ms de estilo Chain sin tramos");
        let a = 60000.0 / parted.segments.first().unwrap().period_ms;
        let b = 60000.0 / parted.segments.last().unwrap().period_ms;
        assert!((a - 118.0).abs() < 1.0, "Chain inicio {a}");
        assert!((b - 132.0).abs() < 1.0, "Chain fin {b}");
    }

    fn spikes(period: f64, n: usize) -> Vec<f64> {
        let len = (period * (n as f64 + 2.0)).ceil() as usize + 4;
        let mut env = vec![0.0; len];
        for k in 0..n {
            let i = (k as f64 * period).round() as usize;
            if i < env.len() {
                env[i] = 1.0;
            }
            if i + 1 < env.len() {
                env[i + 1] = 0.4;
            }
        }
        env
    }

    #[test]
    fn la_envolvente_elige_mitad_doble_y_tres_cuartos() {
        // Words Fell Down: golpes en 86,56. El peine puede decir 173,12.
        let slow = spikes(60.0 / 86.56 * 100.0, 64);
        let picked = choose_metric(&slow, 100.0, 173.12);
        assert!((picked - 86.56).abs() < 1.0, "Words Fell Down {picked}");

        // Boys Will Be Boys: golpes en 171,46. El peine puede decir 85,73.
        let fast = spikes(60.0 / 171.46 * 100.0, 80);
        let up = choose_metric(&fast, 100.0, 85.73);
        assert!((up - 171.46).abs() < 1.5, "Boys Will Be Boys {up}");

        // How Gee: real ~106, etiqueta 141 (×4/3).
        let gee = spikes(60.0 / 105.75 * 100.0, 70);
        let g = choose_metric(&gee, 100.0, 141.0);
        assert!((g - 105.75).abs() < 1.5, "How Gee {g}");

        // Two Princes: real ~140, etiqueta 105 (×3/4).
        let princes = spikes(60.0 / 139.95 * 100.0, 80);
        let p = choose_metric(&princes, 100.0, 105.0);
        assert!((p - 139.95).abs() < 1.5, "Two Princes {p}");
    }

    fn grid_from_beats_direct(times: &[f64], coarse: f64) -> TempoGrid {
        let line = line_fit(times).unwrap();
        let tracked = 60.0 / line.period;
        let shown = align_octave(tracked, coarse);
        let scale = tracked / shown;
        TempoGrid {
            bpm: (shown * 100.0).round() / 100.0,
            anchor_ms: line.anchor * 1000.0,
            period_ms: line.period * scale * 1000.0,
            segments: segments_of(times, scale),
        }
    }
}
