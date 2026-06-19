# VoxConverse Diarization Benchmark

Date: 2026-06-15

## Environment

- EC2: `g4dn.xlarge`, `us-west-1`
- GPU: NVIDIA Tesla T4, 15 GiB
- Price: $0.631/hour on-demand
- Dataset: VoxConverse development set v0.3
- Scoring: `pyannote.metrics.DiarizationErrorRate`, zero collar, overlap included
- ASR excluded so every pipeline is compared on diarization only
- Each model was loaded once and warmed on a separate 30-second recording

## Recordings

| ID | Duration | Reference speakers | Overlap |
| --- | ---: | ---: | ---: |
| `dhorc` | 302.64 s | 4 | 2.05% |
| `qfdpp` | 324.57 s | 4 | 0.80% |
| `bspxd` | 336.36 s | 3 | 16.05% |

## Results

| Model | Weighted DER | Mean latency | Aggregate realtime multiplier | Mean marginal compute cost | Peak VRAM |
| --- | ---: | ---: | ---: | ---: | ---: |
| DiariZen WavLM Large S80 | 2.15% | 37.27 s | 8.87x | $0.00653 | 1.67 GiB |
| NVIDIA Sortformer 4spk v1 | 5.56% | 2.76 s | 119.97x | $0.00048 | 4.50 GiB |
| NVIDIA Streaming Sortformer 4spk v2.1 | 2.39% | 1.84 s | 179.69x | $0.00032 | 0.74 GiB |

Marginal compute cost is `latency / 3600 * $0.631`. A separately started EC2 instance is still subject to the 60-second minimum and boot/model-loading overhead.

## Per-file DER

| Model | `dhorc` | `qfdpp` | `bspxd` |
| --- | ---: | ---: | ---: |
| DiariZen | 1.66% | 1.28% | 3.25% |
| Sortformer v1 | 13.12% | 1.24% | 3.37% |
| Streaming Sortformer v2.1 | 2.14% | 1.06% | 3.70% |

Offline Sortformer v1 detected only three of the four speakers in `dhorc`, producing its accuracy outlier.

## Interpretation

On this small benchmark, DiariZen had the best accuracy. Streaming Sortformer v2.1 was within 0.24 percentage points of weighted DER while running about 20 times faster and using less than half the VRAM. It is the strongest candidate for a low-latency production path, but three recordings are not enough for a final model decision.

The archived RTTMs and timing JSON are stored at:

`s3://meta-glasses-transcribe-620969609288/diarizen/benchmarks/voxconverse-model-benchmark-20260615.tar.gz`
