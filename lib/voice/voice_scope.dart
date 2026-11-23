/// Makes the one [VoiceController] available to the whole app.
///
/// The floating microphone and the voice settings screen both read the same
/// controller, so downloading a model in settings immediately makes the
/// microphone usable without reopening the note.
library;

import 'package:material_ui/material_ui.dart';

import 'voice_controller.dart';

class VoiceScope extends InheritedNotifier<VoiceController> {
  const VoiceScope({
    super.key,
    required VoiceController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Null when the app was built without voice (previews, older tests), so the
  /// microphone can explain itself rather than crash.
  static VoiceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VoiceScope>()?.notifier;
}
