# Third-party notices

Dreadcast CLI includes or adapts the following material.

## Natural Earth

Coastlines, lakes, country and state borders, and populated places in
`Sources/DreadcastKit/BasemapData.swift` are generated from Natural Earth 1:50m data by
`scripts/build-basemap.py`. Natural Earth is in the public domain.
https://www.naturalearthdata.com/about/terms-of-use/

## RainViewer color table

`Sources/DreadcastKit/RainViewerColorTable.swift` reproduces the Universal Blue color
table that RainViewer publishes for its Weather Maps API, so radar pixels can be
converted back to reflectivity.
https://www.rainviewer.com/api/color-schemes.html

## Viridis

The Viridis palette samples in `Sources/DreadcastKit/ViridisSamples.swift` come from
matplotlib's colormap by Nathaniel J. Smith, Stefan van der Walt and Eric Firing,
released under CC0. https://github.com/matplotlib/matplotlib/blob/v3.10.0/lib/matplotlib/_cm_listed.py

## SunCalc

The moon-phase calculation in `Sources/DreadcastKit/Outlook.swift` is adapted from
SunCalc 1.9.0.

```
SunCalc — BSD 2-Clause License
Copyright (c) 2014, Vladimir Agafonkin
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are
permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of
   conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list
   of conditions and the following disclaimer in the documentation and/or other
   materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Data providers

Weather data is not bundled; it is requested at run time from the providers listed in
[docs/DATA_PROVIDERS.md](docs/DATA_PROVIDERS.md), each under its own terms.
