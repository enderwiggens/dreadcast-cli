# Privacy

dreadcast runs entirely on your machine. It has no account, no server, no analytics
and no crash reporting.

## What is sent, and where

Requests go directly from your machine to each provider. Every request carries the
User-Agent `dreadcast-cli/<version> (+https://github.com/enderwiggens/dreadcast-cli)`,
which the National Weather Service asks clients to send.

Coordinates are rounded to two decimal places (about 1 km) before they are stored or
included in any request.

| Provider | What it receives |
| --- | --- |
| Open-Meteo | Rounded coordinates and unit choices (forecast, air quality, dust); place-name text when you search during setup |
| Zippopotam.us | A five-digit ZIP code, when you set up with one |
| National Weather Service | Rounded coordinates |
| RainViewer | Map tile coordinates around your location |
| NIFC | A bounding box around your location |
| NOAA SPC, NHC, SWPC, HMS; USGS; NTWC/PTWC | Nothing location-specific; the same public files for everyone |
| Xweather (optional) | Rounded coordinates, a search radius, and your client ID and secret |

Each provider also sees your IP address, as with any internet request.

## What is stored on this machine

| What | Where |
| --- | --- |
| Preferences and saved location | `~/.config/dreadcast/config.json` (or `$XDG_CONFIG_HOME/dreadcast`) |
| Cached readings and radar tiles | `~/Library/Caches/dreadcast` on macOS, `~/.cache/dreadcast` elsewhere |
| Xweather credentials | The login Keychain, service `dreadcast-cli` |

Radar tiles older than three hours are pruned automatically. Delete the cache folder
at any time; dreadcast rebuilds it. `dread auth remove` deletes saved credentials.

Credentials are never written to the config file, the cache, logs or command output,
including `--json`.
