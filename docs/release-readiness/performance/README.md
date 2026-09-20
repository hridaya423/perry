# Performance release evidence

`budgets.json` is the versioned registry for the numeric Perry 1.0 release contract. Its 14 metrics cover input feedback, panel presentation, overlays, animation, main-thread stalls, exact-window capture, Cua actions, cancellation, idle CPU, and the M5 voice limits.

A metric owns one raw sample stream and one or more percentile constraints. This matters for inserted dictation, where the same observations must satisfy both p50 and p95 limits. A p100 constraint evaluates the maximum observed sample.

Each run must follow `raw-measurements.schema.json`. The file retains raw samples and records provenance, machine, build, and network metadata. The evaluator uses linear interpolation at position `q × (n - 1)` in the sorted samples.

Release evaluation requires baseline and candidate runs captured on the same machine and network mode:

```sh
scripts/performance/evaluate.py \
  --baseline docs/release-readiness/performance/measurements/baseline.json \
  --candidate docs/release-readiness/performance/measurements/candidate.json
```

Both files must contain every metric exactly once and use live, non-synthetic provenance. Every candidate percentile must satisfy its absolute constraint and may not exceed the corresponding baseline percentile by more than 10%. Missing files, metrics, samples, or metadata fail the command.

Launch Perry with an absolute event-log path to record supported internal metrics:

```sh
PERRY_PERFORMANCE_EVENT_LOG=/absolute/path/perry-events.jsonl /Applications/Perry.app/Contents/MacOS/Perry
```

Perry currently emits `voice.realtime_first_audio` from the user's speech-end action to the first valid PCM buffer scheduled for playback. The event contains timing and scenario metadata only; it contains no audio, transcript, prompt, or account data.

For dictation commands, Perry records `dictation.speech_end_to_insert` from push-to-talk release until Cua returns a confirmed field-value read-back for the exact target window. Attempted or unverifiable insertion produces no latency sample and no success claim.

During a realtime response, push-to-talk writes a trusted `voice.barge_in_requested` marker immediately before Perry stops its player. Record Perry's audible output through a loopback device, retain the recording as restricted test-lab input, then derive cancellation samples:

```sh
scripts/performance/acoustic_barge_in.py \
  --recording /absolute/path/perry-loopback.wav \
  --recording-started-at 2026-08-29T14:00:00Z \
  --marker-log /absolute/path/perry-events.jsonl.markers.jsonl \
  --event-log /absolute/path/external-events.jsonl \
  --scenario speaker-loopback
```

The analyzer accepts uncompressed 16-bit PCM WAV input. Each marker must have audible output during the preceding window and sustained silence after it. Threshold and window sizes are explicit command parameters. The evidence log receives only measured milliseconds; it never receives the recording.

External accessibility, Cua, animation, process, and UI harnesses write the same JSONL event shape, including their registered collector identity. Unregistered collectors cannot enter assembled evidence.

Measure the actual Perry process during the endurance and idle runs:

```sh
scripts/performance/sample_process.py \
  --pid "$PERRY_PID" \
  --mode voice-endurance \
  --duration-seconds 1800 \
  --warmup-seconds 60 \
  --interval-seconds 5 \
  --event-log /absolute/path/external-events.jsonl \
  --task-log /absolute/path/perry-events.jsonl.tasks.jsonl \
  --diagnostics /absolute/path/voice-process.json
```

Voice endurance cannot run for less than 1,800 seconds. Idle sampling cannot run for less than 300 seconds. The sampler fails if the process exits or is not named Perry. A voice run also fails unless Perry records at least 10 post-warm-up utterance commits and its owned realtime worker count remains bounded. The diagnostics retain the initial and final resident-memory values and the content-free worker counters; OS thread counts are not used as a proxy for Swift task stability.

Once every metric has observations, assemble one immutable run:

```sh
scripts/performance/assemble.py \
  --event-log /absolute/path/perry-events.jsonl \
  --event-log /absolute/path/external-events.jsonl \
  --output docs/release-readiness/performance/measurements/candidate.json \
  --run-id candidate-m1 \
  --build-version 1.0.0-rc1 \
  --network-mode wifi \
  --internet-reachable true \
  --network-rtt-ms 18
```

The assembler rejects unknown metrics, unregistered collectors, incorrect units, mixed scenarios, missing metrics, malformed timestamps, non-finite values, and an existing output path. It reads explicit event logs and never infers measurements from application logs. Baseline and candidate evaluation also requires the same collector for each metric.

`scripts/performance/self-test.sh` generates fixture runs in a temporary directory and exercises the event assembler. Fixture provenance is accepted only by the evaluator's test-only `--allow-fixtures` option and cannot pass the release command.

No complete live measurement set is committed yet. The registry and evaluator define the gate; they do not prove that Perry meets it.

## Contextual live measurements

The five-minute idle sampler completed against the running Debug app on August 31, 2026 with ambient wake disabled. All 49 post-warm-up samples were 0.0% CPU, so the observed p95 was below the 1% budget. The process held 31,568 KiB RSS at the first and final post-warm-up samples. The machine, build, raw samples, source-artifact hashes, and limitations are retained in `contextual/idle-debug-2026-08-31.json`.

This measurement cannot enter release evaluation because it is an unsigned Debug build from a dirty checkout and has no matched baseline. The complete live release set remains missing.
