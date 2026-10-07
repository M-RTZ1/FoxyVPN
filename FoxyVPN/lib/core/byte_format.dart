const List<String> _units = ['KB', 'MB', 'GB', 'TB', 'PB'];

String formatBytes(int bytes) {
  if (bytes < 0) return '\u2014';
  if (bytes < 1024) return '$bytes B';
  double value = bytes / 1024.0;
  int index = 0;
  while (value >= 1024.0 && index < _units.length - 1) {
    value /= 1024.0;
    index++;
  }
  final text =
      value >= 100 ? value.round().toString() : value.toStringAsFixed(1);
  return '$text ${_units[index]}';
}

String formatBytesPerSecond(int bytesPerSecond) =>
    '${formatBytes(bytesPerSecond < 0 ? 0 : bytesPerSecond)}/s';
