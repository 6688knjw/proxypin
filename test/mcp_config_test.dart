import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';

void main() {
  test('mcp fields persist through toJson/fromJson', () {
    final loaded = Configuration.fromJson({
      'mcpEnabled': true,
      'mcpPort': 9101,
      'mcpAuthToken': 'token-abc',
      'mcpBodyLimit': 1024,
    });
    expect(loaded.mcpEnabled, isTrue);
    expect(loaded.mcpPort, 9101);
    expect(loaded.mcpAuthToken, 'token-abc');
    expect(loaded.mcpBodyLimit, 1024);

    final roundTrip = Configuration.fromJson(loaded.toJson());
    expect(roundTrip.mcpEnabled, isTrue);
    expect(roundTrip.mcpPort, 9101);
    expect(roundTrip.mcpAuthToken, 'token-abc');
    expect(roundTrip.mcpBodyLimit, 1024);
  });

  test('mcp fields have defaults', () {
    final loaded = Configuration.fromJson({});
    expect(loaded.mcpEnabled, isFalse);
    expect(loaded.mcpPort, 9100);
    expect(loaded.mcpAuthToken, '');
    expect(loaded.mcpBodyLimit, 65536);
  });
}
