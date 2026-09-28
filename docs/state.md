# State

Riverpod, no codegen. `main.dart` overrides `serialWorkerProvider` with the spawned isolate handle.

## Live telemetry state: worker → store → tiles

```mermaid
flowchart TD
    SW[SerialWorker]
    SW -- "Stream TelemetryFrame" --> TS[telemetryStreamProvider]
    SW -- SerialWorkerStatus --> SS[serialStatusProvider]
    SW -- LinkStats --> LS[linkStatsStreamProvider]
    SW -- "String list" --> AP[availablePortsProvider]
    SW -- CommandResultEvent --> CE[commandEventsProvider]

    TS -- TelemetryFrame --> STORE[telemetryStoreProvider]
    SS --> STORE
    CE --> CL[commandLogProvider\nSentCommand list]

    STORE -- TelemetryState --> TILES[tiles]
    LS --> HEALTH[channel tile\nlink button\npacket rate]
    CL --> CMDT[CommandsTile]
    AP --> SER[SerialControls\nport dropdown]
    SS --> SER
```

Files: [manager.dart](../packages/serial/lib/worker/manager.dart) · [telemetry_provider.dart](../lib/state/telemetry_provider.dart) · [telemetry_store.dart](../lib/state/telemetry_store.dart) · [channel_health_provider.dart](../lib/state/channel_health_provider.dart) · [main.dart](../lib/main.dart)

## Session control: connect · record · replay

```mermaid
flowchart TD
    SC[serialConfigProvider] -- "ConnectCommand\nport + connectorId" --> SW[SerialWorker]
    SC -- DisconnectCommand --> SW
    SC -- "SendBytesCommand" --> SW
    SC -- "SetConnectorCommand" --> SW
    SC -- "persist + notify worker" --> CID[activeConnectorIdProvider\nString, persisted]
    CID --> CONN[activeConnectorProvider\nTelemetryConnector]
    CONN --> TILES[tiles\nstates/commands/events]

    RC[RecordingService] -- "Start/StopRecordingCommand" --> SW
    SITE[currentLaunchSiteProvider] --> RC

    RP[replayProvider] -- "ingestFrames / reset" --> STORE[telemetryStoreProvider]
    RP -- "override in-memory" --> CID
    SITE --> ELS[effectiveLaunchSiteProvider]
    RP --> ELS
    ELS --> MAP[map / 3D tiles]
```

Files: [telemetry_provider.dart](../lib/state/telemetry_provider.dart) · [connector_provider.dart](../lib/state/connector_provider.dart) · [recording_provider.dart](../lib/state/recording_provider.dart) · [replay_controller.dart](../lib/state/replay_controller.dart) · [launch_site_store.dart](../lib/state/launch_site_store.dart)

## App chrome: layout · theme

```mermaid
flowchart LR
    WS[workspaceProvider\ntabs + grid layout] --> DASH[dashboard]
    TM[themeModeProvider] --> ALL[all screens]
    RD[recordingsDirectoryProvider] --> REC[recordings screen]
```

Files: [workspace_controller.dart](../lib/state/workspace_controller.dart) · [theme_mode_provider.dart](../lib/state/theme_mode_provider.dart)

## TelemetryState vs ReplayState

```mermaid
classDiagram
    class TelemetryState {
        +TelemetryFrame? latest
        +RingBuffer~TelemetryFrame~ history
        +DeadReckoningPosition? deadReckoning
        +RingBuffer~DeadReckoningPosition~ deadReckoningHistory
        +int packetCount
        +String sourceName
        +bool replaying
    }
    class ReplayState {
        +String? filePath
        +bool playing
        +double speed
        +int positionMs
        +int? durationMs
        +List~TelemetryFrame~ frames
        +LaunchSite? launchSite
        +List~SentCommand~ commands
        +String connectorId
        +bool smoothingEnabled
        +bool loopEnabled
    }
    ReplayController --> ReplayState : owns + ticks
    TelemetryStore --> TelemetryState : owns + ingests
    ReplayController --> TelemetryStore : ingestFrames / reset
```

Files: [telemetry_store.dart](../lib/state/telemetry_store.dart) · [replay_controller.dart](../lib/state/replay_controller.dart)

## Live vs replay mode

```mermaid
stateDiagram-v2
    [*] --> Live
    Live --> Replay : play path\nstore.setReplaying true\nconnector overridden
    Replay --> Live : stop\nstore.setReplaying false\nconnector restored
    state Live {
        [*] --> ingest : frame arrives
        ingest --> deadReckon : GPS stale ≥ 1 s
    }
    state Replay {
        [*] --> tick : 50 ms × speed
        tick --> seek : binary search +\nforward-delta ingest
        seek --> tick
    }
```

- Live stream is ignored while `replaying`.
- Dead reckoning is live-only; replay shows the recorded GPS track as-is.
- `seek()` forward ingests the delta, backward resets + replays from 0.

## Persistence

```mermaid
flowchart LR
    subgraph PREFS [SharedPreferences]
        W[trycatch.workspaces]
        L[trycatch.launch_sites]
        D[trycatch.dark_mode]
        C[trycatch.connector_id]
    end
    W --> WS[workspaceProvider]
    L --> LS2[launchSiteProvider]
    D --> TM[themeModeProvider\n+ AppThemeMode singleton]
    C --> CID2[activeConnectorIdProvider]
```

- No version suffixes on keys; corrupt values fall back to defaults, never crash.
- Everything else (telemetry, replay cursor, command log) is in-memory only.

Files: [prefs_keys.dart](../lib/services/prefs_keys.dart)
