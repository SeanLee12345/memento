# Who-Said-What Diarization Benchmark

Date: 2026-06-15

## Dataset And Metric

- Dataset: VoxConverse development set v0.3
- Clips: `dhorc`, `qfdpp`, `bspxd`
- Reference: VoxConverse RTTM speaker labels
- ASR: Whisper `base.en` for self-hosted models, held constant across diarizers
- Speaker-attributed word accuracy: percent of recognized words assigned to the correct RTTM speaker interval after optimal speaker-label mapping
- DER: `pyannote.metrics.DiarizationErrorRate`, zero collar, overlap included

VoxConverse does not provide transcript text references, so this benchmark verifies speaker attribution for recognized words, not word error rate.

## Model Accuracy

| Model | Weighted DER | Word speaker accuracy | Mean diarization latency on `g4dn.xlarge` |
| --- | ---: | ---: | ---: |
| DiariZen WavLM Large S80 | 2.15% | 99.58% | 37.27 s |
| NVIDIA Streaming Sortformer 4spk v2.1 | 2.39% | 99.38% | 1.84 s |
| NVIDIA Sortformer 4spk v1 | 5.56% | 96.78% | 2.76 s |

DiariZen remains the accuracy winner. Streaming Sortformer v2.1 is close enough to be the practical production candidate because it is about 20x faster with only a 0.19 percentage-point drop in word speaker accuracy.

## Hugging Face Follow-up

Additional candidates were selected from the Hugging Face `speaker-diarization` model list sorted by likes on 2026-06-15.

| Candidate | Result |
| --- | --- |
| `pyannote/speaker-diarization-community-1` | Blocked: gated pipeline requires a Hugging Face token with accepted model conditions. |
| `pyannote/speaker-diarization-3.1` | Blocked: gated pipeline requires a Hugging Face token with accepted model conditions. |
| `BUT-FIT/diarizen-wavlm-large-s80-md-v2` | Downloaded and loaded, but did not complete the three-file run in a practical window on `g4dn.xlarge`; canceled as inconclusive/too slow for this baseline. |
| `nvidia/diar_streaming_sortformer_4spk-v2` | Not rerun in the restored environment because NeMo was no longer installed; prior `v2.1` result remains the stronger NVIDIA candidate already measured. |

The follow-up did not change the recommendation. To benchmark pyannote fairly, provide a Hugging Face token that has accepted the pyannote model terms, then rerun the same RTTM/word-attribution harness.

## AWS System Check

| AWS system | Pipeline | Word speaker accuracy | Measured latency | Marginal compute/API cost |
| --- | --- | ---: | ---: | ---: |
| `g4dn.xlarge` | Whisper `base.en` + Streaming Sortformer v2.1 | 99.38% | about 32 s/file including measured ASR pass; 1.84 s diarization-only | about $0.0057/file including ASR; $0.00032 diarization-only |
| `c7i.4xlarge` | DiariZen WavLM Large S80, diarization-only | 99.58% | 202-225 s/file | about $0.050-$0.056/file |
| Amazon Transcribe | Managed ASR + speaker labels | 98.25% | 30-32 s/job wall-clock | about $0.12-$0.13/file |

Pricing used:

- `g4dn.xlarge`, `us-west-1`: $0.631/hour
- `c7i.4xlarge`, `us-west-1`: $0.8904/hour
- Amazon Transcribe audio, `us-west-1`: $0.0004/second

EC2 60-second minimum billing and cold-start/model-load overhead are not included in marginal per-file compute cost.

## Per-file Word Speaker Accuracy

| System/model | `dhorc` | `qfdpp` | `bspxd` |
| --- | ---: | ---: | ---: |
| DiariZen | 99.01% | 99.79% | 99.77% |
| Streaming Sortformer v2.1 | 98.88% | 99.69% | 99.46% |
| Sortformer v1 | 88.32% | 99.90% | 99.69% |
| Amazon Transcribe | 99.88% | 95.31% | 99.61% |

Sortformer v1 missed one speaker on `dhorc`. Amazon Transcribe over-split `qfdpp` into five speakers instead of four, causing its attribution drop.

## Recommendation

Use NVIDIA Streaming Sortformer v2.1 on `g4dn.xlarge` as the next production candidate. It provides near-DiariZen speaker attribution accuracy at much lower latency and cost. Keep DiariZen as the higher-accuracy fallback for offline/batch jobs or ambiguous cases where latency is less important.

Before finalizing, run the same metric on at least 20-30 recordings from the app domain and include ASR text WER using a dataset with human transcripts, such as AMI.
