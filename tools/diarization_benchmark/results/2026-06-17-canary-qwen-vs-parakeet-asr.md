# Post-Stream ASR Benchmark: Parakeet vs Canary-Qwen 2.5B

Date: 2026-06-17

## Question

Is NVIDIA **Canary-Qwen 2.5B** a better post-stream transcription model than the
current **Parakeet TDT-CTC 110M** (on-device live ASR, also the word source feeding
Sortformer speaker attribution)? How long does Canary-Qwen take on the last real
input wav?

## Input

- Audio: `s3://meta-glasses-transcribe-620969609288/diarizen/audio/B9213303EEF448228724735FC9841996.wav`
  — the last stream-uploaded clip (conversation session `CEB87F86…`, created 2026-06-17 09:33 UTC).
- Duration: **38.06 s**, 16 kHz mono PCM.

## Environment

- EC2 `i-0c400af918e775f20` = `g4dn.xlarge`, `us-west-1`, NVIDIA Tesla T4 (15 GiB), driver 535 / CUDA 12.2.
- NeMo `nemo_toolkit[asr]==2.7.3` in a Python **3.11** conda env on the persistent `/data` EBS volume.
- torch pinned to **2.6.0+cu118** (NeMo's auto-pulled torch 2.12 is built for CUDA 12.8 and is
  incompatible with the T4's CUDA-12.2 driver; cu118 runs on driver 535).
- Each model: load once, one warm throwaway pass, then a single timed inference.

## Results

| Model | Load (cold) | Inference (warm) | RTFx | Peak GPU | Output quality |
| --- | ---: | ---: | ---: | ---: | --- |
| `nvidia/parakeet-tdt_ctc-110m` | 6.9 s | **0.17 s** | 224× | 0.6 GiB | lowercase, no punctuation, runs on |
| `nvidia/canary-qwen-2.5b` | 78.3 s | **2.83 s** | 13.5× | 9.8 GiB | full punctuation + casing + sentence segmentation |

### Transcripts (same 38 s clip)

**Parakeet TDT-CTC 110M**
> test test who was this test test test I'm testing whether **diorization** can pick this up test test test test hopefully this is good enough yeah hopefully this is long

**Canary-Qwen 2.5B**
> Test, test. Who is this? Test. Test, test. I'm testing whether **Diarization** can pick this up. Test, test. Test, test. Hopefully this is good enough. Yeah. Hopefully this is long.

## Interpretation

- **Timing (the direct ask):** Canary-Qwen transcribes the 38 s clip in **~2.8 s** warm
  (13.5× faster than real time) on a T4, vs Parakeet's 0.17 s. Cold model load is ~78 s
  (one-time per cold process) and it needs ~10 GiB VRAM — fits the T4 but not on-device.
- **Quality:** Canary-Qwen is clearly better for a *post-stream* transcript — correct
  punctuation, capitalization, sentence boundaries, question marks ("Who is this?"), and
  it spelled "Diarization" correctly where Parakeet produced "diorization". Both got the
  underlying words right on this clean clip; the gap widens on harder audio (Canary-Qwen
  tops the HF Open ASR Leaderboard; Parakeet-110M trades accuracy for size/latency).

## Recommendation

Use Canary-Qwen 2.5B for the **post-stream** transcript pass — it runs on the same
g4dn.xlarge that already does post-stream Sortformer diarization, adds only ~2.8 s/clip
of compute, and yields a far more readable, punctuated transcript to attribute to
speakers and feed downstream LLM summarization. Keep Parakeet 110M on-device for the
**live** low-latency path. Re-run word-attribution scoring (existing
`score_word_attribution.py`) with Canary-Qwen words against Sortformer intervals before
switching the production who-said-what path.

## Reproduce

Scripts archived at `s3://…/diarizen/benchmarks/canary-asr/` (`bench_asr.py`,
`fix_and_run.sh`). The working Python-3.11 + cu118 NeMo env persists at `/data/canary311`
on the EBS volume. Note: `diarizen-worker.service` self-powers-off the box when idle —
stop it (`systemctl stop diarizen-worker`) before long interactive runs.
