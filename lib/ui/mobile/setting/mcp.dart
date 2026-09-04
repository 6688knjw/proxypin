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
    localIp(readCache: false).then((value) {
      if (mounted) {
        setState(() => localAddress = value);
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    portController.dispose();
    bodyLimitController.dispose();
    super.dispose();
  }

  String get connectUrl {
    final host = localAddress ?? '127.0.0.1';
    return 'http://$host:${widget.proxyServer.configuration.mcpPort}/mcp';
  }

  String get connectHint {
    final token = widget.proxyServer.configuration.mcpAuthToken;
    return 'URL: $connectUrl\nAuthorization: Bearer $token\nheader Mcp-Session-Id after initialize';
  }

  @override
  Widget build(BuildContext context) {
    final configuration = widget.proxyServer.configuration;
    final running = controller.isRunning;
    final dividerColor = Theme.of(context).dividerColor.withValues(alpha: 0.22);

    Widget section(List<Widget> tiles) => Card(
          color: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
              side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.13)),
              borderRadius: BorderRadius.circular(10)),
          child: Column(children: tiles),
        );

    return Scaffold(
        appBar: AppBar(title: Text(localizations.mcpServer, style: const TextStyle(fontSize: 16)), centerTitle: true),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          section([
            ListTile(
                title: Text(localizations.mcpEnabled),
                subtitle: Text(running ? localizations.mcpRunning : localizations.mcpStopped),
                trailing: Transform.scale(
                    scale: 0.8,
                    child: Switch(
                        value: running,
                        onChanged: (value) async {
                          startError = null;
                          if (value) {
                            _persistPortAndLimit();
                            final ok = await controller.start();
                            if (!ok) {
                              startError = controller.lastError ?? localizations.mcpStartFailed;
                            }
                          } else {
                            await controller.stop();
                          }
                          if (mounted) setState(() {});
                        }))),
            if (startError != null) ...[
              Divider(height: 0, thickness: 0.3, color: dividerColor),
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(startError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13))),
            ],
          ]),
          const SizedBox(height: 12),
          section([
            ListTile(
                title: Text(localizations.mcpPort),
                subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextField(
                        controller: portController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                            isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.all(10)),
                        onSubmitted: (_) => _persistPortAndLimit()))),
            Divider(height: 0, thickness: 0.3, color: dividerColor),
            ListTile(
                title: Text(localizations.mcpBodyLimit),
                subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextField(
                        controller: bodyLimitController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                            isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.all(10)),
                        onSubmitted: (_) => _persistPortAndLimit()))),
          ]),
          const SizedBox(height: 12),
          section([
            ListTile(
                title: Text(localizations.mcpToken),
                subtitle: SelectableText(configuration.mcpAuthToken, style: const TextStyle(fontSize: 13))),
            Divider(height: 0, thickness: 0.3, color: dividerColor),
            ListTile(
                title: Text(localizations.copy),
                trailing: const Icon(Icons.copy, size: 18),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: configuration.mcpAuthToken));
                  if (context.mounted) {
                    FlutterToastr.show(localizations.copied, context);
                  }
                }),
            Divider(height: 0, thickness: 0.3, color: dividerColor),
            ListTile(
                title: Text(localizations.mcpRegenerateToken),
                trailing: const Icon(Icons.refresh, size: 18),
                onTap: () async {
                  controller.regenerateToken();
                  await configuration.flushConfig();
                  if (mounted) setState(() {});
                }),
          ]),
          const SizedBox(height: 12),
          section([
            ListTile(
                title: Text(localizations.mcpConnectUrl),
                subtitle: SelectableText(connectUrl, style: const TextStyle(fontSize: 13))),
            Divider(height: 0, thickness: 0.3, color: dividerColor),
            ListTile(
                title: Text(localizations.mcpCopyConfig),
                trailing: const Icon(Icons.copy, size: 18),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: connectHint));
                  if (context.mounted) {
                    FlutterToastr.show(localizations.copied, context);
                  }
                }),
            Divider(height: 0, thickness: 0.3, color: dividerColor),
            ListTile(
                title: Text(localizations.mcpConnections),
                trailing: Text('${controller.sessionCount}', style: const TextStyle(fontSize: 16))),
          ]),
          const SizedBox(height: 12),
          Text(localizations.mcpAudit, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          section(controller.auditLog.entries.isEmpty
              ? [
                  ListTile(title: Text(localizations.mcpAuditEmpty, style: TextStyle(color: Colors.grey.shade600)))
                ]
              : controller.auditLog.entries.take(20).map((entry) {
                  return ListTile(
                      dense: true,
                      title: Text('${entry.tool}  ${entry.ok ? 'OK' : 'FAIL'}'),
                      subtitle: Text(entry.summary),
                      trailing: Text(_formatTime(entry.time), style: const TextStyle(fontSize: 11)));
                }).toList()),
        ]));
  }

  void _persistPortAndLimit() {
    final configuration = widget.proxyServer.configuration;
    final port = int.tryParse(portController.text.trim());
    if (port != null && port > 0 && port < 65536) {
      configuration.mcpPort = port;
    } else {
      portController.text = '${configuration.mcpPort}';
    }
    final limit = int.tryParse(bodyLimitController.text.trim());
    if (limit != null && limit >= 0) {
      configuration.mcpBodyLimit = limit;
    } else {
      bodyLimitController.text = '${configuration.mcpBodyLimit}';
    }
    configuration.flushConfig();
    setState(() {});
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
