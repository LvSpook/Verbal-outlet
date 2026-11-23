/// The AI side panel beside a note.
///
/// Kept as a panel rather than a separate screen so the notes stay visible while
/// the answer streams in — the point is to think about what you just wrote, not
/// to leave it.
///
/// The panel owns no provider; it drives the one [AiController] from [AiScope],
/// which means the conversation survives switching days.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../ai/ai_controller.dart';
import '../../ai/ai_provider.dart';
import '../../ai/ai_scope.dart';
import '../../ai/prompts.dart';
import '../../models/day_note.dart';
import 'chart_view.dart';
import 'diagram_view.dart';

class AiPanel extends StatefulWidget {
  const AiPanel({
    super.key,
    required this.note,
    this.onClose,
    this.onOpenSettings,
  });

  /// The note the AI is asked about. Empty notes still work — the model is told
  /// there is nothing yet.
  final DayNote note;

  final VoidCallback? onClose;

  /// Opens AI settings from inside the panel, when the engine is not ready.
  final VoidCallback? onOpenSettings;

  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  final _questionController = TextEditingController();
  final _scrollController = ScrollController();

  final List<AiTurn> _turns = [];

  bool _running = false;
  String? _error;
  String? _errorHint;

  /// The controller is looked up once: the panel is rebuilt often, and
  /// `dependOnInheritedWidgetOfExactType` in build would re-subscribe.
  AiController? _ai;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ai ??= AiScope.maybeOf(context);
  }

  @override
  void dispose() {
    _questionController.dispose();
    _scrollController.dispose();
    _ai?.cancel();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _run(AiTask task, {String? question}) async {
    final ai = _ai;
    if (ai == null || _running) return;

    final prompt = question?.trim() ?? '';
    if (task == AiTask.ask && prompt.isEmpty) return;

    setState(() {
      _running = true;
      _error = null;
      _errorHint = null;
      _turns.add(AiTurn.user(prompt.isEmpty ? task.label : prompt));
      _turns.add(AiTurn.assistant('', pending: true));
    });
    _scrollToEnd();

    try {
      await for (final turn in ai.run(
        task: task,
        notes: [widget.note],
        question: task == AiTask.ask ? prompt : null,
      )) {
        if (!mounted) return;
        setState(() => _turns[_turns.length - 1] = turn);
        _scrollToEnd();
      }
    } on AiException catch (error) {
      if (!mounted) return;
      setState(() {
        _turns.removeLast();
        _error = error.message;
        _errorHint = error.hint;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _turns.removeLast();
        _error = 'Something went wrong talking to the model.';
        _errorHint = '$error';
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _stop() {
    _ai?.cancel();
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ai = _ai;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.72),
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(theme, ai),
          _taskChips(theme),
          Divider(color: scheme.outlineVariant, height: 1),
          Expanded(
            child: _turns.isEmpty && _error == null
                ? _emptyState(theme)
                : ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    children: [
                      for (final turn in _turns) _turnCard(theme, turn),
                      if (_error != null) _errorCard(theme),
                    ],
                  ),
          ),
          _composer(theme),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, AiController? ai) {
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Assistant',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (ai != null)
                  Text(
                    '${ai.engineLabel} · ${ai.modelLabel}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (_running)
            IconButton(
              tooltip: 'Stop',
              onPressed: _stop,
              icon: const Icon(Icons.stop_circle_outlined, size: 20),
            ),
          if (widget.onClose != null)
            IconButton(
              tooltip: 'Close assistant',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, size: 20),
            ),
        ],
      ),
    );
  }

  Widget _taskChips(ThemeData theme) {
    final tasks = AiTask.values.where((task) => task != AiTask.ask).toList();

    // Wraps rather than scrolls so every task is visible in a narrow panel —
    // a horizontal list would hide half of them behind an awkward drag.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final task in tasks)
            ActionChip(
              label: Text(task.label),
              onPressed: _running ? null : () => _run(task),
            ),
        ],
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 36,
              color: scheme.primary.withValues(alpha: 0.8),
            ),
            const SizedBox(height: 12),
            Text(
              'Think it back over',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Reflect on the day, pull out to-dos, or ask for a diagram of how '
              'things connect.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            if (widget.onOpenSettings != null) ...[
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('AI settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _turnCard(ThemeData theme, AiTurn turn) {
    final scheme = theme.colorScheme;

    if (turn.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 24),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.6),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(
            turn.text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
      );
    }

    final visibleText = _stripBlocks(turn.text);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (visibleText.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(14),
                ),
              ),
              child: Text(
                visibleText,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
            ),
          if (turn.pending)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Thinking…',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          for (final block in turn.blocks)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _blockCard(theme, block),
            ),
        ],
      ),
    );
  }

  Widget _blockCard(ThemeData theme, RenderedBlock block) {
    final scheme = theme.colorScheme;

    if (block.error != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Text(
          block.error!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: switch (block.kind) {
        RenderedBlockKind.chart when block.chart != null => ChartView(
          data: block.chart!,
        ),
        RenderedBlockKind.chart => Text(
          'That chart could not be read.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        RenderedBlockKind.diagram => DiagramView(source: block.source),
      },
    );
  }

  Widget _errorCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: scheme.error.withValues(alpha: 0.1),
        border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 17, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (_errorHint != null) ...[
            const SizedBox(height: 6),
            Text(
              _errorHint!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
          if (widget.onOpenSettings != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: widget.onOpenSettings,
              icon: const Icon(Icons.tune, size: 15),
              label: const Text('Open AI settings'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _composer(ThemeData theme) {
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _questionController,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (value) {
                if (value.trim().isEmpty) return;
                _run(AiTask.ask, question: value);
                _questionController.clear();
              },
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Ask about this day…',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                suffixIcon: IconButton(
                  tooltip: 'Send',
                  onPressed: _running
                      ? null
                      : () {
                          _run(AiTask.ask, question: _questionController.text);
                          _questionController.clear();
                        },
                  icon: Icon(
                    Icons.arrow_upward,
                    size: 18,
                    color: _running ? scheme.onSurfaceVariant : scheme.primary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Removes fenced blocks from the display text, since they are drawn separately.
///
/// Mid-stream, an unclosed fence is left in place so text does not flicker; the
/// finished reply always has closed fences.
String _stripBlocks(String text) {
  // Only diagram and chart fences are removed. A fence holding anything else
  // is left in the text, so an ordinary answer that happens to include code
  // still reads correctly.
  final closed = RegExp(r'```[^\n]*\n([\s\S]*?)```');
  final cleaned = text.replaceAllMapped(closed, (match) {
    final body = match.group(1)!.trim();
    final lower = body.toLowerCase();
    if (lower.contains('digraph') || lower.contains('graph ')) return '';
    if (body.startsWith('{')) return '';
    return match.group(0)!;
  });
  // Collapse the blank lines the removal leaves behind.
  return cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
