import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/theme/stable_focus.dart';

void main() {
  testWidgets('row focus node stays when selection changes', (tester) async {
    final bag = KotvFocusBag();
    addTearDown(bag.dispose);
    final first = bag.of('ch:0');
    final second = bag.of('ch:1');
    expect(bag.of('ch:0'), same(first));
    expect(bag.of('ch:1'), same(second));
    expect(identical(first, second), isFalse);

    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return KotvStableFocus(
              autofocus: selected,
              onPressed: () => setState(() => selected = !selected),
              child: Text(selected ? 'on' : 'off'),
            );
          },
        ),
      ),
    );
    final before = tester.widget<Focus>(find.byType(Focus).first).focusNode;
    await tester.tap(find.text('off'));
    await tester.pump();
    final after = tester.widget<Focus>(find.byType(Focus).first).focusNode;
    expect(after, same(before));
    expect(find.text('on'), findsOneWidget);
  });
}
