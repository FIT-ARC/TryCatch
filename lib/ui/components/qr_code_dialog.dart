import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/format.dart';
import '../../theme/app_colors.dart';

/// Icon button (same quiet look as [CopyButton] icon-only) that opens the
/// coordinates as a scannable QR code dialog — handy for handing the
/// recovery position to a phone.
class QrCodeButton extends StatelessWidget {
  final double latitude;

  final double longitude;

  /// Dialog title, e.g. the tile name.
  final String title;

  const QrCodeButton({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final plain = formatLatLonPlain(latitude, longitude);
    return Tooltip(
      message: 'Show QR code for "$plain"',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          onTap: () => showCoordinatesQr(
            context: context,
            title: title,
            latitude: latitude,
            longitude: longitude,
          ),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Icon(
              Icons.qr_code_2,
              size: 13,
              color: AppColors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the position as a QR code scanning to a `geo:` URI (opens straight
/// into the phone's maps app), with the plain coordinates printed below.
Future<void> showCoordinatesQr({
  required BuildContext context,
  required String title,
  required double latitude,
  required double longitude,
}) {
  final plain = formatLatLonPlain(latitude, longitude);
  final uri =
      'geo:${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';
  return showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('$title · QR code', style: const TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Forced white so the code scans in both app themes. The fixed
          // SizedBox matters: AlertDialog measures its content with
          // intrinsic dimensions, which QrImageView (a LayoutBuilder)
          // refuses — the box answers intrinsics without consulting it.
          // White margin is just the scan-required quiet zone.
          Container(
            color: AppColors.fixedWhite,
            padding: const EdgeInsets.all(4),
            child: SizedBox(
              width: 200,
              height: 200,
              child: QrImageView(
                data: uri,
                version: QrVersions.auto,
                size: 200,
                padding: const EdgeInsets.all(4),
                backgroundColor: AppColors.fixedWhite,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            plain,
            style: AppText.mono.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Scan to open in a maps app',
            style: TextStyle(fontSize: 11, color: AppColors.mutedForeground),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
