**English** | [Italiano](README.it.md)

# Trainly

Trainly is a native iOS app for tracking Italian trains and looking up rail travel
information. It aggregates real‑time data from Trenitalia (ViaggiaTreno), Italo and
Trenord behind a single, uniform interface, and adds station departure/arrival
boards, ticket price lookup, infomobility notices and strike information.

The app talks directly to the carriers' public/unofficial endpoints. It uses no
authentication, no account and no server of its own: every request is stateless and
issued from the device.

## Requirements

- iOS 17.6+ (built and run against the iOS 26 SDK, SwiftUI lifecycle)
- Xcode with Swift 5
- No third‑party dependencies; only Apple frameworks (SwiftUI, Foundation,
  Combine, CommonCrypto)

App Transport Security: all endpoints are HTTPS except ViaggiaTreno and the MIT
strike feed, which are reached over HTTP and declared as ATS exception domains in
`Info.plist` (`viaggiatreno.it`, `scioperi.mit.gov.it`).

## Architecture

Standard SwiftUI + MVVM-ish layering, no external frameworks.

- **`TrainlyApp`** – app entry point. Owns the shared `FavoritesStore` and installs
  the global keyboard‑dismiss gesture.
- **`MainTabView`** – five tabs (Board, Search, Utility, Favorites, Settings) driven
  by `AppRouter`. The Utility tab uses a value‑based `NavigationStack` path so other
  screens can push into it programmatically.
- **`AppRouter`** (`ObservableObject`) – cross‑tab coordination: the selected tab,
  the Utility navigation path, a pending train search (used to route from the board
  or an infomobility link into the Search tab), and a pending infomobility target
  (used to jump from a train page to the relevant notice).
- **Models** – Codable request/response types for each carrier plus a single
  normalized `TrainJourney`/`TrainStop` model that the tracking UI renders,
  regardless of the source carrier. All raw response fields are optional to tolerate
  the carriers' inconsistent JSON.
- **NetworkRequests** – one service per data source, each exposing async functions
  that return either a raw response or a normalized `TrainJourney`.
- **Views** – SwiftUI screens. Shared UI helpers live in `Theme.swift`
  (`Color.logoTile`, the fixed light background used behind carrier logos) and
  `KeyboardDismiss.swift`.

### The normalized journey model

`TrainJourney` (in `TrainJourney.swift`) unifies the three carriers via failable/
throwing adapters:

- `init(trenitalia:)`, `init?(italo:)`, `init?(trenord:)`

Each adapter maps carrier‑specific fields to a common shape: train number, display
title, operator/category (mapped to an image asset name), origin/destination,
overall delay, last detection (Trenitalia only), and an array of `TrainStop`.

Every `TrainStop` carries scheduled / estimated / actual arrival and departure
times, platform (with a confirmed flag), passed flag, an optional carriage
orientation label, and an "extraordinary stop" flag.

- **Estimated times** are computed uniformly as *scheduled + current delay* for
  stops not yet reached, so future stops are colored consistently (green when on
  time/early, orange when late). Italo and Trenord provide their own projections but
  are normalized to the same rule. For Trenord the current delay is derived from the
  last completed stop, because the feed's overall `delay` field is unreliable.

## Data sources

| Source | Endpoint | Format |
| --- | --- | --- |
| Trenitalia (ViaggiaTreno) | `viaggiatreno.it/.../cercaNumeroTrenoTrenoAutocomplete`, `.../andamentoTreno` | plain text + JSON |
| Italo | `italoinviaggio.italotreno.com/api/RicercaTrenoService` | JSON |
| Trenord | `trenord.it/mia/bff/train/{id}` | AES‑256‑ECB encrypted JSON |
| RFI station board | `iechub.rfi.it/ArriviPartenze/ArrivalsDepartures/Monitor` | HTML |
| Ticketing (Le Frecce BFF) | `lefrecce.it/Channels.Website.BFF.WEB/website/locations/search`, `.../ticket/solutions` | JSON |
| Trenitalia station catalog | `trenitalia.com/content/trenitalia/it.cruscotto-stations.json` | JSON (ISO‑8859‑1) |
| MIT strikes | `scioperi.mit.gov.it/mit2/public/scioperi/rss` | RSS/XML |
| Trenitalia infomobility | `trenitalia.com/.../notizie-infomobilita.html` | HTML |

Notable handling:

- **Trenord** responses are encrypted. `TrenordService` derives an AES‑256 key as
  the SHA‑256 of a fixed passphrase and decrypts the body with CommonCrypto
  (ECB, PKCS7), then decodes the resulting `[TrenordSolution]` array.
- **RFI** and **Trenitalia infomobility** are HTML‑scraped with `NSRegularExpression`
  (dot‑matches‑newlines) because no JSON API exists.
- The **strike feed** is fetched over HTTPS with `Accept-Encoding: identity` to avoid
  a gzip body that URLSession would not transparently decode after the HTTP→HTTPS
  redirect.
- The **station catalog** is ISO‑8859‑1 encoded; it is re‑encoded to UTF‑8 before
  JSON decoding.

## Features

### Train tracking (Search tab)

- Search a train by number, selecting the carrier (Trenitalia / Italo / Trenord).
  A configurable default carrier (Settings) preselects the segment.
- **Silent cross‑carrier fallback**: if the number is not found on the chosen
  carrier, the other carriers are queried in the background; any that match are
  offered as alternatives ("not found on X, but available on Y/Z").
- **Trenitalia disambiguation**: the ViaggiaTreno autocomplete can return several
  runs for the same number. Runs that differ only by day (same origin) open today's
  run by default and expose a segmented **date picker** in the detail page; runs
  that are genuinely different trains (different origin) present a choice sheet.
- Recent searches are persisted and shown on the Search screen; tapping one re‑runs
  the search.

The train detail page (`TrainView`) shows:

- A header with the carrier as a badge, the train type + number as the title, the
  carrier logo (with a fixed light background), origin → destination, the position
  (last detection for Trenitalia, next stop otherwise) and the delay status
  (green = on time/early, orange = late, with early/late minute text).
- A red banner when the run is cancelled/modified/deviated (from Trenitalia's
  `subTitle`), or an orange "More info on the disruption" banner that links to the
  matching infomobility notice when the train is affected by one (only when the
  train was opened from search/board, not from infomobility itself).
- A vertical **timeline** of every stop with a color‑coded indicator, scheduled
  time (struck through when different), the live time (actual or estimated), the
  platform as a badge (light = scheduled, dark = confirmed), **extraordinary stops**
  highlighted in yellow, and, for Trenitalia, the carriage orientation
  ("Executive in coda/testa").
- A **date picker** when the same run exists on multiple days.
- Pull‑to‑refresh, a favorite toggle, and a report button.

### Station board (Board tab)

- A station picker with autocomplete over the embedded RFI station catalog
  (~2400 stations mapped to their RFI place ids), a "Recent" section persisted in
  `UserDefaults`, and a "Main stations" shortcut section.
- `StationBoardView` scrapes the RFI arrivals/departures monitor and shows a
  segmented Departures/Arrivals control. Each row shows the operator logo, the
  operator + category label, the destination/origin, the train number as a badge,
  the delay, the platform, and an animated railroad‑crossing indicator (two
  alternating red lights, synchronized across rows) when the train is arriving or
  departing.
- Tapping a train opens it in place (within the Board tab) so back navigation
  returns to the board. Segment switches clear the list and reload; loads are
  cancellation‑safe to avoid a stale error when switching quickly.

### Ticket search (Utility → Cerca Biglietto)

Price and timetable lookup via the Le Frecce booking BFF (search only; purchase is
not supported).

- Station inputs use instant local suggestions from the cached Trenitalia station
  catalog; the numeric location id required by the search is resolved on selection.
- A search form: origin/destination (with swap and reset), date/time, passenger
  counts, and a category filter (Frecce / Intercity / Regionali) passed to the API.
- Results open in a dedicated pushed page with client‑side filters (operator
  Trenitalia/Trenord, direct‑only). Each solution row shows the train chain, times,
  duration, direct/changes, minimum price and availability status.
- A solution detail page lists the trains (with stations, useful for changes) and
  **collapsible price classes** (STANDARD/PREMIUM/BUSINESS/EXECUTIVE or regional
  classes), each with its fares, remaining seats, and modifiable/refundable flags,
  plus a legend. Trenord trains that surface in Trenitalia results and multi‑station
  searches ("Tutte le stazioni") are handled and labeled with the specific station.

### Infomobility (Utility → Infomobilità)

- Scrapes the Trenitalia infomobility page and renders each notice as a collapsible
  card (all collapsed by default), preserving the site's ordering.
- The site's left‑bar severity color is reflected with a colored icon (danger/red,
  message/orange, clock/green) and its tags are reproduced as badges
  ("In evidenza" highlighted in yellow).
- Notice bodies preserve bold text and paragraph spacing. Links are classified:
  real train links open the in‑app train page, a generic "search train" link opens
  the Search tab, and document/page links open in the browser.
- Refreshes on every open; can deep‑link to and expand the notice relevant to a
  specific train.

### Strikes (Utility → Scioperi)

- Parses the Ministry of Transport RSS feed and filters to railway‑relevant strikes:
  the exact "Ferroviario" sector, all "Generale" strikes, and "Plurisettoriale"
  strikes that mention rail in any field.
- Each entry shows the date range, sector, relevance (with region/province for local
  strikes, relevance only for national ones), the union/modality fields (which the
  feed sometimes swaps, so both are shown differentiated), and the affected category.
- Cached and refreshed at most once per day.

### Favorites

- Trains can be starred from the detail page and are persisted in `UserDefaults`.
- The list is grouped into collapsible sections by carrier and searchable by name,
  route, carrier or number; entries support swipe‑to‑delete.

### Settings

- Default carrier (applied immediately), app theme (System/Light/Dark), a
  notifications placeholder, and access to the report forms.

### Reporting

- A modal report form is available from each train page (prefilled with the train
  number and route, with a problem‑type picker) and from Settings (a segmented
  Train/Search form). Submission is not yet implemented (work in progress).

## Cross‑cutting behavior

- **Global keyboard dismissal** – a window‑level tap gesture and a downward‑swipe
  pan gesture dismiss the keyboard anywhere in the app, without per‑field wiring.
  A `modalKeyboardSafe()` modifier prevents sheets from being swipe‑dismissed while
  the keyboard is up.
- **Persistence** – favorites, recent trains, recent stations, the app theme and
  default carrier, the cached station catalog, and the cached strike feed are all
  persisted locally; the two catalogs are re‑checked at most weekly/daily and
  rewritten only when their content changes.
- **Image mapping** – each train is mapped to a carrier/category image asset
  (Frecciarossa, Frecciargento, Frecciabianca, Intercity, Trenitalia regional,
  Trenitalia TPER, Leonardo Express, Italo, Trenord), including Trenord trains that
  appear inside Trenitalia results.

## Project layout

```
Trainly/
  TrainlyApp.swift          App entry point
  MainTabView.swift         Tab bar and Utility navigation stack
  Models/                   Codable models, normalized journey, stores
  NetworkRequests/          One service per data source
  Views/                    SwiftUI screens and shared UI helpers
  Assets.xcassets/          App icon and carrier logos
```

## Disclaimer

Trainly is an unofficial client and is not affiliated with Trenitalia, Italo,
Trenord, RFI or the Ministry of Transport. Data is provided as‑is from third‑party
endpoints and may be inaccurate or unavailable. The ticket feature is for lookup
only; purchase tickets through official channels or authorized resellers.

## License

This repository is published for portfolio purposes: viewing is allowed, but
copying, reuse, redistribution and commercial use are not permitted. See
[LICENSE](LICENSE).
