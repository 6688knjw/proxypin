import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/mcp/mcp_server.dart';
import 'package:proxypin/ui/mobile/mobile.dart';
import 'package:proxypin/utils/ip.dart';

class MobileMcpWidget extends StatefulWidget {
  final ProxyServer proxyServer;

  const MobileMcpWidget({super.key, required this.proxyServer});

  @override
  State<MobileMcpWidget> createState() => _MobileMcpWidgetState();
}

class _MobileMcpWidgetState extends State<MobileMcpWidget> {
  late final TextEditingController portController;
  late final TextEditingController bodyLimitController;
  String? localAddress;
  String? startError;
  bool tokenVisible = false;
  bool toggling = false;
  bool jsonExpanded = false;
  Timer? ticker;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  McpServerController get controller => McpServerController.instance(
        configuration: widget.proxyServer.configuration,
        proxyServer: () => widget.proxyServer,
        session: MobileApp.container,
      );

  @override
  void initState() {
    super.initState();
    final configuration = widget.proxyServer.configuration;
    controller.ensureToken();
    portController = TextEditingController(text: '${configuration.mcpPort}');
    bodyLimitController = TextEditingController(text: '${configuration.mcpBodyLimit}');
    _refreshLanAddress();
    ticker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (controller.isRunning) {
        _refreshLanAddress();
      }
    });
  }

  @override
  void dispose() {
    ticker?.cancel();
    portController.dispose();
    bodyLimitController.dispose();
    super.dispose();
  }

  String _mcpUrl(String host) => 'http://$host:${widget.proxyServer.configuration.mcpPort}/mcp';

  String get localUrl => _mcpUrl('127.0.0.1');

  String get lanUrl {
    final host = localAddress;
    if (host == null || host.isEmpty) {
      return localUrl;
    }
    return _mcpUrl(host);
  }

  String get connectHint {
    final token = widget.proxyServer.configuration.mcpAuthToken;
    return 'URL (local): $localUrl\nURL (lan): $lanUrl\nAuthorization: Bearer $token';
  }

  String get clientJson {
    final token = widget.proxyServer.configuration.mcpAuthToken;
    return const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'proxypin': {
          'url': lanUrl,
          'headers': {'Authorization': 'Bearer $token'},
        }
      }
    });
  }

  String get maskedToken {
    final token = widget.proxyServer.configuration.mcpAuthToken;
    if (tokenVisible || token.length < 10) {
      return token;
    }
    return '${token.substring(0, 4)} ······ ${token.substring(token.length - 4)}';
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      FlutterToastr.show(localizations.copied, context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configuration = widget.proxyServer.configuration;
    final running = controller.isRunning;
    final theme = Theme.of(context);
    final dividerColor = theme.dividerColor.withValues(alpha: 0.22);
    final borderColor = theme.dividerColor.withValues(alpha: 0.13);
    Widget section(List<Widget> tiles) => Card(
          color: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(side: BorderSide(color: borderColor), borderRadius: BorderRadius.circular(10)),
          child: Column(children: tiles),
        );

    Widget divider() => Divider(height: 0, thickness: 0.3, color: dividerColor);

    return Scaffold(
        appBar: AppBar(title: Text(localizations.mcpServer, style: const TextStyle(fontSize: 16)), centerTitle: true),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          _statusCard(running, theme),
          if (startError != null) ...[
            const SizedBox(height: 8),
            Card(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
                elevation: 0,
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(startError!, style: TextStyle(color: theme.colorScheme.error, fontSize: 13)))),
          ],
          const SizedBox(height: 12),
          section([
            SwitchListTile(
                hoverColor: Colors.transparent,
                title: Text(localizations.mcpEnabled),
                subtitle: Text(localizations.mcpLanHint, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                value: running,
                onChanged: toggling ? null : _onToggle),
            divider(),
            SwitchListTile(
                hoverColor: Colors.transparent,
                title: Text(localizations.mcpAutoStart),
                subtitle: Text(localizations.mcpAutoStartHint, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                value: configuration.mcpEnabled,
                onChanged: (value) {
                  configuration.mcpEnabled = value;
                  configuration.flushConfig();
                  setState(() {});
                }),
          ]),
          const SizedBox(height: 12),
          section([
            _urlTile(localizations.mcpLocalAddress, localUrl),
            divider(),
            _urlTile(localizations.mcpLanAddress, lanUrl),
            divider(),
            ListTile(
                title: Text(localizations.mcpCopyConfig),
                subtitle: Text(localizations.mcpCopyConfigHint, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                trailing: const Icon(Icons.copy, size: 18),
                onTap: () => _copy(connectHint)),
            divider(),
            ListTile(
                title: Text(localizations.mcpCopyJson),
                subtitle: Text(localizations.mcpCopyJsonHint, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: localizations.mcpCopyJson,
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => _copy(clientJson)),
                  Icon(jsonExpanded ? Icons.expand_less : Icons.expand_more),
                ]),
                onTap: () => setState(() => jsonExpanded = !jsonExpanded)),
            if (jsonExpanded)
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(8)),
                      child: SelectableText(clientJson,
                          style: const TextStyle(fontSize: 11, fontFamily: 'monospace', height: 1.35)))),
          ]),
          const SizedBox(height: 12),
          section([
            ListTile(
                title: Text(localizations.mcpToken),
                subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(maskedToken, style: const TextStyle(fontSize: 13, fontFamily: 'monospace'))),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: tokenVisible ? localizations.mcpHideToken : localizations.mcpShowToken,
                      icon: Icon(tokenVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                      onPressed: () => setState(() => tokenVisible = !tokenVisible)),
                  IconButton(
                      tooltip: localizations.copy,
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => _copy(configuration.mcpAuthToken)),
                ])),
            divider(),
            ListTile(
                title: Text(localizations.mcpRegenerateToken),
                subtitle: Text(localizations.mcpTokenInvalidateHint,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                trailing: const Icon(Icons.refresh, size: 18),
                onTap: _regenerateToken),
          ]),
          const SizedBox(height: 12),
          section([
            ListTile(
                title: Text(localizations.mcpPort),
                subtitle: Text(localizations.mcpPortRestart, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                trailing: SizedBox(
                    width: 92,
                    child: TextField(
                        controller: portController,
                        textAlign: TextAlign.center,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                            isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.all(8)),
                        onSubmitted: (_) => _persistPortAndLimit(),
                        onEditingComplete: _persistPortAndLimit,
                        onTapOutside: (_) => _persistPortAndLimit()))),
            divider(),
            ListTile(
                title: Text(localizations.mcpBodyLimit),
                subtitle: Text(localizations.mcpBodyLimitHint, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                trailing: SizedBox(
                    width: 92,
                    child: TextField(
                        controller: bodyLimitController,
                        textAlign: TextAlign.center,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                            isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.all(8)),
                        onSubmitted: (_) => _persistPortAndLimit(),
                        onEditingComplete: _persistPortAndLimit,
                        onTapOutside: (_) => _persistPortAndLimit()))),
          ]),
          const SizedBox(height: 16),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(localizations.mcpAudit, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
          const SizedBox(height: 8),
          section(_auditTiles(theme, dividerColor)),
        ]));
  }

  Widget _statusCard(bool running, ThemeData theme) {
    final color = running ? Colors.green : theme.colorScheme.outline;
    final title = running ? localizations.mcpRunning : localizations.mcpStopped;
    final subtitle = running
        ? localizations.mcpClientsConnected(controller.sessionCount, lanUrl)
        : localizations.mcpHint;
    return Card(
      elevation: 0,
      color: running
          ? Colors.green.withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.08)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
          side: BorderSide(color: running ? Colors.green.withValues(alpha: 0.35) : theme.dividerColor.withValues(alpha: 0.13)),
          borderRadius: BorderRadius.circular(10)),
      child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(children: [
            Icon(running ? Icons.sensors : Icons.sensors_off, color: color, size: 28),
            const SizedBox(width: 12),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: color)),
              const SizedBox(height: 4),
              Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.35)),
            ])),
            if (running)
              Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                  child: Text('${controller.sessionCount}',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.green))),
          ])),
    );
  }

  List<Widget> _auditTiles(ThemeData theme, Color dividerColor) {
    final entries = controller.auditLog.entries.take(20).toList();
    if (entries.isEmpty) {
      return [
        ListTile(
            leading: Icon(Icons.history, color: Colors.grey.shade500, size: 20),
            title: Text(localizations.mcpAuditEmpty, style: TextStyle(color: Colors.grey.shade600)))
      ];
    }
    final tiles = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      tiles.add(ListTile(
          dense: true,
          leading: Icon(entry.ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 18, color: entry.ok ? Colors.green : theme.colorScheme.error),
          title: Text(entry.tool, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          subtitle: Text(entry.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(_formatTime(entry.time), style: TextStyle(fontSize: 11, color: Colors.grey.shade600))));
      if (i != entries.length - 1) {
        tiles.add(Divider(height: 0, thickness: 0.3, color: dividerColor));
      }
    }
    return tiles;
  }

  Widget _urlTile(String title, String url) {
    return ListTile(
        title: Text(title),
        subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(url, style: const TextStyle(fontSize: 13, fontFamily: 'monospace'))),
        trailing: IconButton(
            tooltip: localizations.mcpCopyUrl,
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => _copy(url)));
  }

  Future<void> _refreshLanAddress() async {
    try {
      final value = await localIp(readCache: false);
      if (!mounted) return;
      if (value != localAddress) {
        setState(() => localAddress = value);
      } else if (controller.isRunning) {
        setState(() {});
      }
    } catch (_) {
      if (mounted && controller.isRunning) setState(() {});
    }
  }

  Future<void> _onToggle(bool value) async {
    toggling = true;
    startError = null;
    setState(() {});
    try {
      if (value) {
        await _persistPortAndLimit();
        final ok = await controller.start();
        if (!ok) {
          startError = controller.lastError ?? localizations.mcpStartFailed;
        }
      } else {
        await controller.stop();
      }
    } finally {
      toggling = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _regenerateToken() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(localizations.mcpRegenerateToken),
        content: Text(localizations.mcpRegenerateConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(localizations.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(localizations.confirm)),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    controller.regenerateToken();
    await widget.proxyServer.configuration.flushConfig();
    if (mounted) setState(() {});
  }

  Future<void> _persistPortAndLimit() async {
    final configuration = widget.proxyServer.configuration;
    final parsedPort = int.tryParse(portController.text.trim());
    var shouldRestart = false;
    if (parsedPort != null && parsedPort > 0 && parsedPort < 65536) {
      shouldRestart = controller.isRunning && configuration.mcpPort != parsedPort;
      configuration.mcpPort = parsedPort;
    } else {
      portController.text = '${configuration.mcpPort}';
    }
    final limit = int.tryParse(bodyLimitController.text.trim());
    if (limit != null && limit >= 0) {
      configuration.mcpBodyLimit = limit;
    } else {
      bodyLimitController.text = '${configuration.mcpBodyLimit}';
    }
    await configuration.flushConfig();
    if (shouldRestart) {
      startError = null;
      final ok = await controller.restart();
      if (!ok) {
        startError = controller.lastError ?? localizations.mcpStartFailed;
      }
    }
    if (mounted) setState(() {});
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
