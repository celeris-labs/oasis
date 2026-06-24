"""Helpers for generating plausible German-style mailing addresses."""

from __future__ import annotations

import random

STREET_NAMES = (
    "Hauptstr",
    "Berliner",
    "Garten",
    "Ring",
    "Weg",
    "Allee",
    "Berg",
    "Tal",
    "Feld",
    "Park",
)

CITY_NAMES = (
    "Muenchen",
    "Augsburg",
    "Nuernberg",
    "Stuttgart",
    "Ulm",
    "Passau",
    "Ingolstadt",
    "Freising",
    "Rosenheim",
    "Bayreuth",
)


def german_address_match(rng: random.Random) -> str:
    """Address matching ``\\d+ \\w+.? 8\\d\\d\\d \\w+`` (post code in 8xxx range)."""
    number = rng.randint(1, 999)
    street = rng.choice(STREET_NAMES)
    postcode = 8000 + rng.randint(0, 999)
    city = rng.choice(CITY_NAMES)
    street_suffix = "." if rng.random() < 0.5 else ""
    return f"{number} {street}{street_suffix} {postcode} {city}"


def german_address_non_match(rng: random.Random) -> str:
    """Plausible German address that does not match the 8xxx post-code pattern."""
    number = rng.randint(1, 999)
    street = rng.choice(STREET_NAMES)
    city = rng.choice(CITY_NAMES)
    variant = rng.randint(0, 2)
    if variant == 0:
        # Street-first format (common in Faker output).
        postcode = rng.randint(10000, 99999)
        return f"{street} {number}, {postcode} {city}"
    if variant == 1:
        # Correct layout but post code outside the 8xxx range.
        postcode = rng.choice([rng.randint(1000, 6999), rng.randint(9000, 9999)])
        return f"{number} {street} {postcode} {city}"
    # Multi-word street name prevents the single-token ``\\w+`` street match.
    postcode = 8000 + rng.randint(0, 999)
    return f"{number} {street} Ring {postcode} {city}"


def generic_address(rng: random.Random) -> str:
    """Non-German address string that stays within VARCHAR(40)."""
    number = rng.randint(1, 9999)
    street = rng.choice(STREET_NAMES)
    city = rng.choice(("Paris", "London", "Rome", "Madrid", "Oslo", "Lyon"))
    postcode = rng.randint(10000, 99999)
    return f"{number} {street} St, {postcode} {city}"


if __name__ == "__main__":
    demo_rng = random.Random(0)
    print("Matching addresses:")
    for _ in range(10):
        print(" ", german_address_match(demo_rng))
    print("Non-matching addresses:")
    for _ in range(10):
        print(" ", german_address_non_match(demo_rng))
