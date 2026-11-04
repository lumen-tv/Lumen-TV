#!/usr/bin/env python3
"""Builds ios/Lumen/Resources/tv-logos-index.txt: which channel logos github.com/tv-logo/tv-logos has.

The app ships only this list of file names (no logos). It matches a channel's name against the list
and downloads the one logo it needs from the collection (see Theme/ChannelLogos.swift).

Usage (from the repo root; needs git and network):
    python3 ios/tools/tv_logos_index.py
Re-run now and then to pick up logos added to the collection.

Each line: key <TAB> country code <TAB> path in the repo.
key = the logo's name in lower-case letters and digits only ("bbc-one-uk" -> "bbcone"), with
variant words (hz = horizontal, alt, icon, white...) and the HD folder's "hd" taken off. When a
channel has several files, the plainest one wins (main folder over hd/, no variant word).
"""
import os, subprocess, sys, tempfile

VARIANTS = {'hz', 'alt', 'icon', 'white', 'black', 'light', 'dark', 'mono', 'color', 'colour', 'square', 'vertical', 'v'}
QUALITY = {'hd', 'uhd', 'fhd', '4k', 'hdr', 'ultra'}


def key_of(words):
    return ''.join(ch for ch in ''.join(words).lower() if ch.isalnum())


def main():
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Lumen', 'Resources', 'tv-logos-index.txt')
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(['git', 'clone', '-q', '--filter=blob:none', '--no-checkout', '--depth', '1',
                        'https://github.com/tv-logo/tv-logos.git', tmp], check=True)
        paths = subprocess.run(['git', '-C', tmp, '-c', 'core.quotePath=false', 'ls-tree', '-r', '--name-only', 'HEAD'],
                               check=True, capture_output=True, text=True).stdout.splitlines()
    best = {}
    for path in paths:
        if not path.startswith('countries/') or not path.endswith('.png'):
            continue
        words = os.path.basename(path)[:-4].split('-')
        if len(words) < 2:
            continue
        cc, words = words[-1].lower(), words[:-1]
        score = 2 if '/hd/' in path else 0
        while words and words[-1].lower() in VARIANTS | QUALITY:
            score += 1 if words[-1].lower() in QUALITY else 3
            words = words[:-1]
        key = key_of(words)
        if not key:
            continue
        rank = (score, len(path))
        if (key, cc) not in best or rank < best[(key, cc)][0]:
            best[(key, cc)] = (rank, path)
    lines = sorted(f'{k}\t{cc}\t{p}' for (k, cc), (_, p) in best.items())
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(lines) + '\n')
    print(f'{len(lines)} logos -> {os.path.relpath(out)}')


if __name__ == '__main__':
    sys.exit(main())
