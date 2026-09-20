#!/usr/bin/env python3

from __future__ import annotations

import array
import json
import tempfile
import unittest
import wave
from datetime import datetime, timedelta, timezone
from pathlib import Path

import acoustic_barge_in


class AcousticBargeInTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)
        self.started_at = datetime(2026, 8, 29, 14, 0, tzinfo=timezone.utc)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_measures_from_marker_to_sustained_acoustic_silence(self) -> None:
        sample_rate = 1_000
        samples = [0] * 100 + [4_000] * 200 + [0] * 100
        marker = self.started_at + timedelta(milliseconds=200)

        durations = acoustic_barge_in.analyze(
            samples,
            sample_rate,
            self.started_at,
            [marker],
            threshold=500,
            pretrigger_ms=50,
            quiet_ms=30,
        )

        self.assertEqual(durations, [100])

    def test_rejects_a_marker_without_audible_output_before_it(self) -> None:
        with self.assertRaises(acoustic_barge_in.AnalysisFailure) as context:
            acoustic_barge_in.analyze(
                [0] * 400,
                1_000,
                self.started_at,
                [self.started_at + timedelta(milliseconds=200)],
                threshold=500,
                pretrigger_ms=50,
                quiet_ms=30,
            )

        self.assertIn("no audible pre-trigger output", str(context.exception))

    def test_end_to_end_writes_registered_evidence_without_audio(self) -> None:
        recording = self.directory / "loopback.wav"
        marker_log = self.directory / "events.jsonl.markers.jsonl"
        event_log = self.directory / "external.jsonl"
        self.write_wav(recording, [0] * 100 + [4_000] * 160 + [0] * 100)
        marker_log.write_text(json.dumps({
            "name": acoustic_barge_in.MARKER_NAME,
            "captured_at": "2026-08-29T14:00:00.200Z",
        }) + "\n", encoding="utf-8")

        status = acoustic_barge_in.main([
            "--recording", str(recording),
            "--recording-started-at", "2026-08-29T14:00:00Z",
            "--marker-log", str(marker_log),
            "--event-log", str(event_log),
            "--scenario", "speaker-loopback",
        ])

        self.assertEqual(status, 0)
        event = json.loads(event_log.read_text(encoding="utf-8"))
        self.assertEqual(event["collector"], acoustic_barge_in.COLLECTOR)
        self.assertEqual(event["metric_id"], "voice.barge_in_cancel")
        self.assertEqual(event["value"], 60)
        self.assertNotIn("audio", event)

    def test_marker_parser_ignores_unrelated_markers_and_rejects_bad_shape(self) -> None:
        path = self.directory / "markers.jsonl"
        path.write_text(
            json.dumps({"name": "voice.other", "captured_at": "2026-08-29T14:00:00Z"}) + "\n" +
            json.dumps({"name": acoustic_barge_in.MARKER_NAME, "captured_at": "2026-08-29T14:00:01Z"}) + "\n",
            encoding="utf-8",
        )

        self.assertEqual(acoustic_barge_in.read_markers(path), [self.started_at + timedelta(seconds=1)])

        path.write_text(json.dumps({"name": acoustic_barge_in.MARKER_NAME}) + "\n", encoding="utf-8")
        with self.assertRaises(acoustic_barge_in.AnalysisFailure):
            acoustic_barge_in.read_markers(path)

    def write_wav(self, path: Path, samples: list[int]) -> None:
        values = array.array("h", samples)
        with wave.open(str(path), "wb") as recording:
            recording.setnchannels(1)
            recording.setsampwidth(2)
            recording.setframerate(1_000)
            recording.writeframes(values.tobytes())


if __name__ == "__main__":
    unittest.main()
