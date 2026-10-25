"""GatoMix 1.0.13 — palabras con tiempo para alinear letras (SOLO escritorio).

Opcional y offline. Escribe `<canción>.gmx_words.json` junto a cada mp3; el
Masterizar / modo Laboratorio lo usa para confirmar o corregir la letra.
Requisitos: pip install faster-whisper==1.2.1 (MIT; modelos Whisper MIT).
Uso: python gmx_whisper_words.py <carpeta> [modelo=small] [idioma=auto]
No modifica audio ni letras.
"""
import json, os, sys, time
from faster_whisper import WhisperModel

def main():
    folder = sys.argv[1]
    model = sys.argv[2] if len(sys.argv) > 2 else "small"
    lang = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != "auto" else None
    m = WhisperModel(model, device="cpu", compute_type="int8")
    for f in sorted(os.listdir(folder)):
        if not f.lower().endswith(".mp3") or f.endswith("_K.mp3"):
            continue
        out = os.path.join(folder, f[:-4] + ".gmx_words.json")
        if os.path.exists(out) or not os.path.exists(os.path.join(folder, f[:-4] + ".lrc")):
            continue
        t = time.time()
        # VAD apagado: el VAD de Silero descarta la voz cantada.
        segs, info = m.transcribe(os.path.join(folder, f), language=lang,
                                  word_timestamps=True, vad_filter=False,
                                  beam_size=1, condition_on_previous_text=False)
        words = [(w.start, w.end, w.word) for s in segs for w in s.words]
        tmp = out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"dur": info.duration, "lang": info.language, "model": model, "words": words}, fh)
        os.replace(tmp, out)
        print(f"{f}\t{len(words)}w\t{time.time()-t:.1f}s", flush=True)

if __name__ == "__main__":
    main()
