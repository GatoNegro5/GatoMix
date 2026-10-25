// Reparación sin pérdida de MP3 (Masterizar etapa 2, 1.0.12+26).
// Código propio, estilo mp3val: conserva ID3v2/ID3v1, descarta basura entre
// tramas, re-sincroniza la cadena de tramas, quita la última trama truncada
// y corrige el conteo de tramas/bytes de la cabecera Xing/Info. Nunca
// recodifica: los bytes de audio que quedan son los originales.
// Puro Rust sin I/O de plataforma: igual en Windows, Android, macOS e iPhone.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHdr {
    pub version: u8, // 1 = MPEG1, 2 = MPEG2, 25 = MPEG2.5
    pub layer: u8,
    pub rate: u32,
    pub len: usize,
    pub samples: u32,
    pub mono: bool,
}

const BR_V1_L3: [u32; 16] = [
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
];
const BR_V2_L3: [u32; 16] = [
    0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
];
const BR_V1_L2: [u32; 16] = [
    0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0,
];
const BR_V1_L1: [u32; 16] = [
    0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0,
];
const BR_V2_L1: [u32; 16] = [
    0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0,
];

pub fn parse_header(b: &[u8]) -> Option<FrameHdr> {
    if b.len() < 4 || b[0] != 0xFF || (b[1] & 0xE0) != 0xE0 {
        return None;
    }
    let version = match (b[1] >> 3) & 3 {
        0 => 25,
        2 => 2,
        3 => 1,
        _ => return None,
    };
    let layer = match (b[1] >> 1) & 3 {
        1 => 3,
        2 => 2,
        3 => 1,
        _ => return None,
    };
    let br_i = (b[2] >> 4) as usize;
    let sr_i = ((b[2] >> 2) & 3) as usize;
    if br_i == 0 || br_i == 15 || sr_i == 3 {
        return None;
    }
    if (b[3] & 3) == 2 {
        return None; // emphasis reservado
    }
    let base = [44100u32, 48000, 32000][sr_i];
    let rate = match version {
        1 => base,
        2 => base / 2,
        _ => base / 4,
    };
    let pad = ((b[2] >> 1) & 1) as usize;
    let kbps = match (version, layer) {
        (1, 3) => BR_V1_L3[br_i],
        (1, 2) => BR_V1_L2[br_i],
        (1, 1) => BR_V1_L1[br_i],
        (_, 1) => BR_V2_L1[br_i],
        _ => BR_V2_L3[br_i],
    } as usize;
    let (len, samples) = match (version, layer) {
        (_, 1) => ((12 * kbps * 1000 / rate as usize + pad) * 4, 384),
        (1, _) => (144 * kbps * 1000 / rate as usize + pad, 1152),
        (_, 3) => (72 * kbps * 1000 / rate as usize + pad, 576),
        _ => (144 * kbps * 1000 / rate as usize + pad, 1152),
    };
    if len < 21 {
        return None;
    }
    Some(FrameHdr {
        version,
        layer,
        rate,
        len,
        samples,
        mono: (b[3] >> 6) == 3,
    })
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct RepairStats {
    pub frames: u32,
    pub garbage_bytes: usize,
    pub resyncs: u32,
    pub truncated_tail: bool,
    pub xing_fixed: bool,
}

impl RepairStats {
    pub fn changed(&self) -> bool {
        self.garbage_bytes > 0 || self.truncated_tail || self.xing_fixed
    }
    pub fn summary(&self) -> String {
        format!(
            "frames={} garbage={} resyncs={} trunc={} xing={}",
            self.frames,
            self.garbage_bytes,
            self.resyncs,
            self.truncated_tail as u8,
            self.xing_fixed as u8
        )
    }
}

fn id3v2_len(d: &[u8]) -> usize {
    if d.len() >= 10 && &d[0..3] == b"ID3" {
        let sz = ((d[6] as usize & 0x7F) << 21)
            | ((d[7] as usize & 0x7F) << 14)
            | ((d[8] as usize & 0x7F) << 7)
            | (d[9] as usize & 0x7F);
        let footer = if d[5] & 0x10 != 0 { 10 } else { 0 };
        (10 + sz + footer).min(d.len())
    } else {
        0
    }
}

fn same_stream(a: &FrameHdr, b: &FrameHdr) -> bool {
    a.version == b.version && a.layer == b.layer && a.rate == b.rate
}

/// Offset del tag Xing/Info dentro de una trama Layer III.
fn xing_offset(h: &FrameHdr) -> usize {
    4 + match (h.version == 1, h.mono) {
        (true, false) => 32,
        (true, true) => 17,
        (false, false) => 17,
        (false, true) => 9,
    }
}

/// Repara en memoria. Devuelve los bytes nuevos y estadísticas, o None si
/// no se encuentra ninguna cadena válida de tramas.
pub fn repair_mp3(d: &[u8]) -> Option<(Vec<u8>, RepairStats)> {
    let head = id3v2_len(d);
    let mut end = d.len();
    let mut tail_tags: &[u8] = &[];
    if end >= head + 128 && &d[end - 128..end - 125] == b"TAG" {
        tail_tags = &d[end - 128..end];
        end -= 128;
    }
    // APEv2 al final (antes del ID3v1): se conserva tal cual.
    let mut ape: &[u8] = &[];
    if end >= head + 32 && &d[end - 32..end - 24] == b"APETAGEX" {
        let sz = u32::from_le_bytes([d[end - 20], d[end - 19], d[end - 18], d[end - 17]]) as usize;
        let total = sz + 32;
        if total <= end - head {
            ape = &d[end - total..end];
            end -= total;
        }
    }
    let mut st = RepairStats::default();
    let mut frames: Vec<(usize, usize)> = Vec::new();
    let mut stream: Option<FrameHdr> = None;
    let mut pos = head;
    let mut in_garbage = false;
    while pos + 4 <= end {
        let h = match parse_header(&d[pos..]) {
            Some(h) if stream.map_or(true, |s| same_stream(&s, &h)) => h,
            _ => {
                st.garbage_bytes += 1;
                if !in_garbage && !frames.is_empty() {
                    st.resyncs += 1;
                }
                in_garbage = true;
                pos += 1;
                continue;
            }
        };
        let next = pos + h.len;
        if next > end {
            // trama truncada: solo cuenta como tal si es la última.
            st.truncated_tail = true;
            st.garbage_bytes += end - pos;
            break;
        }
        // Confirmar con la trama siguiente (o el final) antes de aceptar.
        let confirmed = next == end
            || (next + 4 <= end && parse_header(&d[next..]).map_or(false, |n| same_stream(&h, &n)))
            || (stream.is_some() && end - next < 4);
        if !confirmed && stream.is_none() {
            st.garbage_bytes += 1;
            pos += 1;
            continue;
        }
        if !confirmed {
            // la trama actual parece buena pero la siguiente no: se acepta y
            // la basura posterior se salta en la próxima vuelta.
        }
        if stream.is_none() {
            stream = Some(h);
        }
        in_garbage = false;
        frames.push((pos, h.len));
        pos = next;
    }
    if pos < end && !st.truncated_tail {
        st.garbage_bytes += end - pos;
    }
    let s = stream?;
    if frames.len() < 10 {
        return None;
    }
    // Xing/Info en la primera trama.
    let (f0, l0) = frames[0];
    let xo = xing_offset(&s);
    let mut first = d[f0..f0 + l0].to_vec();
    let has_xing = s.layer == 3
        && first.len() >= xo + 16
        && (&first[xo..xo + 4] == b"Xing" || &first[xo..xo + 4] == b"Info");
    let audio_frames = if has_xing {
        frames.len() - 1
    } else {
        frames.len()
    };
    let audio_bytes: usize = frames.iter().map(|f| f.1).sum();
    if has_xing {
        let flags =
            u32::from_be_bytes([first[xo + 4], first[xo + 5], first[xo + 6], first[xo + 7]]);
        let mut p = xo + 8;
        if flags & 1 != 0 {
            let old = u32::from_be_bytes([first[p], first[p + 1], first[p + 2], first[p + 3]]);
            if old as usize != audio_frames {
                first[p..p + 4].copy_from_slice(&(audio_frames as u32).to_be_bytes());
                st.xing_fixed = true;
            }
            p += 4;
        }
        if flags & 2 != 0 && first.len() >= p + 4 {
            let old = u32::from_be_bytes([first[p], first[p + 1], first[p + 2], first[p + 3]]);
            if old as usize != audio_bytes {
                first[p..p + 4].copy_from_slice(&(audio_bytes as u32).to_be_bytes());
                st.xing_fixed = true;
            }
        }
    }
    st.frames = audio_frames as u32;
    let mut out = Vec::with_capacity(d.len());
    out.extend_from_slice(&d[..head]);
    out.extend_from_slice(&first);
    for &(p, l) in &frames[1..] {
        out.extend_from_slice(&d[p..p + l]);
    }
    out.extend_from_slice(ape);
    out.extend_from_slice(tail_tags);
    Some((out, st))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(fill: u8) -> Vec<u8> {
        // MPEG1 L3 128 kbps 44.1 kHz sin padding = 417 bytes
        let mut f = vec![0xFF, 0xFB, 0x90, 0x00];
        f.resize(417, fill);
        f
    }

    #[test]
    fn header_len_mpeg1_128() {
        let h = parse_header(&frame(0)).unwrap();
        assert_eq!(h.len, 417);
        assert_eq!(h.rate, 44100);
    }

    #[test]
    fn strips_garbage_and_truncated_tail() {
        let mut d = b"ID3\x04\x00\x00\x00\x00\x00\x05hello".to_vec();
        for i in 0..20 {
            d.extend(frame(i));
        }
        d.extend_from_slice(&[0x12, 0x34, 0x56, 0x00, 0x11]);
        for i in 0..20 {
            d.extend(frame(i));
        }
        let t = frame(9);
        d.extend_from_slice(&t[..100]);
        let (out, st) = repair_mp3(&d).unwrap();
        assert_eq!(st.frames, 40);
        assert!(st.truncated_tail);
        assert_eq!(st.garbage_bytes, 5 + 100);
        assert_eq!(out.len(), 15 + 40 * 417);
        assert_eq!(&out[..15], &d[..15]);
    }

    #[test]
    fn clean_file_unchanged() {
        let mut d = Vec::new();
        for i in 0..30 {
            d.extend(frame(i));
        }
        let (out, st) = repair_mp3(&d).unwrap();
        assert!(!st.changed());
        assert_eq!(out, d);
    }

    #[test]
    fn fixes_xing_count() {
        let mut x = frame(0);
        let xo = 4 + 32;
        x[xo..xo + 4].copy_from_slice(b"Xing");
        x[xo + 4..xo + 8].copy_from_slice(&1u32.to_be_bytes());
        x[xo + 8..xo + 12].copy_from_slice(&999u32.to_be_bytes());
        let mut d = x;
        for i in 0..20 {
            d.extend(frame(i));
        }
        let (out, st) = repair_mp3(&d).unwrap();
        assert!(st.xing_fixed);
        assert_eq!(
            u32::from_be_bytes([out[xo + 8], out[xo + 9], out[xo + 10], out[xo + 11]]),
            20
        );
    }
}
