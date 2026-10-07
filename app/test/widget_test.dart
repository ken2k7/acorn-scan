import 'package:flutter_test/flutter_test.dart';

import 'package:app/main.dart';

void main() {
  testWidgets('shows the empty-state prompt on first launch', (tester) async {
    await tester.pumpWidget(const AcornApp());
    expect(find.text('Scan your first prescription label'), findsOneWidget);
  });
}
