#!/usr/bin/env python3
"""
Tixati channel key tool: derive keys from passwords and verify them.

Scheme (reverse-engineered from a known password/key pair):

	key = base32_lower_nopad(clamp25519(SHA-256(utf8(password))))

Example: "ApHfkCDJs8XX" -> "4chqjn3n5gj5rrf3yyjzipu52rf3hls362r27zjrxscmj5w42rka"

where clamp25519 is the standard Curve25519/Ed25519 scalar clamping:
	byte[0]  &= 0b11111000   (clear the 3 lowest bits)
	byte[31] &= 0b01111111   (clear the highest bit)
	byte[31] |= 0b01000000   (set the second highest bit)

The result is 32 bytes (a private scalar), shown as 52 base32 characters.

Data format: CSV with ";" as the delimiter, columns
	password;hash;channel;note
"channel" and "note" are optional and never checked: "encode" copies them
to the output unchanged, "verify" ignores them. A first row whose password
column is "password" (any case) is treated as a header:
"encode" copies it, "verify" skips it. Fields containing ";" or quotes use
standard CSV quoting.

Caveats:
	- The scheme was confirmed on ASCII input only; UTF-8 is assumed for
	  non-ASCII passwords.
	- A key derived from a short or common password is easy to brute-force
	  with a dictionary. Use long random phrases for real channels.

Usage:
	tixati-channel-key.py encode PASSWORD [PASSWORD ...]
	tixati-channel-key.py encode -f channels.csv   (fills in the hash column)
	tixati-channel-key.py verify PASSWORD HASH
	tixati-channel-key.py verify -f channels.csv
	(see tixati-channel-key.example.csv)
	tixati-channel-key.py encode a b | tixati-channel-key.py verify

	"-f FILE" works in every shell, including PowerShell, which has no "<"
	redirection. Without "-f" and positional arguments, CSV is read from
	stdin. Input is always decoded as UTF-8 (a leading BOM is ignored), and
	output is written as UTF-8, regardless of the Windows console code page.

Output of "verify": one "STATUS;password;hash" row per data row, where
STATUS is OK, MISMATCH or INVALID; reasons for INVALID go to stderr.

Exit codes:
	0 - success / all rows match
	1 - at least one row does not match
	2 - invalid input (malformed hash, empty password, unreadable file)
"""

import argparse
import base64
import binascii
import csv
import hashlib
import hmac
import sys
from collections.abc import Iterator

KEY_BYTES = 32
KEY_CHARS = 52

EXIT_OK = 0
EXIT_MISMATCH = 1
EXIT_INVALID = 2

STATUS_NAMES = {
	EXIT_OK: "OK",
	EXIT_MISMATCH: "MISMATCH",
	EXIT_INVALID: "INVALID",
}

DELIMITER = ";"
COL_PASSWORD = 0
COL_HASH = 1

HEADER_NAMES = {"password"}


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
	Derive the raw 32-byte channel key from a password.

	@param text Source password (encoded as UTF-8).
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
	Derive the printable channel key for a password.

	@param text Source password.
	@returns 52-character key string.
	"""
	return key_to_text(derive_key(text))


def check_row(password: str, key: str) -> tuple[int, str]:
	"""
	Check one password against one hash.

	@param password Source password.
	@param key Expected hash (key string).
	@returns (status, reason); reason is empty unless the row is invalid.
	"""
	if not password:
		return EXIT_INVALID, "empty password"

	if not key.strip():
		return EXIT_INVALID, "missing hash"

	expected = text_to_key(key)
	if expected is None:
		return EXIT_INVALID, f"hash is not a {KEY_CHARS}-char base32 key"

	if not hmac.compare_digest(derive_key(password), expected):
		return EXIT_MISMATCH, ""
	return EXIT_OK, ""


def use_utf8_streams() -> None:
	"""
	Force UTF-8 on stdin/stdout.

	On Windows, piped streams default to the ANSI code page (e.g. cp1251),
	which would silently turn non-ASCII input into a different password and
	therefore a different key. "utf-8-sig" also drops a leading BOM.
	"""
	sys.stdin.reconfigure(encoding="utf-8-sig")
	sys.stdout.reconfigure(encoding="utf-8")


def csv_writer():
	"""
	Create a ";"-delimited CSV writer on stdout.

	@returns csv writer object.
	"""
	return csv.writer(sys.stdout, delimiter=DELIMITER, lineterminator="\n")


def is_header(row: list[str]) -> bool:
	"""
	Tell whether a row is a header (column names, not data).

	@param row Parsed CSV row.
	@returns True if the password column holds a known column name.
	"""
	return row[COL_PASSWORD].strip().lower() in HEADER_NAMES


def parse_rows(lines) -> Iterator[tuple[int, list[str], bool]]:
	"""
	Parse ";"-delimited CSV, skipping empty rows.

	@param lines Iterable of text lines (file or stdin).
	@returns Iterator of (line number, row, is header) tuples.
	"""
	reader = csv.reader(lines, delimiter=DELIMITER)
	first = True
	for row in reader:
		if not any(field.strip() for field in row):
			continue
		yield reader.line_num, row, first and is_header(row)
		first = False


def read_rows(path: str | None) -> list[tuple[int, list[str], bool]]:
	"""
	Read CSV rows from a file or stdin.

	@param path File to read, or None for stdin.
	@returns List of (line number, row, is header) tuples.
	"""
	if path is None:
		return list(parse_rows(sys.stdin))

	with open(path, encoding="utf-8-sig", newline="") as source:
		return list(parse_rows(source))


def report_invalid(line: int | None, reason: str) -> None:
	"""
	Print why a row is invalid to stderr.

	@param line Line number in the input, or None for command-line input.
	@param reason Human-readable reason.
	"""
	where = f"line {line}: " if line is not None else ""
	print(f"{where}{reason}", file=sys.stderr)


def fill_hash(row: list[str]) -> list[str]:
	"""
	Return a copy of a row with the hash column set from the password.

	@param row Parsed CSV row (password first).
	@returns Row with at least two columns; extra columns kept as is.
	"""
	filled = list(row) + [""] * (COL_HASH + 1 - len(row))
	filled[COL_HASH] = encode_string(row[COL_PASSWORD])
	return filled


def cmd_encode(args: argparse.Namespace) -> int:
	"""
	Handle "encode": print "password;hash[;channel;note]" rows.

	The output format matches what "verify" reads.

	@param args Parsed arguments.
	@returns Exit code.
	"""
	if args.passwords:
		rows = [(None, [password], False) for password in args.passwords]
	else:
		rows = read_rows(args.file)

	writer = csv_writer()
	worst = EXIT_OK
	for line, row, header in rows:
		if header:
			writer.writerow(row)
			continue
		if not row[COL_PASSWORD]:
			report_invalid(line, "empty password")
			worst = EXIT_INVALID
			continue
		writer.writerow(fill_hash(row))
	return worst


def cmd_verify(args: argparse.Namespace) -> int:
	"""
	Handle "verify" for one pair or for CSV rows; channel/note are ignored.

	@param args Parsed arguments.
	@returns Worst exit code among all rows.
	"""
	if args.password is not None and args.file is not None:
		print("verify: use either PASSWORD HASH or -f FILE", file=sys.stderr)
		return EXIT_INVALID

	if args.password is not None:
		if args.hash is None:
			print("verify: HASH is required with PASSWORD", file=sys.stderr)
			return EXIT_INVALID
		rows = [(None, [args.password, args.hash], False)]
	else:
		rows = read_rows(args.file)

	writer = csv_writer()
	worst = EXIT_OK
	for line, row, header in rows:
		if header:
			continue
		password = row[COL_PASSWORD]
		key = row[COL_HASH] if len(row) > COL_HASH else ""
		status, reason = check_row(password, key)
		if reason:
			report_invalid(line, reason)
		writer.writerow([STATUS_NAMES[status], password, key.strip()])
		worst = max(worst, status)
	return worst


def build_parser() -> argparse.ArgumentParser:
	"""
	Build the command-line parser; each command maps to its handler.

	@returns Configured parser.
	"""
	parser = argparse.ArgumentParser(
		description="Derive and verify Tixati channel keys "
		"(base32(clamp25519(SHA-256(password)))). "
		"CSV format: password;hash;channel;note."
	)
	commands = parser.add_subparsers(dest="command", required=True)

	encode = commands.add_parser("encode", help="derive hashes from passwords")
	encode.add_argument(
		"passwords", nargs="*", help="passwords to encode (default: CSV input)"
	)
	encode.add_argument(
		"-f", "--file", help="read CSV from FILE and fill in the hash column"
	)
	encode.set_defaults(handler=cmd_encode)

	verify = commands.add_parser("verify", help="check passwords against hashes")
	verify.add_argument("password", nargs="?", help="source password")
	verify.add_argument("hash", nargs="?", help="expected hash")
	verify.add_argument("-f", "--file", help="read CSV rows from FILE")
	verify.set_defaults(handler=cmd_verify)

	return parser


def main() -> int:
	"""
	Entry point.

	@returns Process exit code.
	"""
	use_utf8_streams()
	args = build_parser().parse_args()
	try:
		return args.handler(args)
	except UnicodeDecodeError:
		print(
			"cannot read input: not UTF-8 (in Excel, save as \"CSV UTF-8\")",
			file=sys.stderr,
		)
		return EXIT_INVALID
	except (OSError, csv.Error) as error:
		print(f"cannot read input: {error}", file=sys.stderr)
		return EXIT_INVALID


if __name__ == "__main__":
	sys.exit(main())
