#!/usr/bin/env python3
"""
Offline speaker recognition accuracy test using SpeechBrain ECAPA-TDNN.

Usage:
  # Record two speakers then test (requires sounddevice):
  python tools/test_speaker_recognition_offline.py --record --speakers 2 --duration 5

  # Test on existing WAV files:
  python tools/test_speaker_recognition_offline.py \
    --files speaker1_a.wav speaker1_b.wav speaker2_a.wav speaker2_b.wav \
    --labels 0 0 1 1

  # Quick same-speaker vs different-speaker cosine similarity report:
  python tools/test_speaker_recognition_offline.py --demo

Requirements:
  pip install speechbrain torch torchaudio soundfile numpy
  Optional (for --record): pip install sounddevice
"""

import argparse
import sys
import numpy as np

SAMPLE_RATE = 16_000


def load_model():
    try:
        from speechbrain.pretrained import EncoderClassifier
    except ImportError:
        sys.exit(
            "speechbrain not installed. Run:\n"
            "  pip install speechbrain torch torchaudio soundfile numpy"
        )
    print("Loading SpeechBrain ECAPA-TDNN (downloads ~80 MB on first run)...")
    model = EncoderClassifier.from_hparams(
        source="speechbrain/spkrec-ecapa-voxceleb",
        run_opts={"device": "cpu"},
    )
    print("Model loaded.")
    return model


def embed(model, audio_np: np.ndarray) -> np.ndarray:
    """Return L2-normalized 192-dim speaker embedding for a 16 kHz mono numpy array."""
    import torch

    wav = torch.tensor(audio_np, dtype=torch.float32).unsqueeze(0)
    with torch.no_grad():
        emb = model.encode_batch(wav)  # [1, 1, 192]
    vec = emb.squeeze().numpy()
    vec = vec / (np.linalg.norm(vec) + 1e-8)
    return vec


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b))


def load_wav(path: str) -> np.ndarray:
    import soundfile as sf

    audio, sr = sf.read(path, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        try:
            import torchaudio
            import torch

            wav = torch.tensor(audio).unsqueeze(0)
            wav = torchaudio.functional.resample(wav, sr, SAMPLE_RATE)
            audio = wav.squeeze().numpy()
        except ImportError:
            print(f"Warning: {path} is {sr} Hz but torchaudio unavailable for resampling.")
    return audio


def record_speaker(index: int, duration: float) -> np.ndarray:
    try:
        import sounddevice as sd
    except ImportError:
        sys.exit("sounddevice not installed. Run: pip install sounddevice")
    print(f"  Recording speaker {index} for {duration}s — speak now...")
    audio = sd.rec(
        int(duration * SAMPLE_RATE), samplerate=SAMPLE_RATE, channels=1, dtype="float32"
    )
    sd.wait()
    return audio.squeeze()


def report_pair(label_a: str, label_b: str, sim: float, same_speaker: bool):
    match = "SAME" if same_speaker else "DIFF"
    ok = (same_speaker and sim > 0.75) or (not same_speaker and sim < 0.65)
    status = "OK" if ok else "MISS"
    print(f"  [{status}] {match:4s}  {label_a:30s} vs {label_b:30s}  sim={sim:.4f}")


def demo_mode(model):
    """
    Synthesise two fake speakers using random walk noise to illustrate the
    expected same/different similarity range without needing real audio.
    """
    import torch

    rng = np.random.default_rng(42)
    dur = SAMPLE_RATE * 3  # 3 seconds

    def fake_audio(seed):
        r = np.random.default_rng(seed)
        # Narrow-band shaped noise as a crude voice proxy.
        noise = r.standard_normal(dur).astype(np.float32) * 0.05
        return noise

    print("\n--- DEMO MODE (synthetic audio) ---")
    print("Real speech will produce much stronger intra-speaker similarity (>0.80).\n")

    spk1_a = embed(model, fake_audio(1))
    spk1_b = embed(model, fake_audio(2))  # slightly different but same random range
    spk2_a = embed(model, fake_audio(100))
    spk2_b = embed(model, fake_audio(101))

    report_pair("spk1_utterance_a", "spk1_utterance_b", cosine(spk1_a, spk1_b), same_speaker=True)
    report_pair("spk2_utterance_a", "spk2_utterance_b", cosine(spk2_a, spk2_b), same_speaker=True)
    report_pair("spk1_utterance_a", "spk2_utterance_a", cosine(spk1_a, spk2_a), same_speaker=False)
    report_pair("spk1_utterance_b", "spk2_utterance_b", cosine(spk1_b, spk2_b), same_speaker=False)
    print("\nNote: synthetic noise embeddings are not meaningful for threshold calibration.")
    print("Record real speech with --record or provide --files to get actionable numbers.")


def files_mode(model, paths: list[str], labels: list[int]):
    if len(paths) != len(labels):
        sys.exit("--files and --labels must have the same length.")
    embeddings = []
    for p, lbl in zip(paths, labels):
        audio = load_wav(p)
        emb = embed(model, audio)
        embeddings.append((p, lbl, emb))
        print(f"  Embedded {p} (label={lbl}, dur={len(audio)/SAMPLE_RATE:.1f}s)")

    print("\n--- Pairwise cosine similarities ---")
    same_sims, diff_sims = [], []
    for i in range(len(embeddings)):
        for j in range(i + 1, len(embeddings)):
            pa, la, ea = embeddings[i]
            pb, lb, eb = embeddings[j]
            sim = cosine(ea, eb)
            same = la == lb
            report_pair(pa, pb, sim, same_speaker=same)
            (same_sims if same else diff_sims).append(sim)

    print(f"\nSame-speaker  mean={np.mean(same_sims):.4f} min={np.min(same_sims):.4f} max={np.max(same_sims):.4f}" if same_sims else "No same-speaker pairs.")
    print(f"Diff-speaker  mean={np.mean(diff_sims):.4f} min={np.min(diff_sims):.4f} max={np.max(diff_sims):.4f}" if diff_sims else "No diff-speaker pairs.")


def record_mode(model, n_speakers: int, duration: float):
    print(f"\nRecording {n_speakers} speakers × 2 utterances each ({duration}s each).\n")
    embeddings = []
    for spk in range(n_speakers):
        input(f"Press Enter when speaker {spk + 1} is ready for utterance 1...")
        a1 = record_speaker(spk + 1, duration)
        input(f"Press Enter when speaker {spk + 1} is ready for utterance 2...")
        a2 = record_speaker(spk + 1, duration)
        e1 = embed(model, a1)
        e2 = embed(model, a2)
        embeddings.append((f"spk{spk+1}_utt1", spk, e1))
        embeddings.append((f"spk{spk+1}_utt2", spk, e2))

    print("\n--- Pairwise cosine similarities ---")
    same_sims, diff_sims = [], []
    for i in range(len(embeddings)):
        for j in range(i + 1, len(embeddings)):
            pa, la, ea = embeddings[i]
            pb, lb, eb = embeddings[j]
            sim = cosine(ea, eb)
            same = la == lb
            report_pair(pa, pb, sim, same_speaker=same)
            (same_sims if same else diff_sims).append(sim)

    if same_sims:
        print(f"\nSame-speaker  mean={np.mean(same_sims):.4f}")
    if diff_sims:
        print(f"Diff-speaker  mean={np.mean(diff_sims):.4f}")
    if same_sims and diff_sims:
        # Suggest iOS thresholds based on observed distributions.
        suggested_strong = round(float(np.mean(same_sims)) - 0.05, 2)
        suggested_weak = round(float(np.mean(diff_sims)) + 0.05, 2)
        print(f"\nSuggested iOS thresholds (SpeakerIdentityConfig):")
        print(f"  strongMatchThreshold = {suggested_strong}")
        print(f"  weakMatchThreshold   = {suggested_weak}")


def main():
    parser = argparse.ArgumentParser(description="Offline speaker recognition accuracy test")
    parser.add_argument("--demo", action="store_true", help="Run demo with synthetic audio")
    parser.add_argument("--record", action="store_true", help="Record live speakers")
    parser.add_argument("--speakers", type=int, default=2, help="Number of speakers to record")
    parser.add_argument("--duration", type=float, default=5.0, help="Seconds per utterance")
    parser.add_argument("--files", nargs="+", help="WAV files to embed and compare")
    parser.add_argument("--labels", nargs="+", type=int, help="Speaker labels for --files")
    args = parser.parse_args()

    model = load_model()

    if args.demo:
        demo_mode(model)
    elif args.record:
        record_mode(model, args.speakers, args.duration)
    elif args.files:
        files_mode(model, args.files, args.labels or [])
    else:
        print("No mode specified. Running --demo.\n")
        demo_mode(model)


if __name__ == "__main__":
    main()
