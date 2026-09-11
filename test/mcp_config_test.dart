import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';

void main() {
  test('mcp fields persist through toJson/fromJson', () {
    final loaded = Configuration.fromJson({
      'mcpEnabled': true,
      'mcpPort': 9101,
      'mcpAuthEnabled': false,
      'mcpAuthToken': 'token-abc',
      'mcpSseEnabled': false,
      'mcpBodyLimit': 1024,
    });
    expect(loaded.mcpEnabled, isTrue);
    expect(loaded.mcpPort, 9101);
    expect(loaded.mcpAuthEnabled, isFalse);
    expect(loaded.mcpAuthToken, 'token-abc');
    expect(loaded.mcpSseEnabled, isFalse);
    expect(loaded.mcpBodyLimit, 1024);

    final roundTrip = Configuration.fromJson(loaded.toJson());
    expect(roundTrip.mcpEnabled, isTrue);
    expect(roundTrip.mcpPort, 9101);
    expect(roundTrip.mcpAuthEnabled, isFalse);
    expect(roundTrip.mcpAuthToken, 'token-abc');
    expect(roundTrip.mcpSseEnabled, isFalse);
    expect(roundTrip.mcpBodyLimit, 1024);
  });

  test('mcp fields have defaults', () {
    final loaded = Configuration.fromJson({});
    expect(loaded.mcpEnabled, isFalse);
    expect(loaded.mcpPort, 9100);
    expect(loaded.mcpAuthEnabled, isTrue);
    expect(loaded.mcpAuthToken, '');
    expect(loaded.mcpSseEnabled, isTrue);
    expect(loaded.mcpBodyLimit, 65536);
  });
}
