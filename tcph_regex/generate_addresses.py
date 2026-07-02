"""Helpers for generating plausible mailing addresses with Faker."""

from __future__ import annotations

from enum import Enum

from faker import Faker

MAX_ADDRESS_LEN = 40

_FAKER_DE = Faker("de_DE")
_FAKER_GB = Faker("en_GB")


class AddressKind(str, Enum):
    MATCH = "match"
    DE_STREET_FIRST = "de_street_first"
    DE_WRONG_POSTCODE = "de_wrong_postcode"
    DE_MULTIWORD = "de_multiword"
    FOREIGN = "foreign"


def _truncate(address: str) -> str:
    return address if len(address) <= MAX_ADDRESS_LEN else address[:MAX_ADDRESS_LEN]


def _ascii_word(text: str) -> str:
    """Return a single ASCII alphanumeric token (DuckDB ``\\w+`` is ASCII-only)."""
    normalized = (
        text.replace("ä", "ae")
        .replace("ö", "oe")
        .replace("ü", "ue")
        .replace("Ä", "Ae")
        .replace("Ö", "Oe")
        .replace("Ü", "Ue")
        .replace("ß", "ss")
    )
    token = normalized.split("-")[0].split()[0]
    chars = [char for char in token if char.isascii() and char.isalnum()]
    return "".join(chars) or "Str"


def _faker(seed: int, locale: str = "de_DE") -> Faker:
    fake = _FAKER_DE if locale == "de_DE" else _FAKER_GB
    fake.seed_instance(seed)
    return fake


def generate_address(kind: AddressKind, key: int, seed: int) -> str:
    """Build a VARCHAR(40) address for the given row key and benchmark bucket."""
    fake = _faker(key + seed)
    street = _ascii_word(fake.street_name())
    city = _ascii_word(fake.city())

    if kind is AddressKind.MATCH:
        dot = "." if (key % 2) == 0 else ""
        return _truncate(f"{key} {street}{dot} 8{key % 1000:03d} {city}")

    if kind is AddressKind.DE_STREET_FIRST:
        fake_postcode = fake.postcode().replace(" ", "")
        digits = "".join(char for char in fake_postcode if char.isdigit())
        postcode = digits[:5] if len(digits) >= 5 else f"{10000 + (key % 89999)}"
        return _truncate(f"{street} {key}, {postcode} {city}")

    if kind is AddressKind.DE_WRONG_POSTCODE:
        postcode = 1000 + (key % 6000)
        return _truncate(f"{key} {street} {postcode} {city}")

    if kind is AddressKind.DE_MULTIWORD:
        return _truncate(f"{key} {street} Ring 8{key % 1000:03d} {city}")

    if kind is AddressKind.FOREIGN:
        foreign = _faker(key + seed + 1, locale="en_GB")
        foreign_city = _ascii_word(foreign.city())
        foreign_street = _ascii_word(foreign.street_name())
        postcode = 10000 + (key % 89999)
        return _truncate(f"{key} {foreign_street} St, {postcode} {foreign_city}")

    raise AssertionError(f"Unhandled address kind: {kind!r}")


if __name__ == "__main__":
    for address_kind in AddressKind:
        print(f"{address_kind.value}:")
        for demo_key in range(1, 4):
            print(" ", generate_address(address_kind, demo_key, seed=27_000))
