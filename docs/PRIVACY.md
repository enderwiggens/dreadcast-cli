# Privacy

Dreadcast CLI runs on your machine. This version has no account, analytics or crash
reporting. It requests weather, air quality, place search and radar from the Dreadcast
API, and everything else directly from each provider below. It sends the Dreadcast API
an install token, described [below](#the-install-token), which you can turn off.

## What is sent, and where

Requests go directly from your machine to each provider. Every request carries the
User-Agent `dreadcast-cli/<version> (+https://github.com/enderwiggens/dreadcast-cli)`,
which the National Weather Service asks clients to send.

Coordinates are rounded to two decimal places (about 1 km) before they are stored or
included in any request.

If you save more than one place (`dread places`), each is a location in this sense.
While the app runs, it checks every saved place's conditions with the Dreadcast API every 10
minutes and, for US places, its alerts with the National Weather Service every 2
minutes. Radar tiles and the other location-specific sources are requested only for the
place you're viewing, and rain timing also for the row highlighted on the Places tab.
`dread now --all` and `dread alerts --all` make the same per-place requests once.

| Provider | What it receives |
| --- | --- |
| Zippopotam.us | A five-digit ZIP code, when you set up with one |
| National Weather Service | Rounded coordinates |
| Dreadcast API (unless turned off) | Rounded coordinates and unit choices for weather, air quality and dust, and place-name text when you search during setup. The radar loop is the same for every client; where satellite estimates fill in beyond the radar, the API also receives their map tile coordinates, so roughly the area you're looking at. It sees your IP address, and the install token while it's on. It asks Open-Meteo for the same rounded coordinates and search text, so Open-Meteo sees the API's address, not yours |
| DigitalOcean Spaces CDN (with the Dreadcast API) | Map tile coordinates around your location, so roughly the area you're looking at, and your IP address |
| NIFC | A bounding box around your location |
| NOAA SPC, NHC, SWPC, HMS; USGS; NTWC/PTWC | Nothing location-specific; the same public files for everyone |
| Xweather (optional) | Rounded coordinates, a search radius, and your client ID and secret |

Each provider also sees your IP address, as with any internet request.

## The install token

The first time Dreadcast CLI uses the Dreadcast API, it asks the API for an install
token: a random number, made by the API, with nothing about you or your machine in it.
It sends the token with each request to the API, and only to the API, never to the
tile CDN or another provider. The API then counts this install's requests apart from
others on your network and gives it its own, higher limits; without it, everything from
your network shares one allowance.

The token is the same on every request, so it identifies this install to the API. The
API keeps only a fingerprint of it (SHA-256), which kind of client asked for it, when,
and the last day it was used. It doesn't record your IP address, places or requests
with it, except in its logs when an install goes over its limit, and those logs are
deleted after a week. Installs unused for a year are deleted.

`dread config set install-token off` deletes the install from the API and the token
from this machine; requests then go without one and share your network's limits.
`DREADCAST_INSTALL_TOKEN=off` sends none for one run without deleting it.

## What is stored on this machine

| What | Where |
| --- | --- |
| Preferences and saved places | `~/.config/dreadcast/config.json` (or `$XDG_CONFIG_HOME/dreadcast`) |
| Cached readings and radar tiles | `~/Library/Caches/dreadcast` on macOS, `~/.cache/dreadcast` elsewhere |
| Xweather credentials | macOS: the login Keychain, service `dreadcast-cli`. Linux: `~/.config/dreadcast/credentials.json`, created readable only by you |
| The install token | `~/.config/dreadcast/install-token.json`, created readable only by you, one per API address |

Radar tiles older than three hours are pruned automatically. Delete the cache folder
at any time; Dreadcast CLI rebuilds it. `dread auth remove` deletes saved credentials.

Credentials and the install token are never written to the config file, the cache, logs
or command output, including `--json`.
