import 'dart:convert';

/// What happens to a flow that matches a split-tunnel rule.
enum SplitTunnelAction {
  /// Carry it through the VPN tunnel, as if split tunneling were off.
  tunnel,

  /// Dial it from the machine itself, around the VPN.
  direct,
}

/// The two flavours of pattern a rule can hold. A flow's target is tested
/// against rules of one flavour only: a hostname against [domain] rules, an
/// address literal against [address] rules.
enum SplitTunnelPatternKind { domain, address }

/// One split-tunnel rule: a domain suffix (a TLD such as `ir`, or a hostname
/// such as `example.com`), or an IPv4 range, plus the action to take for the
/// flows that match it.
class SplitTunnelRule {
  const SplitTunnelRule({
    required this.pattern,
    required this.kind,
    required this.action,
    this.enabled = true,
  });

  /// Normalised pattern: `ir`, `example.com`, `192.168.0.0/16`.
  final String pattern;
  final SplitTunnelPatternKind kind;
  final SplitTunnelAction action;
  final bool enabled;

  /// Parses free-form user input: `.ir`, `ir`, `*.example.com`,
  /// `https://example.com/path`, `203.0.113.7`, `192.168.0.0/16`.
  /// Returns null when the input is not a usable pattern.
  static SplitTunnelRule? parse(
    String input, {
    SplitTunnelAction action = SplitTunnelAction.direct,
    bool enabled = true,
  }) {
    final normalized = normalizePattern(input);
    if (normalized == null) return null;
    return SplitTunnelRule(
      pattern: normalized,
      kind: normalized.contains('/') || _isIpv4(normalized)
          ? SplitTunnelPatternKind.address
          : SplitTunnelPatternKind.domain,
      action: action,
      enabled: enabled,
    );
  }

  /// Strips the decoration people paste (scheme, path, wildcard, leading or
  /// trailing dot) and validates what is left. Null means "not a pattern".
  ///
  /// IPv6 is deliberately rejected: the tunnel is IPv4-only, so v6 traffic
  /// already leaves the machine untreated and a rule for it would be a lie.
  static String? normalizePattern(String input) {
    var value = input.trim().toLowerCase();
    if (value.isEmpty || value.length > 253) return null;

    final scheme = value.indexOf('://');
    if (scheme >= 0) value = value.substring(scheme + 3);
    // Userinfo or a bracketed IPv6 literal: too ambiguous to match on.
    if (value.contains('@') || value.startsWith('[')) return null;
    if (value.startsWith('*.')) value = value.substring(2);
    if (value.startsWith('.')) value = value.substring(1);
    while (value.endsWith('.')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.isEmpty) return null;

    final slash = value.indexOf('/');
    if (slash >= 0) {
      final host = value.substring(0, slash);
      final tail = value.substring(slash + 1);
      if (_isIpv4(host)) {
        final prefix = int.tryParse(tail);
        if (prefix == null || prefix < 0 || prefix > 32) return null;
        return '$host/$prefix';
      }
      // A slash after anything else was a URL path, not a prefix.
      if (_isIpv6(host) || tail.contains('.') || tail.contains(':')) return null;
      value = host;
    }
    if (value.isEmpty || value.contains(':')) return null;
    if (_isIpv4(value)) return value;
    return _isDomainPattern(value) ? value : null;
  }

  /// The pattern as the user means it: TLD and hostname rules are suffixes.
  String get display =>
      kind == SplitTunnelPatternKind.domain ? '.$pattern' : pattern;

  Map<String, dynamic> toJson() => {
        'p': pattern,
        'k': kind.name,
        'a': action.name,
        if (!enabled) 'e': false,
      };

  static SplitTunnelRule? fromJson(Object? json) {
    if (json is! Map) return null;
    final pattern = json['p'];
    final kind = json['k'];
    final action = json['a'];
    if (pattern is! String || kind is! String || action is! String) return null;
    if (normalizePattern(pattern) != pattern) return null;
    final ruleKind = SplitTunnelPatternKind.values.firstWhere(
      (value) => value.name == kind,
      orElse: () => SplitTunnelPatternKind.domain,
    );
    return SplitTunnelRule(
      pattern: pattern,
      kind: ruleKind,
      action: SplitTunnelAction.values.firstWhere(
        (value) => value.name == action,
        orElse: () => SplitTunnelAction.tunnel,
      ),
      enabled: json['e'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SplitTunnelRule &&
      other.pattern == pattern &&
      other.kind == kind &&
      other.action == action &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(pattern, kind, action, enabled);

  @override
  String toString() =>
      '${enabled ? '' : 'off '}${action.name} ${kind.name}:$pattern';
}

/// The rule set consulted for every flow, plus the action to use when no rule
/// matches.
class SplitTunnelPolicy {
  SplitTunnelPolicy({
    this.rules = const [],
    this.defaultAction = SplitTunnelAction.tunnel,
    this.enabled = false,
  }) : _matching = List<SplitTunnelRule>.of(
         rules.where((rule) => rule.enabled),
       )..sort(_bySpecificity);

  final List<SplitTunnelRule> rules;
  final SplitTunnelAction defaultAction;
  final bool enabled;

  /// Enabled rules, most specific first, so the first match wins.
  final List<SplitTunnelRule> _matching;

  int get enabledRuleCount => _matching.length;

  /// A clash between equally specific rules is resolved in favour of the
  /// tunnelled one, so a misconfiguration can never silently leak traffic
  /// onto the plain network.
  static int _bySpecificity(SplitTunnelRule a, SplitTunnelRule b) {
    final bySpecificity = _specificity(b).compareTo(_specificity(a));
    if (bySpecificity != 0) return bySpecificity;
    if (a.action != b.action) {
      return a.action == SplitTunnelAction.tunnel ? -1 : 1;
    }
    return a.pattern.compareTo(b.pattern);
  }

  static int _specificity(SplitTunnelRule rule) =>
      rule.kind == SplitTunnelPatternKind.address
          ? 1000 + _prefixLength(rule.pattern)
          : rule.pattern.length;

  /// The decision for one flow target, or null when split tunneling is off.
  SplitTunnelDecision? decide(String rawTarget) {
    if (!enabled) return null;
    var host = rawTarget.trim().toLowerCase();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    if (host.isEmpty) return null;
    final isAddress = _isIpv4(host) || _isIpv6(host);
    final kind = isAddress
        ? SplitTunnelPatternKind.address
        : SplitTunnelPatternKind.domain;
    for (final rule in _matching) {
      if (rule.kind != kind) continue;
      final hit = isAddress
          ? _addressMatches(rule, host)
          : _domainMatches(rule, host);
      if (hit) return SplitTunnelDecision(action: rule.action, rule: rule);
    }
    return SplitTunnelDecision(action: defaultAction);
  }

  /// A suffix match: `ir` covers `site.ir` and `a.site.ir` but never
  /// `notir.com`; `example.com` covers the host itself and its subdomains.
  static bool _domainMatches(SplitTunnelRule rule, String host) =>
      host == rule.pattern || host.endsWith('.${rule.pattern}');

  static bool _addressMatches(SplitTunnelRule rule, String host) {
    final slash = rule.pattern.indexOf('/');
    if (slash < 0) return rule.pattern == host;
    final network = _ipv4Bytes(rule.pattern.substring(0, slash));
    final address = _ipv4Bytes(host);
    if (network == null || address == null) return false;
    final prefix = _prefixLength(rule.pattern);
    for (var bit = 0; bit < prefix; bit++) {
      final mask = 0x80 >> (bit & 7);
      final byte = bit >> 3;
      if ((network[byte] & mask) != (address[byte] & mask)) return false;
    }
    return true;
  }

  static int _prefixLength(String pattern) {
    final slash = pattern.indexOf('/');
    return slash < 0 ? 32 : (int.tryParse(pattern.substring(slash + 1)) ?? 32);
  }

  static String encodeRules(List<SplitTunnelRule> rules) =>
      jsonEncode([for (final rule in rules) rule.toJson()]);

  static List<SplitTunnelRule> decodeRules(String? stored) {
    if (stored == null || stored.isEmpty) return const [];
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! List) return const [];
      return decoded
          .map(SplitTunnelRule.fromJson)
          .whereType<SplitTunnelRule>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}

/// The engine's answer for one flow: what to do, and which rule said so.
class SplitTunnelDecision {
  const SplitTunnelDecision({required this.action, this.rule});

  final SplitTunnelAction action;

  /// Null when the fallback action decided.
  final SplitTunnelRule? rule;

  bool get bypassesTunnel => action == SplitTunnelAction.direct;

  /// Short text for the log: `bypass .ir`, `vpn .example.com`, or the
  /// default when no rule matched.
  String get label {
    final matched = rule;
    if (matched == null) {
      return bypassesTunnel ? 'bypass (default)' : 'vpn (default)';
    }
    return bypassesTunnel
        ? 'bypass ${matched.display}'
        : 'vpn ${matched.display}';
  }

  @override
  String toString() => label;
}

/// Destinations a direct flow must never reach: keeping the VPN bypass and
/// the local network separate is the point of the check.
bool isLocalOrSpecialAddress(String host) {
  var value = host.trim().toLowerCase();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  final v4 = _ipv4Bytes(value);
  if (v4 != null) {
    final first = v4[0];
    final second = v4[1];
    if (first == 0 || first == 127) return true; // this-network + loopback
    if (first == 10) return true;
    if (first == 172 && second >= 16 && second <= 31) return true;
    if (first == 192 && second == 168) return true;
    if (first == 169 && second == 254) return true; // link local
    if (first == 100 && second >= 64 && second <= 127) return true; // mapdns
    if (first == 198 && second == 18) return true; // mapdns listener
    if (first >= 224) return true; // multicast + reserved
    if (first == 192 && second == 0 && v4[2] == 2) return true; // TEST-NET
    return false;
  }
  if (!value.contains(':')) return false;
  if (value == '::' || value == '::1') return true;
  // IPv4-mapped form: judge it by the address it carries.
  final mapped = value.lastIndexOf(':');
  if (mapped > 0 && _isIpv4(value.substring(mapped + 1))) {
    return isLocalOrSpecialAddress(value.substring(mapped + 1));
  }
  final first = _firstIPv6Group(value);
  if (first != null) {
    if (first >= 0xFC00 && first <= 0xFDFF) return true; // fc00::/7 ULA
    if (first >= 0xFE80 && first <= 0xFEBF) return true; // fe80::/10 link local
    if (first >= 0xFF00) return true; // multicast
  }
  return false;
}

bool _isIpv4(String value) => _ipv4Bytes(value) != null;

List<int>? _ipv4Bytes(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return null;
  final bytes = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return null;
    if (!part.codeUnits.every((c) => c >= 48 && c <= 57)) return null;
    final octet = int.tryParse(part);
    if (octet == null || octet > 255) return null;
    bytes.add(octet);
  }
  return bytes;
}

bool _isIpv6(String value) {
  if (!value.contains(':')) return false;
  final compression = value.indexOf('::');
  if (compression != value.lastIndexOf('::') || value.contains(':::')) {
    return false;
  }
  List<String> halves(String text) =>
      text.split(':').where((group) => group.isNotEmpty).toList();
  final List<String> groups;
  if (compression >= 0) {
    groups = [
      ...halves(value.substring(0, compression)),
      ...halves(value.substring(compression + 2)),
    ];
  } else {
    groups = value.split(':');
    if (groups.length != 8) return false;
  }
  if (groups.isEmpty || groups.length > 8) return false;
  for (final group in groups) {
    if (group.contains('.')) {
      // Trailing IPv4 form, e.g. ::ffff:192.0.2.1
      if (!_isIpv4(group)) return false;
      continue;
    }
    if (group.length > 4 || !group.codeUnits.every(_isHexDigit)) return false;
  }
  return true;
}

/// The first hextet of an IPv6 text form, or null when it is not hex.
int? _firstIPv6Group(String value) {
  final trimmed = value.startsWith('::') ? value.substring(2) : value;
  final group = trimmed.split(':').first;
  if (group.isEmpty || group.contains('.')) return null;
  return int.tryParse(group, radix: 16);
}

bool _isHexDigit(int code) =>
    (code >= 48 && code <= 57) ||
    (code >= 97 && code <= 102) ||
    (code >= 65 && code <= 70);

bool _isDomainPattern(String value) {
  if (value.contains(':')) return false;
  final labels = value.split('.');
  if (labels.length > 127) return false;
  // No real TLD is all digits, so a numeric last label is a mistyped IPv4 such
  // as 203.0.113.256 — better to reject it than to file it as a domain.
  if (labels.last.codeUnits.every((c) => c >= 48 && c <= 57)) return false;
  for (final label in labels) {
    if (label.isEmpty || label.length > 63) return false;
    if (label.startsWith('-') || label.endsWith('-')) return false;
    if (!label.codeUnits.every(
      (c) =>
          (c >= 97 && c <= 122) ||
          (c >= 48 && c <= 57) ||
          c == 45 || // -
          c == 95, // _
    )) {
      return false;
    }
  }
  return true;
}

/// Quick-add patterns offered in Settings. `.ir` first: the usual reason to
/// want this at all is keeping domestic sites on the local network.
const List<String> splitTunnelTldPresets = ['ir', 'com', 'net', 'org', 'co.ir'];
