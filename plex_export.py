#!/usr/bin/env python3

import requests
import csv
import xml.etree.ElementTree as ET
from datetime import datetime
from plex_config import PLEX_IP, PLEX_TOKEN, OUTPUT_DIR, LIBRARIES

BASE_URL = f'http://{PLEX_IP}:32400'

def get_library(key, name):
    url = f'{BASE_URL}/library/sections/{key}/all?X-Plex-Token={PLEX_TOKEN}'
    resp = requests.get(url)
    resp.raise_for_status()
    return ET.fromstring(resp.content)

def export_movies(key, name):
    print(f"Fetching {name}...")
    root = get_library(key, name)
    rows = []
    for video in root.findall('Video'):
        rows.append({
            'Title':  video.get('title', ''),
            'Year':   video.get('year', ''),
            'Rating': video.get('audienceRating') or video.get('rating', ''),
            'Studio': video.get('studio', ''),
            'Added':  datetime.fromtimestamp(int(video.get('addedAt', 0))).strftime('%Y-%m-%d'),
        })
    rows.sort(key=lambda r: r['Title'].lower())
    filename = f"{OUTPUT_DIR}/plex_{name.replace(' ', '_').lower()}.csv"
    with open(filename, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=['Title', 'Year', 'Rating', 'Studio', 'Added'])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Saved {len(rows)} titles -> {filename}")

def export_shows(key, name):
    print(f"Fetching {name}...")
    root = get_library(key, name)
    rows = []
    for show in root.findall('Directory'):
        rows.append({
            'Title':    show.get('title', ''),
            'Year':     show.get('year', ''),
            'Rating':   show.get('audienceRating') or show.get('rating', ''),
            'Seasons':  show.get('childCount', ''),
            'Episodes': show.get('leafCount', ''),
            'Added':    datetime.fromtimestamp(int(show.get('addedAt', 0))).strftime('%Y-%m-%d'),
        })
    rows.sort(key=lambda r: r['Title'].lower())
    filename = f"{OUTPUT_DIR}/plex_{name.replace(' ', '_').lower()}.csv"
    with open(filename, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=['Title', 'Year', 'Rating', 'Seasons', 'Episodes', 'Added'])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Saved {len(rows)} titles -> {filename}")

if __name__ == '__main__':
    export_movies('10', 'Movies')
    export_shows('15', 'TV Shows')
    print("Done.")
