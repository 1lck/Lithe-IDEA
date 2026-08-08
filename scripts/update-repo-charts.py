#!/usr/bin/env python3
"""Generate README charts from GitHub API responses."""

from __future__ import annotations

import argparse
import base64
import html
import json
import math
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib import request
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


CHART_WIDTH = 1200
CHART_HEIGHT = 680
PLOT_LEFT = 115
PLOT_RIGHT = 1135
PLOT_TOP = 112
PLOT_BOTTOM = 535
CHART_TIMEZONE = timezone(timedelta(hours=8))
STAR_HISTORY_START_DATE = date(2026, 8, 2)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="Repository name, for example 1lck/Lithe-IDEA")
    parser.add_argument("--stargazers", type=Path, required=True)
    parser.add_argument("--contributors", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def flatten_pages(payload: object) -> list[dict]:
    if not isinstance(payload, list):
        return []

    if payload and all(isinstance(page, list) for page in payload):
        return [item for page in payload for item in page if isinstance(item, dict)]

    return [item for item in payload if isinstance(item, dict)]


def load_entries(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as stream:
        return flatten_pages(json.load(stream))


def parse_starred_date(entry: dict) -> date | None:
    raw_value = entry.get("starred_at")
    if not isinstance(raw_value, str):
        return None

    try:
        starred_at = datetime.fromisoformat(raw_value.replace("Z", "+00:00"))
        if starred_at.tzinfo is None:
            starred_at = starred_at.replace(tzinfo=timezone.utc)
        return starred_at.astimezone(CHART_TIMEZONE).date()
    except ValueError:
        return None


def add_query_parameter(url: str, key: str, value: str) -> str:
    parts = urlsplit(url)
    query = dict(parse_qsl(parts.query, keep_blank_values=True))
    query[key] = value
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))


def nice_maximum(value: int) -> int:
    if value <= 0:
        return 1

    exponent = 10 ** int(math.floor(math.log10(value)))
    normalized = value / exponent
    if normalized <= 1:
        step = 1
    elif normalized <= 2:
        step = 2
    elif normalized <= 5:
        step = 5
    else:
        step = 10
    return int(step * exponent)


def format_number(value: int) -> str:
    return f"{value:,}"


def format_date(value: date) -> str:
    return value.strftime("%b %d")


def svg_text(x: float, y: float, value: str, **attributes: str) -> str:
    rendered_attributes = " ".join(
        f'{key.replace("_", "-")}="{html.escape(str(attribute), quote=True)}"'
        for key, attribute in attributes.items()
    )
    return f'<text x="{x:.2f}" y="{y:.2f}" {rendered_attributes}>{html.escape(value)}</text>'


def avatar_data_uri(url: str) -> str | None:
    parts = urlsplit(url)
    if parts.scheme != "https":
        return None

    try:
        avatar_request = request.Request(
            add_query_parameter(url, "s", "136"),
            headers={"User-Agent": "Lithe-IDEA chart generator"},
        )
        with request.urlopen(avatar_request, timeout=10) as response:
            content_type = response.headers.get_content_type()
            if not content_type.startswith("image/"):
                return None
            encoded = base64.b64encode(response.read()).decode("ascii")
    except (OSError, ValueError):
        return None

    return f"data:{content_type};base64,{encoded}"


def monotone_curve_path(coordinates: list[tuple[float, float]]) -> tuple[str, list[str]]:
    if len(coordinates) == 1:
        x, y = coordinates[0]
        path = f"M {x:.2f},{y:.2f}"
        return path, []

    intervals = [coordinates[index + 1][0] - coordinates[index][0] for index in range(len(coordinates) - 1)]
    slopes = [
        (coordinates[index + 1][1] - coordinates[index][1]) / intervals[index]
        for index in range(len(intervals))
    ]
    tangents = [slopes[0]]
    for index in range(1, len(coordinates) - 1):
        previous_slope = slopes[index - 1]
        next_slope = slopes[index]
        if previous_slope * next_slope <= 0:
            tangents.append(0.0)
            continue
        previous_interval = intervals[index - 1]
        next_interval = intervals[index]
        previous_weight = 2 * next_interval + previous_interval
        next_weight = next_interval + 2 * previous_interval
        tangents.append(
            (previous_weight + next_weight)
            / (previous_weight / previous_slope + next_weight / next_slope)
        )
    tangents.append(slopes[-1])

    commands: list[str] = []
    for index, interval in enumerate(intervals):
        x1, y1 = coordinates[index]
        x2, y2 = coordinates[index + 1]
        commands.append(
            " ".join(
                [
                    "C",
                    f"{x1 + interval / 3:.2f},{y1 + tangents[index] * interval / 3:.2f}",
                    f"{x2 - interval / 3:.2f},{y2 - tangents[index + 1] * interval / 3:.2f}",
                    f"{x2:.2f},{y2:.2f}",
                ]
            )
        )
    x, y = coordinates[0]
    return " ".join([f"M {x:.2f},{y:.2f}", *commands]), commands


def star_history_svg(repo: str, entries: list[dict], dark: bool) -> str:
    counts = Counter(
        starred_date
        for entry in entries
        if (starred_date := parse_starred_date(entry)) is not None
    )

    today = datetime.now(CHART_TIMEZONE).date()
    first_day = STAR_HISTORY_START_DATE
    last_day = max(first_day, today)

    span = max((last_day - first_day).days, 1)
    cumulative = sum(count for starred_date, count in counts.items() if starred_date < first_day)
    points: list[tuple[date, int]] = []
    current_day = first_day
    while current_day <= last_day:
        points.append((current_day, cumulative))
        cumulative += counts[current_day]
        current_day += timedelta(days=1)

    maximum = nice_maximum(max((value for _, value in points), default=1))
    plot_width = PLOT_RIGHT - PLOT_LEFT
    plot_height = PLOT_BOTTOM - PLOT_TOP

    def point_for(index: int, value: int) -> tuple[float, float]:
        x = PLOT_LEFT + (index / span) * plot_width
        y = PLOT_BOTTOM - (value / maximum) * plot_height
        return x, y

    coordinates = [point_for(index, value) for index, (_, value) in enumerate(points)]
    path, curve_commands = monotone_curve_path(coordinates)
    area_path = " ".join(
        [
            f"M {coordinates[0][0]:.2f},{PLOT_BOTTOM:.2f}",
            f"L {coordinates[0][0]:.2f},{coordinates[0][1]:.2f}",
            *curve_commands,
            f"L {coordinates[-1][0]:.2f},{PLOT_BOTTOM:.2f}",
            "Z",
        ]
    )

    background = "#ffffff" if not dark else "#111827"
    foreground = "#111111" if not dark else "#f3f4f6"
    muted = "#4b5563" if not dark else "#d1d5db"
    grid = "#e5e7eb" if not dark else "#374151"
    accent = "#e34b2d"
    tick_count = 4
    latest_x, latest_y = coordinates[-1]
    latest_label = f"{format_number(points[-1][1])} stars"
    latest_label_x = latest_x - 18
    latest_label_y = max(PLOT_TOP + 28, latest_y - 18)
    elements = [
        f'<rect width="{CHART_WIDTH}" height="{CHART_HEIGHT}" fill="{background}"/>',
        svg_text(600, 46, "Star History", text_anchor="middle", font_size="34", font_weight="700", fill=foreground),
        svg_text(600, 78, "Cumulative GitHub Stars at 00:00 Beijing time", text_anchor="middle", font_size="17", fill=muted),
        f'<line x1="{PLOT_LEFT}" y1="{PLOT_BOTTOM}" x2="{PLOT_RIGHT}" y2="{PLOT_BOTTOM}" stroke="{foreground}" stroke-width="2"/>',
        f'<line x1="{PLOT_LEFT}" y1="{PLOT_TOP}" x2="{PLOT_LEFT}" y2="{PLOT_BOTTOM}" stroke="{foreground}" stroke-width="2"/>',
        svg_text(54, 325, "GitHub Stars", text_anchor="middle", transform="rotate(-90 54 325)", font_size="22", fill=foreground),
        svg_text(625, 635, "Date", text_anchor="middle", font_size="22", fill=foreground),
    ]

    for tick in range(tick_count + 1):
        value = int(maximum * tick / tick_count)
        y = PLOT_BOTTOM - (tick / tick_count) * plot_height
        elements.append(
            f'<line x1="{PLOT_LEFT}" y1="{y:.2f}" x2="{PLOT_RIGHT}" y2="{y:.2f}" stroke="{grid}" stroke-width="1" stroke-dasharray="4 8"/>'
        )
        elements.append(svg_text(PLOT_LEFT - 18, y + 6, format_number(value), text_anchor="end", font_size="17", fill=muted))

    label_indices = sorted({0, len(points) // 4, len(points) // 2, (len(points) * 3) // 4, len(points) - 1})
    for index in label_indices:
        x, _ = point_for(index, 0)
        elements.append(svg_text(x, PLOT_BOTTOM + 40, format_date(points[index][0]), text_anchor="middle", font_size="18", fill=foreground))

    elements.extend(
        [
            f'<path d="{area_path}" fill="{accent}" fill-opacity="0.10" stroke="none"/>',
            f'<path d="{path}" fill="none" stroke="{accent}" stroke-width="4" stroke-linejoin="round" stroke-linecap="round"/>',
            *[
                f'<circle cx="{x:.2f}" cy="{y:.2f}" r="5" fill="{background}" stroke="{accent}" stroke-width="3"/>'
                for x, y in coordinates
            ],
            f'<circle cx="{latest_x:.2f}" cy="{latest_y:.2f}" r="10" fill="none" stroke="{accent}" stroke-opacity="0.24" stroke-width="5"/>',
            f'<rect x="{latest_label_x - 76:.2f}" y="{latest_label_y - 27:.2f}" width="76" height="26" rx="13" fill="{background}" stroke="{accent}" stroke-width="1.5"/>',
            svg_text(latest_label_x - 38, latest_label_y - 9, latest_label, text_anchor="middle", font_size="15", font_weight="700", fill=foreground),
            f'<rect x="{PLOT_LEFT + 20}" y="{PLOT_TOP + 18}" width="300" height="58" rx="12" fill="{background}" stroke="{grid}" stroke-width="1.5"/>',
            f'<circle cx="{PLOT_LEFT + 43}" cy="{PLOT_TOP + 47}" r="6" fill="{accent}"/>',
            svg_text(PLOT_LEFT + 64, PLOT_TOP + 53, repo, font_size="19", font_weight="600", fill=foreground),
        ]
    )

    return "\n".join(
        [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CHART_WIDTH} {CHART_HEIGHT}" role="img" aria-label="Star history at Beijing midnight for {html.escape(repo, quote=True)}">',
            f'<style>text {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; letter-spacing: 0; }}</style>',
            *elements,
            "</svg>",
        ]
    )


def contributor_color(login: str) -> str:
    palette = ["#8b5cf6", "#0ea5e9", "#10b981", "#f59e0b", "#ef4444", "#ec4899"]
    return palette[sum(ord(character) for character in login) % len(palette)]


def contributor_svg(repo: str, entries: list[dict]) -> str:
    contributors = entries[:100]
    columns = 12
    avatar_size = 68
    gap = 14
    margin = 28
    rows = max(1, math.ceil(len(contributors) / columns))
    width = margin * 2 + columns * avatar_size + (columns - 1) * gap
    height = margin * 2 + rows * avatar_size + (rows - 1) * gap
    avatar_cache: dict[str, str | None] = {}
    elements = [
        f'<rect width="{width}" height="{height}" fill="transparent"/>',
        f'<title>Contributors to {html.escape(repo, quote=True)}</title>',
    ]

    for index, contributor in enumerate(contributors):
        login = str(contributor.get("login") or "Anonymous contributor")
        avatar_url = contributor.get("avatar_url")
        profile_url = contributor.get("html_url") or f"https://github.com/{login}"
        x = margin + (index % columns) * (avatar_size + gap)
        y = margin + (index // columns) * (avatar_size + gap)
        clip_id = f"avatar-{index}"
        contributions = contributor.get("contributions", 0)
        label = f"{login} ({contributions} contributions)"
        elements.append(f'<clipPath id="{clip_id}"><circle cx="{x + avatar_size / 2}" cy="{y + avatar_size / 2}" r="{avatar_size / 2 - 2}"/></clipPath>')
        elements.append(f'<a href="{html.escape(str(profile_url), quote=True)}">')
        avatar_href = None
        if isinstance(avatar_url, str) and avatar_url:
            if avatar_url not in avatar_cache:
                avatar_cache[avatar_url] = avatar_data_uri(avatar_url)
            avatar_href = avatar_cache[avatar_url]
        if avatar_href:
            elements.append(
                f'<image href="{avatar_href}" x="{x}" y="{y}" width="{avatar_size}" height="{avatar_size}" preserveAspectRatio="xMidYMid slice" clip-path="url(#{clip_id})"/>'
            )
        else:
            elements.append(f'<circle cx="{x + avatar_size / 2}" cy="{y + avatar_size / 2}" r="{avatar_size / 2 - 2}" fill="{contributor_color(login)}"/>')
            elements.append(svg_text(x + avatar_size / 2, y + avatar_size / 2 + 7, login[:1].upper(), text_anchor="middle", font_size="28", font_weight="700", fill="#ffffff"))
        elements.append(f'<circle cx="{x + avatar_size / 2}" cy="{y + avatar_size / 2}" r="{avatar_size / 2 - 2}" fill="none" stroke="#9ca3af" stroke-width="2"/>')
        elements.append(f'<title>{html.escape(label)}</title>')
        elements.append("</a>")

    return "\n".join(
        [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img" aria-label="Contributors to {html.escape(repo, quote=True)}">',
            '<style>text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; letter-spacing: 0; }</style>',
            *elements,
            "</svg>",
        ]
    )


def main() -> None:
    arguments = parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)
    stargazers = load_entries(arguments.stargazers)
    contributors = load_entries(arguments.contributors)
    (arguments.output / "star-history-light.svg").write_text(star_history_svg(arguments.repo, stargazers, dark=False), encoding="utf-8")
    (arguments.output / "star-history-dark.svg").write_text(star_history_svg(arguments.repo, stargazers, dark=True), encoding="utf-8")
    (arguments.output / "contributors.svg").write_text(contributor_svg(arguments.repo, contributors), encoding="utf-8")


if __name__ == "__main__":
    main()
