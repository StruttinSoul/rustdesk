import 'package:flutter/material.dart';

abstract final class ApertureBrand {
  static const name = 'Aperture';
  static const iconAsset = 'assets/aperture_icon.png';
}

class ApertureBrandMark extends StatelessWidget {
  const ApertureBrandMark({super.key, this.size = 48});

  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size / 4),
        child: Image.asset(
          ApertureBrand.iconAsset,
          width: size,
          height: size,
          cacheWidth: 192,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
        ),
      );
}