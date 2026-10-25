import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'esp32_api.dart';
import 'home_controller.dart';
import 'mqtt_models.dart';
import 'secure_storage.dart';
import 'settings.dart';
import 'strings.dart';
import 'strings_cloud.dart';

final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{32,128}$');

class _Entry {
  const _Entry(this.device, this.index, this.status);
  final Device? device; // saved local address (null: seen through MQTT only)
  final int? index;
  final BoardStatus? status; // live status (null: never seen yet)
}

/// Every board of the home: claim a new one, give the app its access token, send it broker
/// credentials, rotate the token. Hardware setup (GPIO, Wi-Fi) needs the local connection;
/// the cloud connection only switches devices and edits names/rooms.
class BoardsPage extends StatefulWidget {
  const BoardsPage({super.key});

  @override
  State<BoardsPage> createState() => _BoardsPageState();
}

class _BoardsPageState extends State<BoardsPage> {
  bool _busy = false;

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Runs [job], showing its returned message (null = nothing to say) and a busy indicator.
  Future<void> _run(Future<String?> Function() job) async {
    setState(() => _busy = true);
    String? message;
    try {
      message = await job();
    } on ApiException catch (e) {
      message = mounted ? describeApiException(Tr.of(context.read<SettingsController>().value), e) : null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (message != null) _snack(message);
  }

  List<_Entry> _entries(AppSettings s, List<BoardStatus> statuses) {
    final used = <String>{};
    final out = <_Entry>[];
    for (var i = 0; i < s.devices.length; i++) {
      final d = s.devices[i];
      BoardStatus? st;
      for (final b in statuses) {
        if (d.boardId.isNotEmpty && b.id == d.boardId) st = b;
      }
      if (st != null) used.add(st.id);
      out.add(_Entry(d, i, st));
    }
    for (final st in statuses) {
      if (!used.contains(st.id)) out.add(_Entry(null, null, st));
    }
    return out;
  }

  // ------------------------------------------------------------------ claim
  Future<void> _addBoard(Tr tr) async {
    final values = await showDialog<List<String>>(
      context: context,
      builder: (_) => _FormDialog(
        title: tr.addBoard,
        note: tr.addBoardNote,
        okLabel: tr.claim,
        cancelLabel: tr.cancel,
        fields: [
          _Field(tr.boardAddress, setupEsp32Url, keyboard: TextInputType.url),
          _Field(tr.claimCode, '', hint: 'XXXXX-XXXXX', capitalize: true),
          _Field(tr.boardName, ''),
        ],
      ),
    );
    if (values == null) return;
    final url = normalizeUrl(values[0]);
    if (url == null) {
      _snack(tr.badAddress);
      return;
    }
    await _run(() => _claim(tr, url, values[1].trim(), values[2].trim()));
  }

  Future<String?> _claim(Tr tr, String url, String code, String name) async {
    final settings = context.read<SettingsController>();
    final store = context.read<SecureStore>();
    final esp = context.read<Esp32Controller>();
    final http = BoardHttp(baseUrl: url);
    try {
      final info = await http.call('GET', 'info', auth: false);
      final board = info['board'];
      if (board is! String || !validBoardId(board)) return tr.errFirmware;
      if (info['claimed'] == true) return tr.boardAlreadyClaimed;

      final token = SecureStore.generateToken();
      await http.call('POST', 'claim', body: {'code': code, 'token': token}, auth: false);
      await store.setBoardToken(board, token);

      final s = settings.value;
      final list = [...s.devices];
      final entry = Device(name: name.isEmpty ? board : name, url: url, boardId: board);
      var i = list.indexWhere((d) => d.boardId == board || d.url == url);
      if (i >= 0) {
        list[i] = entry;
      } else {
        list.add(entry);
        i = list.length - 1;
      }
      await settings.update(s.copyWith(devices: list, activeDevice: i));
      await esp.reloadToken();
      return tr.claimDone;
    } finally {
      http.close();
    }
  }

  // ---------------------------------------------------------- per-board work
  Future<BoardHttp?> _httpFor(Device d) async {
    final token = await context.read<SecureStore>().boardToken(d.tokenKey);
    if (!mounted) return null; // the screen was closed while the token was being read
    if (token == null) {
      _snack(Tr.of(context.read<SettingsController>().value).errAuth);
      return null;
    }
    return BoardHttp(baseUrl: d.url, token: token);
  }

  Future<void> _useLocal(int index) async {
    final settings = context.read<SettingsController>();
    await settings.update(settings.value.copyWith(activeDevice: index));
  }

  Future<void> _setAddress(Tr tr, int index) async {
    final settings = context.read<SettingsController>();
    final d = settings.value.devices[index];
    final v = await showDialog<List<String>>(
      context: context,
      builder: (_) => _FormDialog(
        title: tr.setAddress,
        okLabel: tr.save,
        cancelLabel: tr.cancel,
        fields: [_Field(tr.boardAddress, d.url, keyboard: TextInputType.url)],
      ),
    );
    if (v == null) return;
    final url = normalizeUrl(v[0]);
    if (url == null) {
      _snack(tr.badAddress);
      return;
    }
    final list = [...settings.value.devices];
    list[index] = d.copyWith(url: url);
    await settings.update(settings.value.copyWith(devices: list));
  }

  Future<void> _enterToken(Tr tr, int index) async {
    final settings = context.read<SettingsController>();
    final store = context.read<SecureStore>();
    final esp = context.read<Esp32Controller>();
    final d = settings.value.devices[index];
    final v = await showDialog<List<String>>(
      context: context,
      builder: (_) => _FormDialog(
        title: tr.enterToken,
        note: tr.enterTokenNote,
        okLabel: tr.save,
        cancelLabel: tr.cancel,
        fields: [_Field(tr.accessToken, '', obscure: true)],
      ),
    );
    if (v == null) return;
    final token = v[0].trim();
    if (!_tokenPattern.hasMatch(token)) {
      _snack(tr.badToken);
      return;
    }
    await store.setBoardToken(d.tokenKey, token);
    if (index == settings.value.activeDevice) await esp.reloadToken();
    _snack(tr.tokenSaved);
  }

  Future<void> _rotateToken(Tr tr, int index) async {
    final settings = context.read<SettingsController>();
    final store = context.read<SecureStore>();
    final esp = context.read<Esp32Controller>();
    final d = settings.value.devices[index];
    await _run(() async {
      final http = await _httpFor(d);
      if (http == null) return null;
      try {
        final fresh = SecureStore.generateToken();
        await http.call('POST', 'auth/rotate', body: {'token': fresh});
        await store.setBoardToken(d.tokenKey, fresh); // the board already stopped accepting the old one
        if (index == settings.value.activeDevice) await esp.reloadToken();
        return tr.tokenRotated;
      } finally {
        http.close();
      }
    });
  }

  Future<void> _sendCloudLogin(Tr tr, int index) async {
    final settings = context.read<SettingsController>();
    final saved = await context.read<SecureStore>().loadCloud();
    if (!mounted) return;
    final d = settings.value.devices[index];
    final v = await showDialog<List<String>>(
      context: context,
      builder: (_) => _FormDialog(
        title: tr.sendCloudLogin,
        note: tr.sendCloudLoginNote,
        okLabel: tr.send,
        cancelLabel: tr.cancel,
        fields: [
          _Field(tr.cloudHost, saved?.host ?? '', keyboard: TextInputType.url),
          _Field(tr.cloudUsername, d.boardId.isEmpty ? '' : 'board-${d.boardId}'),
          _Field(tr.cloudPassword, '', obscure: true),
          _Field(tr.cloudHomeId, saved?.homeId ?? 'home'),
        ],
      ),
    );
    if (v == null) return;
    final cfg = CloudConfig(
      provider: saved?.provider ?? CloudProvider.hivemq,
      host: v[0].trim(),
      port: saved?.port ?? 8883,
      username: v[1].trim(),
      password: v[2],
      homeId: v[3].trim().toLowerCase(),
    );
    final problem = cfg.validate();
    if (problem != null) {
      _snack(problem);
      return;
    }
    await _run(() async {
      final http = await _httpFor(d);
      if (http == null) return null;
      try {
        await http.call('POST', 'config/mqtt', body: {
          'enabled': true,
          'provider': cfg.provider.name,
          'host': cfg.host,
          'port': cfg.port,
          'username': cfg.username,
          'password': cfg.password,
          'homeId': cfg.homeId,
        });
        return tr.cloudLoginSent;
      } finally {
        http.close();
      }
    });
  }

  Future<void> _boardSettings(Tr tr, int index, String currentName) async {
    final settings = context.read<SettingsController>();
    final d = settings.value.devices[index];
    final v = await showDialog<List<String>>(
      context: context,
      builder: (_) => _FormDialog(
        title: tr.boardSettings,
        note: tr.timeZoneNote,
        okLabel: tr.save,
        cancelLabel: tr.cancel,
        fields: [
          _Field(tr.boardName, currentName),
          _Field(tr.timeZone, '', hint: 'IST-5:30'),
        ],
      ),
    );
    if (v == null) return;
    await _run(() async {
      final http = await _httpFor(d);
      if (http == null) return null;
      try {
        await http.call('POST', 'config/board', body: {
          if (v[0].trim().isNotEmpty) 'name': v[0].trim(),
          if (v[1].trim().isNotEmpty) 'tz': v[1].trim(),
        });
        return tr.saved;
      } finally {
        http.close();
      }
    });
  }

  Future<void> _remove(Tr tr, int index) async {
    final settings = context.read<SettingsController>();
    final store = context.read<SecureStore>();
    final d = settings.value.devices[index];
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.removeBoardTitle),
        content: Text(tr.removeBoardBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr.remove)),
        ],
      ),
    );
    if (yes != true) return;
    await store.deleteBoardToken(d.tokenKey);
    final s = settings.value;
    final list = [...s.devices]..removeAt(index);
    final active = list.isEmpty ? 0 : s.activeDevice.clamp(0, list.length - 1).toInt();
    await settings.update(s.copyWith(devices: list, activeDevice: active));
  }

  // -------------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final home = context.watch<HomeController>();
    final tr = Tr.of(settings.value);
    final s = settings.value;
    final entries = _entries(s, home.boards);

    return Scaffold(
      appBar: AppBar(title: Text(tr.boardsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : () => _addBoard(tr),
        icon: const Icon(Icons.add),
        label: Text(tr.addBoard),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(tr.boardsHelp, style: Theme.of(context).textTheme.bodySmall),
              ),
              if (entries.isEmpty)
                Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr.noBoardsYet))),
              for (final e in entries) _tile(context, tr, s, e),
            ],
          ),
          if (_busy) const Positioned.fill(child: IgnorePointer(child: Center(child: CircularProgressIndicator()))),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, Tr tr, AppSettings s, _Entry e) {
    final st = e.status;
    final d = e.device;
    final isActive = e.index != null && e.index == s.activeDevice;
    final name = st?.name ?? d?.name ?? '';
    final id = st?.id ?? d?.boardId ?? '';
    final source = st == null ? BoardSource.none : st.source;
    final color = switch (source) {
      BoardSource.local => Colors.green,
      BoardSource.cloud => Colors.blue,
      BoardSource.none => Theme.of(context).disabledColor,
    };
    final lines = <String>[
      if (id.isNotEmpty) id else tr.boardNotIdentified,
      if (d != null) d.url,
      if (st != null && st.fw.isNotEmpty) 'v${st.fw} · ${st.chip}',
      tr.sourceLabel(source),
    ];
    final index = e.index;
    return ListTile(
      leading: Icon(isActive ? Icons.radio_button_checked : Icons.developer_board, color: color),
      title: Text(name.isEmpty ? tr.unnamedBoard : name),
      subtitle: Text(lines.join('\n')),
      isThreeLine: lines.length > 2,
      trailing: index == null
          ? null
          : PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'use':
                    _useLocal(index);
                  case 'address':
                    _setAddress(tr, index);
                  case 'token':
                    _enterToken(tr, index);
                  case 'rotate':
                    _rotateToken(tr, index);
                  case 'cloud':
                    _sendCloudLogin(tr, index);
                  case 'settings':
                    _boardSettings(tr, index, name);
                  case 'remove':
                    _remove(tr, index);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'use', child: Text(tr.useLocally)),
                PopupMenuItem(value: 'address', child: Text(tr.setAddress)),
                PopupMenuItem(value: 'settings', child: Text(tr.boardSettings)),
                PopupMenuItem(value: 'cloud', child: Text(tr.sendCloudLogin)),
                PopupMenuItem(value: 'token', child: Text(tr.enterToken)),
                PopupMenuItem(value: 'rotate', child: Text(tr.rotateToken)),
                PopupMenuItem(value: 'remove', child: Text(tr.remove)),
              ],
            ),
    );
  }
}

// ------------------------------------------------------------------ small form dialog
class _Field {
  const _Field(this.label, this.initial, {this.hint, this.obscure = false, this.keyboard, this.capitalize = false});
  final String label;
  final String initial;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboard;
  final bool capitalize;
}

class _FormDialog extends StatefulWidget {
  const _FormDialog({
    required this.title,
    required this.fields,
    required this.okLabel,
    required this.cancelLabel,
    this.note,
  });

  final String title;
  final String? note;
  final List<_Field> fields;
  final String okLabel;
  final String cancelLabel;

  @override
  State<_FormDialog> createState() => _FormDialogState();
}

class _FormDialogState extends State<_FormDialog> {
  late final List<TextEditingController> _controllers = [
    for (final f in widget.fields) TextEditingController(text: f.initial),
  ];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.note != null) ...[
              Text(widget.note!, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
            ],
            for (var i = 0; i < widget.fields.length; i++) ...[
              TextField(
                controller: _controllers[i],
                obscureText: widget.fields[i].obscure,
                keyboardType: widget.fields[i].keyboard,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: widget.fields[i].capitalize ? TextCapitalization.characters : TextCapitalization.none,
                decoration: InputDecoration(labelText: widget.fields[i].label, hintText: widget.fields[i].hint),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(widget.cancelLabel)),
        TextButton(
          onPressed: () => Navigator.pop(context, [for (final c in _controllers) c.text]),
          child: Text(widget.okLabel),
        ),
      ],
    );
  }
}
