/// Value object for the read-only live telemetry bridge.
 ///
 /// The bridge serves the last known live packet over HTTP (`GET /latest`,
 /// `GET /events` as server-sent events) from a dedicated isolate. It is
 /// disabled by default and binds localhost: the public website sits behind
 /// a reverse proxy, so the app itself never faces the internet.
class BridgeConfig {
  /// Default port the bridge binds when enabled.
  static const int defaultPort = 6767;

  /// Default bind address (localhost; the proxy handles public traffic).
  static const String defaultBindAddress = '127.0.0.1';

  /// Default cross-origin value (`*` serves any public site).
  static const String defaultCorsOrigin = '*';

  /// Whether the bridge server runs.
  final bool enabled;

  /// TCP port to bind (1–65535).
  final int port;

  /// Address to bind (`127.0.0.1` for proxy setups, `0.0.0.0` for direct LAN).
  final String bindAddress;

  /// Value sent as `Access-Control-Allow-Origin`.
  final String corsOrigin;

  const BridgeConfig({
    this.enabled = false,
    this.port = defaultPort,
    this.bindAddress = defaultBindAddress,
    this.corsOrigin = defaultCorsOrigin,
  });

  /// Whether [port] is a bindable TCP port.
  static bool isValidPort(int port) => port >= 1 && port <= 65535;

  /// Whether [address] is non-empty (bindability itself surfaces at runtime
  /// as a bridge status error, so this stays a cheap guard).
  static bool isValidBindAddress(String address) =>
      address.trim().isNotEmpty;

  /// Tolerant parse: missing keys fall back to defaults, out-of-range ports
  /// clamp back to [defaultPort].
  factory BridgeConfig.fromJson(Map<String, dynamic> json) {
    final port = json['port'];
    return BridgeConfig(
      enabled: json['enabled'] == true,
      port: port is int && isValidPort(port) ? port : defaultPort,
      bindAddress: switch (json['bind']) {
        final String s when isValidBindAddress(s) => s.trim(),
        _ => defaultBindAddress,
      },
      corsOrigin: switch (json['cors']) {
        final String s when s.trim().isNotEmpty => s.trim(),
        _ => defaultCorsOrigin,
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'port': port,
        'bind': bindAddress,
        'cors': corsOrigin,
      };

  BridgeConfig copyWith({
    bool? enabled,
    int? port,
    String? bindAddress,
    String? corsOrigin,
  }) {
    return BridgeConfig(
      enabled: enabled ?? this.enabled,
      port: port ?? this.port,
      bindAddress: bindAddress ?? this.bindAddress,
      corsOrigin: corsOrigin ?? this.corsOrigin,
    );
  }
}
