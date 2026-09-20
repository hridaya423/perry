import base64
import binascii
import sys


def main() -> int:
    encoded = sys.stdin.buffer.read()
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except binascii.Error:
        return 1
    return 0 if len(decoded) == 32 else 1


if __name__ == "__main__":
    raise SystemExit(main())
