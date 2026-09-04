# Local simulator photo fixtures

`prepare_unsplash_simulator_library.py` builds 300 geotagged JPEG fixtures for local tvOS performance testing:

- 10 globally distributed destinations.
- 3 unique Unsplash photos per destination.
- 10 local derivatives per photo.
- Synthetic city-level GPS jitter when the downloaded image has no embedded GPS.
- Deterministic travel dates and coordinates.
- A JSON manifest containing photographer and source-page attribution.

The tool uses 10 Unsplash search requests and 30 tracked download requests, fitting the default 50-request/hour demo allowance. Generated data and credentials are ignored by Git.

## Configure

Create an application at <https://unsplash.com/developers>, then copy `.env.unsplash.example` to `.env.unsplash.local` and enter the Access Key. The Secret Key is not needed.

## Generate and import

With an Apple TV Simulator booted:

```bash
python3 Scripts/prepare_unsplash_simulator_library.py --import-simulator
```

The resumable output is written to `.local-test-data/unsplash-global-300/`. Rerunning reuses the cached API selection and downloaded source files.

Use `--refresh-selection` only when a fresh search is intentional because it consumes another 10 API requests.

