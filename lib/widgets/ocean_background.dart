import 'package:material_ui/material_ui.dart';

/// A very subtle vertical gradient that makes the app feel like looking down
/// into water: lighter near the surface, sinking to black at the bottom.
///
/// It is intentionally almost imperceptible — enough depth to stop large dark
/// areas feeling flat, without drawing attention to itself.
class OceanBackground extends StatelessWidget {
  const OceanBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.surfaceContainerHigh.withValues(alpha: 0.55),
            scheme.surface,
            scheme.surfaceContainerLowest,
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: child,
    );
  }
}
