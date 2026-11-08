#!/usr/bin/env python3
"""
Tixati channel key tool: derive keys from strings and verify string/key pairs.

Scheme (reverse-engineered from a known sample, "hashme" ->
"aaqixfadvb67t5hnnmxoezl67ksysatljthjvtgi5cs36pljhrda"):

	key = base32_lower_nopad(clamp25519(SHA-256(utf8(string))))

where clamp25519 is the standard Curve25519/Ed25519 scalar clamping:
	byte[0]  &= 0b11111000   (clear the 3 lowest bits)
	byte[31] &= 0b01111111   (clear the highest bit)
	byte[31] |= 0b01000000   (set the second highest bit)

The result is 32 bytes (a private scalar), shown as 52 base32 characters.

Caveats:
	- The scheme was confirmed on ASCII input only; UTF-8 is assumed for
	  non-ASCII strings.
	- A key derived from a short or common string is easy to brute-force
	  with a dictionary. Use long random phrases for real channels.

Usage:
	tixati-channel-key.py encode STRING [STRING ...]
	tixati-channel-key.py encode < strings.txt    (prints "STRING<TAB>KEY")
	tixati-channel-key.py verify STRING KEY
	tixati-channel-key.py verify < pairs.txt      (one "STRING<TAB>KEY" per line)
	tixati-channel-key.py encode a b | tixati-channel-key.py verify

Exit codes:
	0 - success / all pairs match
	1 - at least one pair does not match
	2 - invalid input (malformed key or line)
"""

import argparse
import base64
import binascii
import hashlib
import hmac
import sys

KEY_BYTES = 32
KEY_CHARS = 52

EXIT_OK = 0
EXIT_MISMATCH = 1
EXIT_INVALID = 2


def clamp25519(scalar: bytes) -> bytes:
	"""
	Apply Curve25519/Ed25519 scalar clamping.

	@param scalar 32 raw bytes.
	@returns Clamped copy of the input.
	"""
	clamped = bytearray(scalar)
	clamped[0] &= 0b11111000
	clamped[31] &= 0b01111111
	clamped[31] |= 0b01000000
	return bytes(clamped)


def derive_key(text: str) -> bytes:
	"""
	Derive the raw 32-byte channel key from a string.

	@param text Source string (encoded as UTF-8).
	@returns Raw clamped key bytes.
	"""
	digest = hashlib.sha256(text.encode("utf-8")).digest()
	return clamp25519(digest)


def key_to_text(raw: bytes) -> str:
	"""
	Format raw key bytes as lowercase base32 without padding.

	@param raw Raw key bytes.
	@returns 52-character key string.
	"""
	return base64.b32encode(raw).decode("ascii").rstrip("=").lower()


def text_to_key(text: str) -> bytes | None:
	"""
	Parse a key string into raw bytes.

	Accepts any case, optional "=" padding and surrounding whitespace.

	@param text Key string.
	@returns Raw key bytes, or None if the string is not a valid key.
	"""
	normalized = text.strip().rstrip("=").upper()
	if len(normalized) != KEY_CHARS:
		return None

	padding = "=" * (-len(normalized) % 8)
	try:
		raw = base64.b32decode(normalized + padding)
	except binascii.Error:
		return None

	if len(raw) != KEY_BYTES:
		return None
	return raw


def encode_string(text: str) -> str:
	"""
	Derive the printable channel key for a string.

	@param text Source string.
	@returns 52-character key string.
	"""
	return key_to_text(derive_key(text))


def verify_pair(text: str, key: str) -> int:
	"""
	Check one string against one key and print the verdict.

	@param text Source string.
	@param key Expected key string.
	@returns EXIT_OK, EXIT_MISMATCH or EXIT_INVALID.
	"""
	expected = text_to_key(key)
	if expected is None:
		print(f"INVALID\t{text}\t{key.strip()} (not a {KEY_CHARS}-char base32 key)")
		return EXIT_INVALID

	if not hmac.compare_digest(derive_key(text), expected):
		print(f"MISMATCH\t{text}\t{key.strip()}")
		return EXIT_MISMATCH

	print(f"OK\t{text}\t{key_to_text(expected)}")
	return EXIT_OK


def read_stdin_lines() -> list[str]:
	"""
	Read non-empty lines from stdin, without trailing newlines.

	@returns List of lines.
	"""
	return [line.rstrip("\r\n") for line in sys.stdin if line.strip()]


def cmd_encode(args: argparse.Namespace) -> int:
	"""
	Handle the "encode" command: print "STRING<TAB>KEY" per input string.

	The output format matches what "verify" reads from stdin.

	@param args Parsed arguments.
	@returns Exit code.
	"""
	strings = args.strings or read_stdin_lines()
	for text in strings:
		print(f"{text}\t{encode_string(text)}")
	return EXIT_OK


def cmd_verify(args: argparse.Namespace) -> int:
	"""
	Handle the "verify" command for one pair or for pairs from stdin.

	@param args Parsed arguments.
	@returns Worst exit code among all pairs.
	"""
	if args.string is not None:
		if args.key is None:
			print("verify: KEY is required when STRING is given", file=sys.stderr)
			return EXIT_INVALID
		return verify_pair(args.string, args.key)

	worst = EXIT_OK
	for line in read_stdin_lines():
		text, sep, key = line.rpartition("\t")
		if not sep:
			print(f"INVALID\t{line} (expected STRING<TAB>KEY)")
			worst = max(worst, EXIT_INVALID)
			continue
		worst = max(worst, verify_pair(text, key))
	return worst


def build_parser() -> argparse.ArgumentParser:
	"""
	Build the command-line parser; each command maps to its handler.

	@returns Configured parser.
	"""
	parser = argparse.ArgumentParser(
		description="Derive and verify Tixati channel keys "
		"(base32(clamp25519(SHA-256(string))))."
	)
	commands = parser.add_subparsers(dest="command", required=True)

	encode = commands.add_parser("encode", help="derive keys from strings")
	encode.add_argument(
		"strings", nargs="*", help="strings to encode (default: stdin lines)"
	)
	encode.set_defaults(handler=cmd_encode)

	verify = commands.add_parser("verify", help="check strings against keys")
	verify.add_argument("string", nargs="?", help="source string")
	verify.add_argument("key", nargs="?", help="expected key")
	verify.set_defaults(handler=cmd_verify)

	return parser


def main() -> int:
	"""
	Entry point.

	@returns Process exit code.
	"""
	args = build_parser().parse_args()
	return args.handler(args)


if __name__ == "__main__":
	sys.exit(main())
