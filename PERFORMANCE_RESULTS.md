# Benchmark Results: pre-Phase 1 baseline → Phase 5

Compared `bench-baseline/pre-phase1-*.csv` (commit before Phase 1) against
`bench-results/ea4df68-*.csv` (Phase 5 final, runtime-equivalent to current
`b2e68af`). The IO commit `081ecf8` lands at the assertion layer, so the
compare-path bench numbers are unchanged by it — total CI gains on
high-latency volumes will be larger than what's captured here.

## Serial p50 (single-call latency)

| Scenario | Baseline | Phase 5 | Δ | Speedup |
|---|---:|---:|---:|---:|
| `precision-1px-diff` | 12.48 ms | 1.24 ms | **−90%** | 10.1× |
| `precision-50pct-diff` | 12.70 ms | 1.24 ms | **−90%** | 10.3× |
| `exact-match-large` | 14.87 ms | 3.03 ms | **−80%** | 5.0× |
| `exact-match-mixed` | 3.83 ms | 1.26 ms | **−67%** | 3.0× |
| `perceptual-fail` | 15.98 ms | 5.86 ms | **−63%** | 2.7× |
| `perceptual-pass` | 12.46 ms | 5.98 ms | **−52%** | 2.1× |
| `exact-match-small` | 20.1 µs | 10.8 µs | **−46%** | 1.9× |
| `precision-early-fail` | 32.24 ms | 24.66 ms | −24% | 1.3× |
| `png-roundtrip` | 5.07 ms | 4.79 ms | −5% | 1.06× |

## Parallel-4 wall time (4-way parallel total)

| Scenario | Baseline | Phase 5 | Δ | Speedup |
|---|---:|---:|---:|---:|
| `precision-1px-diff` | 2542 ms | 115 ms | **−95%** | 22.0× |
| `precision-50pct-diff` | 2257 ms | 109 ms | **−95%** | 20.7× |
| `exact-match-large` | 1072 ms | 264 ms | **−75%** | 4.1× |
| `perceptual-fail` | 1097 ms | 298 ms | **−73%** | 3.7× |
| `perceptual-pass` | 1041 ms | 301 ms | **−71%** | 3.5× |
| `exact-match-mixed` | 3218 ms | 1209 ms | **−62%** | 2.7× |
| `precision-early-fail` | 4122 ms | 1797 ms | −56% | 2.3× |
| `exact-match-small` | 79.8 ms | 34.2 ms | −57% | 2.3× |
| `png-roundtrip` | 496 ms | 389 ms | −22% | 1.3× |

## Parallel-8 wall time (8-way parallel total)

| Scenario | Baseline | Phase 5 | Δ | Speedup |
|---|---:|---:|---:|---:|
| `precision-1px-diff` | 1810 ms | 118 ms | **−93%** | 15.4× |
| `precision-50pct-diff` | 1620 ms | 112 ms | **−93%** | 14.4× |
| `perceptual-pass` | 1209 ms | 294 ms | **−76%** | 4.1× |
| `perceptual-fail` | 1054 ms | 294 ms | **−72%** | 3.6× |
| `exact-match-large` | 920 ms | 267 ms | **−71%** | 3.4× |
| `exact-match-mixed` | 3125 ms | 1038 ms | **−67%** | 3.0× |
| `precision-early-fail` | 4016 ms | 1725 ms | −57% | 2.3× |
| `exact-match-small` | 77.2 ms | 33.9 ms | −56% | 2.3× |
| `png-roundtrip` | 616 ms | 395 ms | −36% | 1.6× |

## Peak RSS

| Mode | Baseline | Phase 5 | Δ |
|---|---:|---:|---:|
| Parallel-4 | 7.93 GB | 4.53 GB | **−43%** |
| Parallel-8 | 8.96 GB | 4.48 GB | **−50%** (halved) |

## Where the wins came from

- **Phase 2** — CIContext pooling + perceptual-diff concurrency cap →
  perceptual scenarios stopped serializing on a single GPU; eliminated
  `Context leak detected` warnings.
- **Phase 3** — dropped the PNG round-trip in `compare()` + normalized
  NSImage's `context(for:)` → the largest single contributor; byte-loop
  scenarios went from ~12 ms to ~1.7 ms (−84%).
- **Phase 5** — raw allocation skipping the per-call
  `[UInt8](repeating: 0, ...)` zero-fill → final 29-37% on the byte-loop
  scenarios + halved peak RSS at parallel-8.

## Headline

On the most common CI-failure path (`precision-*` scenarios at parallel-8),
the library is now **~15× faster** while consuming **half the RAM**.
The IO commit (`081ecf8`) on top removes ~3 syscalls per assertion, so total
CI gains will be even higher on high-latency volumes — but that's not
captured by this bench harness.
