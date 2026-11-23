/// The Updates card in Settings.
///
/// The app checks once at launch, quietly. This card is where a person can also
/// ask by hand, see which version they are on, read what changed, and press one
/// button to install. It is the only place an update failure is explained,
/// because a launch check that fails has nobody to explain itself to.
library;

import 'package:material_ui/material_ui.dart';

import '../update/update_controller.dart';
import '../update/update_scope.dart';

class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = UpdateScope.maybeOf(context);
    // No controller (previews, tests not about updates) means no card, rather
    // than a card that can never do anything.
    if (controller == null) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _card(context, controller),
    );
  }

  Widget _card(BuildContext context, UpdateController controller) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = controller.state;

    final hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.45,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Updates',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (state.available != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'New',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            FutureBuilder<String>(
              future: controller.currentVersion(),
              builder: (context, snapshot) {
                final version = snapshot.data;
                return Text(
                  version == null
                      ? 'Updates come from this app\'s GitHub releases.'
                      : 'You are on version $version. '
                            'Updates come from the app\'s GitHub releases.',
                  style: hintStyle,
                );
              },
            ),
            const SizedBox(height: 14),
            ..._body(context, controller, state, hintStyle),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(
    BuildContext context,
    UpdateController controller,
    UpdateState state,
    TextStyle? hintStyle,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (state.downloading) {
      final fraction = state.progress;
      return [
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 8),
        Text(
          fraction == null
              ? 'Downloading the new version…'
              : 'Downloading the new version… ${(fraction * 100).round()}%',
          style: hintStyle,
        ),
        const SizedBox(height: 4),
        Text(
          'The app will close and reopen when it is ready.',
          style: hintStyle,
        ),
      ];
    }

    if (state.available != null) {
      final release = state.available!;
      return [
        Text(
          'Version ${release.version} is ready to install.',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (release.notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              release.notes,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            FilledButton.icon(
              onPressed: state.installing ? null : controller.install,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Update now'),
            ),
            const SizedBox(width: 8),
            Text(
              'Your notes are kept.',
              style: hintStyle,
            ),
          ],
        ),
        if (state.error != null) ...[
          const SizedBox(height: 10),
          Text(
            state.error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ];
    }

    if (state.error != null) {
      return [
        Text(
          state.error!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: state.checking ? null : () => controller.check(quiet: false),
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Check again'),
        ),
      ];
    }

    return [
      Row(
        children: [
          OutlinedButton.icon(
            onPressed: state.checking
                ? null
                : () => controller.check(quiet: false),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(state.checking ? 'Checking…' : 'Check for updates'),
          ),
          if (state.checked && !state.checking) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text('You are up to date.', style: hintStyle),
            ),
          ],
        ],
      ),
    ];
  }
}
