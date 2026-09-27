# Data Flow

Raw bytes never leave `packages/serial`. The UI only deals in `TelemetryFrame`.

## Layers

```mermaid
flowchart LR
    subgraph HW [Hardware / sim]
        REAL[RealSerialPort]
        MOCK[MockSerialPort]
        BQ[MockBqSerialPort]
        DC[MockDcSerialPort]
    end
    subgraph ISO [Worker isolate]
        WSVC[SerialService]
        PARSE[Connector parser]
        REC[Recorder]
    end
    subgraph UI [Main isolate]
        MGR[SerialWorker]
        PROV[Providers]
        STORE[TelemetryStore]
        TILES[Tiles]
    end
    REAL -- Uint8List --> WSVC
    MOCK -- Uint8List --> WSVC
    BQ -- Uint8List --> WSVC
    DC -- Uint8List --> WSVC
    WSVC -- "Uint8List chunks" --> PARSE
    WSVC -- "Uint8List chunks" --> REC
    PARSE -- TelemetryFrame --> MGR
    REC -- "TCR3 file" --> DISK[(disk)]
    MGR -- "streams" --> PROV
    PROV -- "frames / status" --> STORE
    STORE -- "TelemetryState" --> TILES
    DISK -- "chunks + header" --> PROV
```

Files: [real.dart](../packages/serial/lib/hardware/real.dart) · [mock.dart](../packages/serial/lib/hardware/mock.dart) · [mock_bq.dart](../packages/serial/lib/hardware/mock_bq.dart) · [mock_dc.dart](../packages/serial/lib/hardware/mock_dc.dart) · [serial.dart](../packages/serial/lib/serial.dart) (`SerialService`) · [worker.dart](../packages/serial/lib/worker/worker.dart) (`workerMain`) · [manager.dart](../packages/serial/lib/worker/manager.dart) (`SerialWorker`) · [protocol.dart](../packages/serial/lib/worker/protocol.dart) · [telemetry_store.dart](../lib/state/telemetry_store.dart)

## Live: bytestream → tile

```mermaid
flowchart TD
    A["Serial port\nCOMx / MOCK / MOCK-BQ / MOCK-DC"] -- "Uint8List" --> B[SerialService.byteStream]
    B -- "Uint8List" --> C{workerMain\nper chunk}
    C -->|1| D["Recorder.recordBytes\nUint8List + 12 B stamp"]
    C -->|2| E["connector.createParser().feed()\nUint8List → TelemetryFrame[]"]
    E -->|drop| F["counters\n→ LinkStats"]
    E -->|keep| G["PacketReceivedEvent\nTelemetryFrame"]
    G --> H["SerialWorker.frameStream\nStream TelemetryFrame"]
    H --> I["telemetryStreamProvider"]
    I -- "TelemetryFrame" --> J["TelemetryStore.ingest\nskip if replaying"]
    J --> K["history ring 9000\n+ dead reckoning"]
    K -- TelemetryState --> L[tiles]
    E -.->|"LinkStatsEvent\nmax 1 per 250 ms\n+ 500 ms heartbeat"| M[LinkStats consumers]
```

- 250ms throttle: stats go out at most 4 Hz per chunk burst; the 500ms heartbeat re-emits only when counters changed since the last snapshot — silence stays silent, and the UI derives link loss from snapshot age (rate label decays to "N s ago", graphs gap) instead of charting 0.0 heartbeats and spiking on resume.
- `LinkStatsEvent` is link health only: cumulative byte counters (`totalBytes`, `matchedBytes`, `garbageBytes`, `crcErrorBytes`, `matchedPackets`, `crcErrors`). All rocket data travels in `PacketReceivedEvent` → `TelemetryFrame`.
- Rocket data itself is never throttled or dropped: the worker forwards every decoded frame immediately, live `ingest()` stores + notifies per frame, replay batches each 50 ms tick into one rebuild with zero drops. (`TelemetryStore.notifyThrottled`, 80 ms, is currently uncalled.)
- Files: [worker.dart](../packages/serial/lib/worker/worker.dart) · [recorder.dart](../packages/serial/lib/io/recorder.dart) · [connector.dart](../packages/serial/lib/connectors/connector.dart) · [telemetry_provider.dart](../lib/state/telemetry_provider.dart) · [channel_health_provider.dart](../lib/state/channel_health_provider.dart)

## Recording: live → file

```mermaid
flowchart TD
    A[RecordingControls\nRecord] --> B[RecordingService.startRecording]
    B --> C{site selected?}
    C -- no --> Z[no-op]
    C -- yes --> D["StartRecordingCommand\nfilePath + LaunchRef + connectorId"]
    D --> E["Recorder.start\nprovisional v3 RecordingHeader"]
    E --> F["recordBytes: RecordingChunk\ntsUs + Uint8List\nrecordCommand: SentCommand"]
    G[RecordingControls\nStop] --> H[StopRecordingCommand]
    H --> I["finalizeRecordingFile\nre-parse body via connector\nstats + site + commands"]
    I --> J[("telemetry_*.bin\nTCR3")]
```

Files: [recording_provider.dart](../lib/state/recording_provider.dart) · [recorder.dart](../packages/serial/lib/io/recorder.dart) · [recording_file.dart](../packages/serial/lib/io/recording_file.dart) · [sent_command.dart](../packages/serial/lib/telemetry/sent_command.dart)

## Playback: file → tile

```mermaid
flowchart TD
    A["Recordings screen\n▶ card"] --> B["replayProvider.play path"]
    B --> C["RecordingRepository.loadReplay\nRecordingHeader → connector\nRecordingChunk[] → TelemetryFrame[]"]
    C -->|unknown connector / no site| Z[errorMsg]
    C --> D["auto-select recording connector\nin-memory, restored on stop"]
    D --> E[TelemetryStore.setReplaying true]
    E --> F["50 ms ticker × speed\nseek = binary search +\nforward-delta ingestFrames"]
    F -- "TelemetryFrame[]" --> G["store in replay mode\nno dead reckoning"]
    G --> H["PlaybackBar\nslider + markers"]
```

Files: [recording_repository.dart](../lib/services/recording_repository.dart) · [replay_controller.dart](../lib/state/replay_controller.dart) · [file_parser.dart](../packages/serial/lib/io/file_parser.dart) · [flight_trim.dart](../lib/services/flight_trim.dart) (trim/preview)

## Uplink: tile → rocket

```mermaid
flowchart LR
    A["Control panel / FSM chips\nConnectorCommand.bytes"] -- "sendBytes List[int]" --> B["SendBytesCommand\nbytes + source"]
    B --> C[worker sendBytes]
    C --> D["CommandResultEvent\nbytes + ok"]
    D --> E["commandLogProvider\nSentCommand[]"]
    C --> F["recorder.recordCommand\nSentCommand → file"]
    E --> G[CommandsTile]
```

Files: [rocket_commands.dart](../packages/serial/lib/telemetry/rocket_commands.dart) · [control_panel_tile.dart](../lib/ui/tiles/control_panel_tile.dart) · [commands_tile.dart](../lib/ui/tiles/commands_tile.dart)

## Formats

```mermaid
flowchart LR
    subgraph WIRE [Bytestream — connector-owned, e.g. MOCK]
        W["AA55 + 52 B payload\nincl. CRC16-CCITT\nstates 0-7/255 · uplink 54 43 cmd arg"]
    end
    subgraph INTERNAL [TelemetryFrame — shared, SI units]
        T["receivedAtMs · flags · seq\nlat/lon · gpsAlt · baroAlt\nvelNED · accelXYZ · gyroXYZ\nheading/roll/pitch/yaw\nbattery · hall · fsmStateId"]
    end
    subgraph FILE [TCR3 file — 168 B header + body]
        H["magic · stats · launch site\nconnectorId · section directory"]
        CH["chunk stream\n12 B tsUs+len + raw bytes"]
        CL["command log\n16 B records"]
    end
    W -- "connector parser" --> T
    W -- "recordBytes verbatim" --> CH
    T -- "PacketReceivedEvent" --> UIAPP[UI]
    H -.->|"selects connector"| T
```

Files: [frame_codec.dart](../packages/serial/lib/telemetry/frame_codec.dart) · [telemetry_frame.dart](../packages/serial/lib/telemetry/telemetry_frame.dart) · [recording_file.dart](../packages/serial/lib/io/recording_file.dart) · [mock_connector.dart](../packages/serial/lib/connectors/mock_connector.dart) · [registry.dart](../packages/serial/lib/connectors/registry.dart)
