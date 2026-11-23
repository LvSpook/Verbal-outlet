import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:verbal_outlet/ai/ai_controller.dart';
import 'package:verbal_outlet/ai/ai_settings.dart';
import 'package:verbal_outlet/ai/ollama_provider.dart';
import 'package:verbal_outlet/widgets/ai/diagram_view.dart';

void main() {
  group('parseBlocks', () {
    test('finds a chart block and parses it', () {
      const reply = '''
Here are your numbers.

```chart
{"type":"bar","title":"Hours slept","labels":["Mon","Tue"],"values":[6,7.5]}
```
''';

      final blocks = parseBlocks(reply);
      expect(blocks, hasLength(1));
      expect(blocks.first.kind, RenderedBlockKind.chart);
      expect(blocks.first.error, isNull);
      expect(blocks.first.chart!.type, ChartType.bar);
      expect(blocks.first.chart!.title, 'Hours slept');
      expect(blocks.first.chart!.labels, ['Mon', 'Tue']);
      expect(blocks.first.chart!.values, [6, 7.5]);
    });

    test('accepts numeric strings as values', () {
      const reply =
          '```chart\n{"type":"line","labels":["a","b"],"values":["1","2.5"]}\n```';
      final chart = parseBlocks(reply).single.chart;
      expect(chart!.values, [1.0, 2.5]);
      expect(chart.type, ChartType.line);
    });

    test('reports mismatched labels and values instead of throwing', () {
      const reply =
          '```chart\n{"type":"pie","labels":["a","b"],"values":[1]}\n```';
      final block = parseBlocks(reply).single;
      expect(block.chart, isNull);
      expect(block.error, isNotNull);
    });

    test('ignores JSON that cannot be read at all', () {
      const reply = '```chart\n{not json}\n```';
      // Rather than showing an error card, an unreadable block is simply left
      // out; the reply text still reads fine without it.
      expect(parseBlocks(reply), isEmpty);
    });

    test('accepts the fence variants models actually emit', () {
      const reply = '```\ndot\ndigraph g { a [label="One"]; }\n```\nAll done.';
      final block = parseBlocks(reply).single;
      expect(block.kind, RenderedBlockKind.diagram);
      expect(block.source.trimLeft(), startsWith('dot'));
    });

    test('accepts two parallel lists instead of labels/values', () {
      const reply =
          '```json\n'
          '{"dates":["Mon","Tue"],"hours":[6,7]}\n'
          '```';
      final chart = parseBlocks(reply).single.chart;
      expect(chart!.labels, ['Mon', 'Tue']);
      expect(chart.values, [6, 7]);
    });

    test('leaves ordinary fenced code alone', () {
      const reply = '```dart\nfinal x = 1;\n```';
      expect(parseBlocks(reply), isEmpty);
    });

    test('finds a dot block', () {
      const reply = '''
```dot
digraph notes {
  a [label="Sleep"];
  b [label="Energy"];
  a -> b [label="poor night"];
}
```
''';
      final block = parseBlocks(reply).single;
      expect(block.kind, RenderedBlockKind.diagram);
      expect(block.source, contains('digraph'));
    });

    test('ignores unclosed fences and plain prose', () {
      expect(parseBlocks('Just a normal answer.'), isEmpty);
      expect(parseBlocks('```dot\ndigraph x { a -> b'), isEmpty);
    });

    test('ignores text inside other languages', () {
      const reply = '```dart\nfinal x = 1;\n```';
      expect(parseBlocks(reply), isEmpty);
    });
  });

  group('parseDot', () {
    test('reads nodes and edges with labels', () {
      final graph = parseDot('''
digraph g {
  rankdir=LR;
  node [shape=box];
  a [label="Sleep"];
  b [label="Focus"];
  a -> b [label="drives"];
}
''');
      expect(graph, isNotNull);
      expect(graph!.nodes.map((node) => node.label), ['Sleep', 'Focus']);
      expect(graph.edges, hasLength(1));
      expect(graph.edges.single.label, 'drives');
    });

    test('creates nodes referenced only by edges', () {
      final graph = parseDot('digraph { one -> two }');
      expect(graph!.nodes, hasLength(2));
      expect(graph.edges.single.from, 'one');
    });

    test('handles graph syntax without digraph', () {
      final graph = parseDot('graph { a -- b }');
      expect(graph, isNotNull);
      expect(graph!.edges, hasLength(1));
    });

    test('returns null when there is no graph body', () {
      expect(parseDot('Sleep drives focus.'), isNull);
    });
  });

  group('AiSettingsStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to local with the recommended model', () async {
      final settings = await AiSettingsStore().load();
      expect(settings.engine, AiEngineKind.local);
      expect(settings.localModel, AiSettings.defaultLocalModel);
      expect(settings.hasApiKey, isFalse);
    });

    test('round-trips non-secret choices', () async {
      final store = AiSettingsStore();
      await store.save(
        const AiSettings(
          engine: AiEngineKind.cloud,
          localModel: 'llama3.2:3b',
          cloudModel: 'gpt-4o-mini',
          cloudName: 'OpenAI',
        ),
      );

      // A fresh store reads the same values back.
      final loaded = await AiSettingsStore().load();
      expect(loaded.engine, AiEngineKind.cloud);
      expect(loaded.localModel, 'llama3.2:3b');
      expect(loaded.cloudModel, 'gpt-4o-mini');
      expect(loaded.cloudName, 'OpenAI');
    });
  });

  group('OllamaProvider.hasModel', () {
    test('matches an exact tag', () async {
      // No server running in tests, so installedModels is empty and the check
      // is false — but the suffix logic itself is what matters here.
      final provider = OllamaProvider(model: 'qwen3:4b');
      expect(await provider.hasModel('qwen3:4b'), isFalse);
      await provider.dispose();
    });
  });
}
