import base64
import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate_sparkle_public_key.py")


class SparklePublicKeyTests(unittest.TestCase):
    def validate(self, value: bytes) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT)],
            input=value,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_accepts_exactly_32_bytes(self) -> None:
        result = self.validate(base64.b64encode(bytes(range(32))))
        self.assertEqual(result.returncode, 0)

    def test_rejects_wrong_decoded_length(self) -> None:
        result = self.validate(base64.b64encode(bytes(range(31))))
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_trailing_invalid_data_after_32_bytes(self) -> None:
        result = self.validate(base64.b64encode(bytes(range(32))) + b"!")
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_embedded_whitespace(self) -> None:
        encoded = base64.b64encode(bytes(range(32)))
        result = self.validate(encoded[:8] + b"\n" + encoded[8:])
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
