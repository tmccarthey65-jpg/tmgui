#!/usr/bin/env python3

import requests
import csv
import xml.etree.ElementTree as ET
import os
import json
import urllib.request
from datetime import datetime
from plex_config import PLEX_IP, PLEX_TOKEN, OUTPUT_DIR, LIBRARIES, GOOGLE_SHEET_WEBAPP_URL

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
        media = video.find('Media')
        part = media.find('Part') if media is not None else None
        file_path = part.get('file', '') if part is not None else ''
        rows.append({
            'Title':    video.get('title', ''),
            'Year':     video.get('year', ''),
            'Rating':   video.get('audienceRating') or video.get('rating', ''),
            'Studio':   video.get('studio', ''),
            'Added':    datetime.fromtimestamp(int(video.get('addedAt', 0))).strftime('%Y-%m-%d'),
            'Path':     file_path,
            'Filename': os.path.basename(file_path) if file_path else '',
        })
    rows.sort(key=lambda r: r['Title'].lower())
    rows.sort(key=lambda r: r['Added'], reverse=True)
    filename = f"{OUTPUT_DIR}/plex_{name.replace(' ', '_').lower()}.csv"
    with open(filename, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=['Title', 'Year', 'Rating', 'Studio', 'Added', 'Path', 'Filename'])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Saved {len(rows)} titles -> {filename}")

def export_shows(key, name):
    print(f"Fetching {name}...")
    root = get_library(key, name)
    rows = []
    for show in root.findall('Directory'):
        rating_key = show.get('ratingKey')
        seasons_list = []
        if rating_key:
            try:
                c_url = f"{BASE_URL}/library/metadata/{rating_key}/children?X-Plex-Token={PLEX_TOKEN}"
                c_resp = requests.get(c_url)
                c_resp.raise_for_status()
                c_root = ET.fromstring(c_resp.content)
                for child in c_root.findall('Directory'):
                    c_title = child.get('title')
                    if c_title and c_title.lower() != 'all episodes':
                        seasons_list.append(c_title)
            except Exception as e:
                print(f"  Error fetching seasons for {show.get('title')}: {e}")

        rows.append({
            'Title':        show.get('title', ''),
            'Seasons':      ':'.join(seasons_list),
            'Year':         show.get('year', ''),
            'Rating':       show.get('audienceRating') or show.get('rating', ''),
            'Season Count': show.get('childCount', ''),
            'Episodes':     show.get('leafCount', ''),
            'Added':        datetime.fromtimestamp(int(show.get('addedAt', 0))).strftime('%Y-%m-%d'),
        })
    rows.sort(key=lambda r: r['Title'].lower())
    rows.sort(key=lambda r: r['Added'], reverse=True)
    filename = f"{OUTPUT_DIR}/plex_{name.replace(' ', '_').lower()}.csv"
    with open(filename, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=['Title', 'Seasons', 'Year', 'Rating', 'Season Count', 'Episodes', 'Added'])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Saved {len(rows)} titles -> {filename}")

def upload_to_sheets(csv_file_path, data_type):
    if not GOOGLE_SHEET_WEBAPP_URL:
        print(f"Skipping Google Sheets upload for {data_type} (GOOGLE_SHEET_WEBAPP_URL is not set).")
        return
    
    print(f"Uploading {data_type} to Google Sheets...")
    try:
        with open(csv_file_path, mode='r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            data = list(reader)
            
        payload = json.dumps({
            'type': data_type,
            'data': data
        }).encode('utf-8')
        
        req = urllib.request.Request(
            GOOGLE_SHEET_WEBAPP_URL,
            data=payload,
            headers={'Content-Type': 'application/json'}
        )
        
        with urllib.request.urlopen(req) as response:
            res = response.read().decode('utf-8')
            print(f"  Sheets API Response: {res}")
    except Exception as e:
        print(f"  Failed to upload {data_type}: {e}")

if __name__ == '__main__':
    export_movies('10', 'Movies')
    export_shows('15', 'TV Shows')
    
    # Upload to Google Sheets
    movies_csv = f"{OUTPUT_DIR}/plex_movies.csv"
    shows_csv = f"{OUTPUT_DIR}/plex_tv_shows.csv"
    upload_to_sheets(movies_csv, 'movies')
    upload_to_sheets(shows_csv, 'shows')
    
    print("Done.")
