import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';

/// In-app log viewer with copy/export/clear, mirroring the Android Logs screen.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  bool _newestFirst = true;

  Color _levelColor(BuildContext context, LogLevel level) {
    final scheme = Theme.of(context).colorScheme;
    return switch (level) {
      LogLevel.info => scheme.onSurface,
      LogLevel.warn => Colors.orange.shade700,
      LogLevel.error => scheme.error,
    };
  }

  Future<void> _export() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${dir.path}${Platform.pathSeparator}foxyvpn-$stamp.log');
      await file.writeAsString(AppLogger.exportAsText());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Log exported to ${file.path}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: AppLogger.exportAsText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Logs copied to the clipboard'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: _newestFirst ? 'Show oldest first' : 'Show newest first',
            icon: Icon(_newestFirst
                ? Icons.arrow_downward
                : Icons.arrow_upward),
            onPressed: () => setState(() => _newestFirst = !_newestFirst),
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: 'Export to file',
            icon: const Icon(Icons.download_outlined),
            onPressed: _export,
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              AppLogger.clear();
              setState(() {});
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ValueListenableBuilder<List<LogEntry>>(
          valueListenable: AppLogger.entries,
          builder: (context, allEntries, _) {
            final entries =
                _newestFirst ? allEntries.reversed.toList() : allEntries;
            if (entries.isEmpty) {
              return Center(
                child: Text('No log entries yet.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final time = DateTime.fromMillisecondsSinceEpoch(
                    entry.timestampMillis);
                final hh = time.hour.toString().padLeft(2, '0');
                final mm = time.minute.toString().padLeft(2, '0');
                final ss = time.second.toString().padLeft(2, '0');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                          fontFamily: 'Consolas', fontSize: 12),
                      children: [
                        TextSpan(
                          text: '$hh:$mm:$ss ',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        TextSpan(
                          text: '[${entry.tag}] ',
                          style: TextStyle(color: scheme.primary),
                        ),
                        TextSpan(
                          text: entry.message,
                          style: TextStyle(
                              color: _levelColor(context, entry.level)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
