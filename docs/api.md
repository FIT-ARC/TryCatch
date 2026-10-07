# Live Output API

Read-only HTTP feed of the last known live packet, for a public display.
Enable it in Settings → LIVE OUTPUT (off by default). The app binds
localhost (`127.0.0.1:6767` by default); put a reverse proxy in front for
public traffic, with buffering off for the event stream.

## Endpoints

| Method | Path      | Response                                      |
|--------|-----------|-----------------------------------------------|
| GET    | `/health` | `{"status": "ok"}`                            |
| GET    | `/latest` | Newest packet as JSON, or `204` when no packet has arrived yet |
| GET    | `/events` | Server-sent events stream of packets (`text/event-stream`) |

Non-GET requests are rejected (`405`). There is no way to send anything
into the app through this API.

## Packet

```json
{
  "receivedAt": 1700000000000,
  "gpsLat": 50.0755,
  "gpsLong": 14.4378,
  "altitudeMSL": 1215.3,
  "altitudeAGL": 812.3,
  "hasParachute": false,
  "maxAltitude": 1303.0,
  "totalVelocity": 45.6
}
```

| Field          | Unit                              |
|----------------|-----------------------------------|
| `receivedAt`   | Unix time, milliseconds           |
| `gpsLat`       | Degrees north                     |
| `gpsLong`      | Degrees east                      |
| `altitudeMSL`  | Metres above mean sea level       |
| `altitudeAGL`  | Metres above the launch pad, matching the app's altitude charts |
| `hasParachute` | `true` once the canopy is out     |
| `maxAltitude`  | Session peak, metres MSL          |
| `totalVelocity`| Metres per second                 |

## Staleness

The feed publishes live packets only — replays and old flights never
appear. When the link drops, nothing new arrives: treat data older than a
few seconds (compare `receivedAt` against now) as stale. `/latest` keeps
returning the last packet with its original timestamp.

## Examples

Poll the latest packet:

```sh
curl http://127.0.0.1:6767/latest
```

Follow the live stream in a browser page:

```js
const source = new EventSource('https://your-proxy/events');
source.onmessage = (event) => {
  const packet = JSON.parse(event.data);
  const ageS = (Date.now() - packet.receivedAt) / 1000;
  if (ageS > 3) showStale();
  else show(packet);
};
```

Follow it from Python:

```python
import json, urllib.request

with urllib.request.urlopen('http://127.0.0.1:6767/events') as stream:
    buffer = ''
    while chunk := stream.read(1024).decode():
        buffer += chunk
        while '\n\n' in buffer:
            message, buffer = buffer.split('\n\n', 1)
            for line in message.splitlines():
                if line.startswith('data: '):
                    print(json.loads(line[6:]))
```
