# Tay release performance

Baseline `773dd03e869753579747c2b4e7b96e601da73233` → candidate `773dd03e869753579747c2b4e7b96e601da73233`

| Metric | Baseline median | Candidate median | Regression | Relative MAD baseline/candidate | Samples |
| --- | ---: | ---: | ---: | ---: | ---: |
| completed_jobs_per_second | 465.40 | 471.43 | -1.28% | 2.95% / 2.31% | 4/4 |
| enqueue_ack_p95_us | 12,634.00 | 12,540.50 | -0.74% | 3.40% / 2.25% | 4/4 |
| callback_latency_p95_us | 16,286.50 | 16,018.50 | -1.65% | 2.57% / 1.38% | 4/4 |
| compaction_us | 154,369,884.00 | 19,085,637.50 | -87.64% | 2.86% / 2.69% | 4/4 |
| peak_rss_bytes | 286,425,088.00 | 267,821,056.00 | -6.50% | 1.58% / 9.90% | 4/4 |
| peak_beam_bytes | 222,366,454.00 | 243,041,048.00 | +9.30% | 0.92% / 0.40% | 4/4 |

Positive regression means worse; negative means improved.
Relative MAD is median absolute deviation divided by the median; qualification requires each cohort to stay within 10% for every metric. No trials are discarded.

Median of trial measurements on the same configuration. Sampling and hosted-runner noise remain; this is not production capacity certification.
