//! DSP de DNA: pasa-altos / estante de agudos (biquad) y eco al beat.
//!
//! Se calcula al preparar el relevo. El tick de Dart no entra aquí.
//! En vivo, libmpv aplica `equalizer` o `aecho` con estos parámetros.
//! Si ese filtro no está, DNA cae al fundido de volumen.

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

impl Biquad {
    fn highpass(fc: f64, fs: f64) -> Self {
        let w = std::f64::consts::TAU * fc / fs;
        let (sinw, cosw) = (w.sin(), w.cos());
        let alpha = sinw / (2.0 * std::f64::consts::FRAC_1_SQRT_2);
        let a0 = 1.0 + alpha;
        Self {
            b0: ((1.0 + cosw) / 2.0) / a0,
            b1: (-(1.0 + cosw)) / a0,
            b2: ((1.0 + cosw) / 2.0) / a0,
            a1: (-2.0 * cosw) / a0,
            a2: (1.0 - alpha) / a0,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
        }
    }

    /// Estante de agudos. [db] negativo baja los agudos.
    fn high_shelf(fc: f64, fs: f64, db: f64) -> Self {
        let a = 10f64.powf(db / 40.0);
        let w = std::f64::consts::TAU * fc / fs;
        let (sinw, cosw) = (w.sin(), w.cos());
        let alpha = sinw / (2.0 * std::f64::consts::FRAC_1_SQRT_2);
        let a0 = (a + 1.0) - (a - 1.0) * cosw + 2.0 * a.sqrt() * alpha;
        Self {
            b0: (a * ((a + 1.0) + (a - 1.0) * cosw + 2.0 * a.sqrt() * alpha)) / a0,
            b1: (-2.0 * a * ((a - 1.0) + (a + 1.0) * cosw)) / a0,
            b2: (a * ((a + 1.0) + (a - 1.0) * cosw - 2.0 * a.sqrt() * alpha)) / a0,
            a1: (2.0 * ((a - 1.0) - (a + 1.0) * cosw)) / a0,
            a2: ((a + 1.0) - (a - 1.0) * cosw - 2.0 * a.sqrt() * alpha) / a0,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
        }
    }

    fn process(&mut self, input: &[f32]) -> Vec<f32> {
        input
            .iter()
            .map(|&x| {
                let x = x as f64;
                let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2
                    - self.a1 * self.y1
                    - self.a2 * self.y2;
                self.x2 = self.x1;
                self.x1 = x;
                self.y2 = self.y1;
                self.y1 = y;
                y as f32
            })
            .collect()
    }
}

/// Eco al beat. Cada vuelta guarda el golpe multiplicado por [feedback] (< 1),
/// así la repetición siguiente sale más baja.
pub fn echo_out(input: &[f32], delay: usize, feedback: f64) -> Vec<f32> {
    if delay == 0 || input.is_empty() {
        return input.to_vec();
    }
    let mut line = vec![0.0f64; delay];
    let mut pos = 0usize;
    let mut out = Vec::with_capacity(input.len());
    for &x in input {
        let delayed = line[pos];
        let y = x as f64 + delayed;
        line[pos] = y * feedback;
        pos += 1;
        if pos == delay {
            pos = 0;
        }
        out.push(y as f32);
    }
    out
}

fn rms(xs: &[f32]) -> f64 {
    if xs.is_empty() {
        return 0.0;
    }
    let s: f64 = xs.iter().map(|v| (*v as f64) * (*v as f64)).sum();
    (s / xs.len() as f64).sqrt()
}

fn sine(rate: u32, seconds: f64, hz: f64, amp: f32) -> Vec<f32> {
    let n = (seconds * rate as f64) as usize;
    (0..n)
        .map(|i| amp * (std::f64::consts::TAU * hz * i as f64 / rate as f64).sin() as f32)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: u32 = 22050;

    #[test]
    fn el_pasa_altos_apaga_el_grave_y_deja_el_agudo() {
        let low = sine(RATE, 1.0, 100.0, 0.5);
        let high = sine(RATE, 1.0, 3000.0, 0.5);
        let low_y = Biquad::highpass(280.0, RATE as f64).process(&low);
        let high_y = Biquad::highpass(280.0, RATE as f64).process(&high);
        let low_ratio = rms(&low_y[low_y.len() / 2..]) / rms(&low);
        let high_ratio = rms(&high_y[high_y.len() / 2..]) / rms(&high);
        assert!(low_ratio < 0.25, "grave {low_ratio}");
        assert!(high_ratio > 0.7, "agudo {high_ratio}");
    }

    #[test]
    fn el_estante_baja_los_agudos_y_deja_el_cuerpo() {
        let body = sine(RATE, 1.0, 200.0, 0.5);
        let air = sine(RATE, 1.0, 6000.0, 0.5);
        let mut shelf = Biquad::high_shelf(2500.0, RATE as f64, -12.0);
        let body_y = shelf.process(&body);
        let mut shelf = Biquad::high_shelf(2500.0, RATE as f64, -12.0);
        let air_y = shelf.process(&air);
        let body_ratio = rms(&body_y[body_y.len() / 2..]) / rms(&body);
        let air_ratio = rms(&air_y[air_y.len() / 2..]) / rms(&air);
        assert!(body_ratio > 0.75, "cuerpo {body_ratio}");
        assert!(air_ratio < 0.55, "agudos {air_ratio}");
        assert!(air_ratio < body_ratio);
    }

    #[test]
    fn el_eco_repite_el_golpe_cada_vez_mas_bajo() {
        let delay = 2000;
        let mut click = vec![0.0f32; delay * 3 + 10];
        click[0] = 1.0;
        let y = echo_out(&click, delay, 0.6);
        let first = y[delay].abs();
        let second = y[delay * 2].abs();
        assert!(first > 0.4, "primera repetición {first}");
        assert!(second > 0.05, "segunda repetición {second}");
        assert!(second < first * 0.7, "decae {second} vs {first}");
    }
}
