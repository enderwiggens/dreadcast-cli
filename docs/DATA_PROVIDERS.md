# Data providers

Dreadcast CLI requests public data directly from each provider. Each source has its own
refresh interval in the shared cache, so running many commands, or a prompt in many
shells, never polls a provider faster than this table allows.

| Data | Provider | Refresh | Coverage | Terms |
| --- | --- | --- | --- | --- |
| Current conditions, hourly and daily forecast, 15-minute precipitation | [Open-Meteo forecast API](https://open-meteo.com/en/docs) | 10 min | Worldwide | CC BY 4.0; free for non-commercial use |
| Place search | [Open-Meteo geocoding](https://open-meteo.com/en/docs/geocoding-api) | On setup | Worldwide | CC BY 4.0 |
| Air quality and dust | [Open-Meteo air quality](https://open-meteo.com/en/docs/air-quality-api) (CAMS) | 30 min (dust 15 min) | Worldwide | CC BY 4.0; CAMS attribution |
| ZIP lookup | [Zippopotam.us](https://zippopotam.us/) | Cached 30 days | United States | Free API |
| Radar (contiguous US, when a Dreadcast API is set) | [NOAA MRMS](https://www.nssl.noaa.gov/projects/mrms/) base reflectivity through the Dreadcast API (`/v1/radar/latest`) | Manifest 1 min; tiles are immutable and cached until they age out | Contiguous US | Public domain (U.S. Government data); numeric tiles, zoom 3–8 |
| Radar (everywhere else, and when the API is unavailable) | [RainViewer Weather Maps API](https://www.rainviewer.com/api/weather-maps-api.html) | Manifest 5 min; tiles cached until they age out | Worldwide where radar exists | Free API for personal and non-commercial use; maximum zoom 7 |
| Active alerts | [National Weather Service](https://www.weather.gov/documentation/services-web-api) | 2 min | US and territories | Public domain; identifying User-Agent required |
| Day 1 convective outlook | [NOAA SPC](https://www.spc.noaa.gov/products/outlook/) | 15 min | Contiguous US | Public domain |
| Tropical cyclones | [NOAA NHC](https://www.nhc.noaa.gov/) | 15 min | Atlantic and eastern Pacific | Public domain |
| Wildfires | [NIFC WFIGS](https://data-nifc.opendata.arcgis.com/) | 5 min | United States | Public domain |
| Kp index | [NOAA SWPC](https://www.swpc.noaa.gov/) | 10 min | Global | Public domain |
| Aurora | [NOAA SWPC OVATION](https://www.swpc.noaa.gov/products/aurora-30-minute-forecast) | 15 min | Global | Public domain |
| HF radio absorption | [NOAA SWPC D-RAP](https://www.swpc.noaa.gov/products/d-region-absorption-predictions-d-rap) | 15 min | Global | Public domain |
| Earthquakes | [USGS](https://earthquake.usgs.gov/earthquakes/feed/) | 5 min | Global, M2.5+ | Public domain |
| Volcanoes | [USGS HANS](https://volcanoes.usgs.gov/hans-public/) | 15 min | US-monitored volcanoes | Public domain |
| Tsunamis | [NTWC / PTWC](https://www.tsunami.gov/) | 15 min | Bulletin areas | Public domain |
| Smoke | [NOAA HMS](https://www.ospo.noaa.gov/products/land/hms.html) | 15 min | North America | Public domain |
| Meteor showers | [American Meteor Society calendar](https://www.amsmeteors.org/calendar/) | Built in | Global | Dated list, checked 2026-10-03 |
| Lightning (optional) | [Xweather](https://www.xweather.com/) | 1 min | Global, 62-mile radius | Your own account and plan |
| Basemap | [Natural Earth](https://www.naturalearthdata.com/) 1:50m | Built in | Global | Public domain |

## Failure behavior

Each source fails independently. When a refresh fails, Dreadcast CLI shows the last good
reading for a limited time and labels it stale with its age. When nothing usable is
cached, it says the source is unavailable. Missing alert data is never reported as an
all-clear, and `dread alerts` exits 3 rather than 0.

Radar from the Dreadcast API is labeled "radar delayed" with its age once the newest
scan is more than 10 minutes old, and isn't used after 3 hours. If the API can't
provide a loop, the radar comes from RainViewer instead, credited as such.

## Choosing the radar source

`dread config set api-url <url>` (or `DREADCAST_API_URL`) points the CLI at a Dreadcast
API. With one set, places in the contiguous US get NOAA MRMS radar from it; places
elsewhere keep RainViewer. `dread config set radar-source rainviewer` uses RainViewer
everywhere. Until the public API is live, no API is set by default, so nothing changes
unless you set one.

## Adding a provider

1. Add provider-neutral models and a decoder in `DreadcastKit`, with tests that use
   inline fixtures. Tests never contact live services.
2. Add a cached loader in `Context` with an honest refresh interval.
3. Update this file, `docs/PRIVACY.md`, `dread credits` and the README.
4. Confirm the provider's terms allow a free, open-source client to call it directly.
