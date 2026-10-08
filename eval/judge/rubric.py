"""Scoring rubric shared by collection and reporting."""

AXES = ("accuracy", "naturalness", "context", "proper_nouns")
WEIGHTS = {"accuracy": 0.40, "naturalness": 0.25, "context": 0.25, "proper_nouns": 0.10}
REQUIRED_AXES = ("accuracy", "naturalness")   # always apply; null is not allowed for them
CRITICAL_TYPES = ("mistranslation", "addition", "omission", "proper_noun")
PREFERENCES = ("first", "second", "tie", "unrated")


def valid_score(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and 1 <= v <= 5


def weighted_score(scores: dict) -> float | None:
    """Weighted mean over the axes that apply (None axes are dropped and the weights renormalised).

    Returns None when no axis could be scored; callers must never turn that into 0.
    """
    used = {a: scores[a] for a in AXES if valid_score(scores.get(a))}
    if not used:
        return None
    total = sum(WEIGHTS[a] for a in used)
    return sum(WEIGHTS[a] * v for a, v in used.items()) / total
