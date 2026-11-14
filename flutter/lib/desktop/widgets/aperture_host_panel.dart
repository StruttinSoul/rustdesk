import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/aperture_brand.dart';

const apertureHostWindowSize = Size(460, 560);
const apertureExpandedWindowSize = Size(900, 650);

/// The Windows host surface. Live connection controls remain owned by the host.
class ApertureHostPanel extends StatelessWidget {
  const ApertureHostPanel({
    super.key,
    required this.status,
    required this.identity,
    required this.password,
    this.notice,
    required this.translate,
    required this.onSettings,
    required this.onConnect,
    required this.onHide,
  });

  final Widget status;
  final Widget identity;
  final Widget password;
  final Widget? notice;
  final String Function(String) translate;
  final VoidCallback? onSettings;
  final VoidCallback? onConnect;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final foreground = dark ? const Color(0xFFF0F5FC) : const Color(0xFF192431);
    final accent = dark ? const Color(0xFFA4BCFF) : const Color(0xFF2855CC);
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: dark ? const Color(0xFF101923) : const Color(0xFFF5F7FA),
      child: LayoutBuilder(builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const ApertureBrandMark(size: 44),
                    const SizedBox(width: 14),
                    Expanded(
                        child: Text(ApertureBrand.name,
                            style: TextStyle(
                                color: foreground,
                                fontSize: 26,
                                fontWeight: FontWeight.w600))),
                    if (onSettings != null)
                      IconButton(
                        tooltip: translate('Settings'),
                        onPressed: onSettings,
                        icon: Icon(Icons.settings_outlined, color: foreground),
                      ),
                  ]),
                  const SizedBox(height: 24),
                  Text(translate('Your Desktop'),
                      style: TextStyle(
                          color: foreground,
                          fontSize: 18,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  status,
                  const SizedBox(height: 20),
                  Divider(
                      color: dark
                          ? const Color(0xFF36475B)
                          : const Color(0xFFDCE3EA)),
                  const SizedBox(height: 16),
                  identity,
                  const SizedBox(height: 14),
                  password,
                  if (notice != null) ...[
                    const SizedBox(height: 12),
                    notice!,
                  ],
                  const SizedBox(height: 24),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (onConnect != null)
                        TextButton.icon(
                          onPressed: onConnect,
                          icon: const Icon(Icons.computer_outlined, size: 19),
                          label: Text(translate('Connect')),
                          style: TextButton.styleFrom(
                              foregroundColor: accent,
                              minimumSize: const Size(44, 44)),
                        ),
                      FilledButton.icon(
                        onPressed: onHide,
                        icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                        label: Text(translate('Minimize')),
                        style: FilledButton.styleFrom(
                            backgroundColor:
                                dark ? const Color(0xFF2855CC) : accent,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(44, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8))),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}
