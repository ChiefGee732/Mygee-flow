import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Look
// ---------------------------------------------------------------------------
const _bg = Color(0xFF0A0E1A);
const _surface = Color(0xFF151B2E);
const _accent = Color(0xFFFF2E88); // flow pink
const _cyan = Color(0xFF22E1FF); // flow cyan
const _text = Color(0xFFF4F6FF);
const _muted = Color(0xFF8E97B5);
const _flow = LinearGradient(colors: [_accent, _cyan]);

Color groupColor(String group) => group == 'DJ Mixes' ? _accent : _cyan;

class Wordmark extends StatelessWidget {
  const Wordmark({super.key});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (r) => _flow.createShader(r),
      child: const Text(
        'MYGEE FLOW',
        style: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.5,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Round play / pause button with the flow gradient.
class PlayPauseButton extends StatelessWidget {
  final double size;
  const PlayPauseButton({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: player.playerStateStream,
      builder: (context, s) {
        final playing = s.data?.playing ?? false;
        return GestureDetector(
          onTap: playing ? player.pause : player.play,
          child: Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: _flow,
            ),
            child: Icon(
              playing ? Icons.pause : Icons.play_arrow,
              size: size * 0.6,
              color: _bg,
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Audio engine (background play + equalizer)
// ---------------------------------------------------------------------------
final equalizer = AndroidEqualizer();
final loudness = AndroidLoudnessEnhancer();
final player = AudioPlayer(
  audioPipeline: AudioPipeline(androidAudioEffects: [loudness, equalizer]),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'ke.mymusic.musicplayer.audio',
    androidNotificationChannelName: 'MYGEE FLOW playback',
    androidNotificationOngoing: true,
  );
  runApp(const MusicApp());
  app.init();
}

// ---------------------------------------------------------------------------
// App state: songs on the phone + which folder each song is in
// ---------------------------------------------------------------------------
const _defaultGroups = <String, List<String>>{
  'DJ Mixes': ['Pop', 'RnB', 'Hip-hop', 'Mixed'],
  'Singles': ['Gospel', 'RnB', 'Hip-hop', 'Other'],
};

final app = AppState();

class AppState extends ChangeNotifier {
  final OnAudioQuery _query = OnAudioQuery();
  late SharedPreferences prefs;

  List<SongModel> songs = [];
  Map<String, List<String>> groups = {
    for (final e in _defaultGroups.entries) e.key: [...e.value],
  };
  Map<String, String> assigned = {}; // song id -> "Group/Folder"
  bool hasPermission = false;
  bool loading = true;
  bool _eqRestored = false;

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    final g = prefs.getString('groups');
    if (g != null) {
      final m = jsonDecode(g) as Map<String, dynamic>;
      groups = m.map((k, v) => MapEntry(k, List<String>.from(v as List)));
    }
    final a = prefs.getString('assigned');
    if (a != null) {
      assigned = Map<String, String>.from(jsonDecode(a) as Map);
    }
    await Permission.notification.request();
    await loadSongs();
  }

  Future<void> loadSongs() async {
    loading = true;
    notifyListeners();
    hasPermission = await _query.permissionsStatus();
    if (!hasPermission) hasPermission = await _query.permissionsRequest();
    if (hasPermission) {
      final all = await _query.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      songs = all
          .where((s) => s.uri != null && (s.duration ?? 0) > 30000)
          .toList();
    }
    loading = false;
    notifyListeners();
  }

  String folderId(String group, String name) => '$group/$name';

  List<SongModel> songsIn(String id) =>
      songs.where((s) => assigned['${s.id}'] == id).toList();

  List<SongModel> get unsorted =>
      songs.where((s) => assigned['${s.id}'] == null).toList();

  List<String> get allFolderIds => [
        for (final e in groups.entries)
          for (final f in e.value) folderId(e.key, f),
      ];

  Future<void> assign(SongModel s, String? id) async {
    if (id == null) {
      assigned.remove('${s.id}');
    } else {
      assigned['${s.id}'] = id;
    }
    await prefs.setString('assigned', jsonEncode(assigned));
    notifyListeners();
  }

  Future<void> addFolder(String group, String name) async {
    final n = name.trim();
    if (n.isEmpty || groups[group]!.contains(n)) return;
    groups[group]!.add(n);
    await prefs.setString('groups', jsonEncode(groups));
    notifyListeners();
  }

  /// Sorts songs that have no folder yet, using the file path and length.
  /// Long files (20+ minutes) or paths containing "mix" or "dj" become DJ mixes.
  Future<int> autoSort() async {
    var count = 0;
    for (final s in unsorted) {
      final path = s.data.toLowerCase();
      String? genre;
      if (path.contains('gospel')) {
        genre = 'Gospel';
      } else if (path.contains('rnb') ||
          path.contains('r&b') ||
          path.contains('r_b')) {
        genre = 'RnB';
      } else if (path.contains('hip')) {
        genre = 'Hip-hop';
      } else if (path.contains('pop')) {
        genre = 'Pop';
      }
      final isMix = (s.duration ?? 0) >= 20 * 60 * 1000 ||
          path.contains('mix') ||
          path.contains('dj');
      String? id;
      if (isMix) {
        final options = groups['DJ Mixes']!;
        id = folderId('DJ Mixes',
            options.contains(genre) ? genre! : 'Mixed');
      } else if (genre != null && groups['Singles']!.contains(genre)) {
        id = folderId('Singles', genre);
      }
      if (id != null && allFolderIds.contains(id)) {
        assigned['${s.id}'] = id;
        count++;
      }
    }
    await prefs.setString('assigned', jsonEncode(assigned));
    notifyListeners();
    return count;
  }

  // ----- playback -----
  Future<void> playQueue(List<SongModel> list, int index) async {
    final sources = list
        .map((s) => AudioSource.uri(
              Uri.parse(s.uri!),
              tag: MediaItem(
                id: '${s.id}',
                title: s.title,
                artist: artistOf(s),
                duration: Duration(milliseconds: s.duration ?? 0),
              ),
            ))
        .toList();
    await player.setAudioSource(
      ConcatenatingAudioSource(children: sources),
      initialIndex: index,
    );
    player.play();
    if (!_eqRestored) {
      _eqRestored = true;
      restoreEq();
    }
  }

  // ----- equalizer -----
  Future<void> saveEq(AndroidEqualizerParameters p) async {
    await prefs.setString(
      'eq',
      jsonEncode({
        'on': equalizer.enabled,
        'gains': p.bands.map((b) => b.gain).toList(),
        'loud': loudness.targetGain,
      }),
    );
  }

  Future<void> restoreEq() async {
    final raw = prefs.getString('eq');
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final p =
          await equalizer.parameters.timeout(const Duration(seconds: 5));
      final gains = (m['gains'] as List).map((e) => (e as num).toDouble());
      var i = 0;
      for (final g in gains) {
        if (i < p.bands.length) await p.bands[i].setGain(g);
        i++;
      }
      await equalizer.setEnabled(m['on'] == true);
      final l = (m['loud'] as num?)?.toDouble() ?? 0;
      await loudness.setTargetGain(l);
      await loudness.setEnabled(l > 0);
    } catch (_) {}
  }
}

String artistOf(SongModel s) {
  final a = s.artist;
  return (a == null || a == '<unknown>') ? 'Unknown artist' : a;
}

String fmt(int ms) {
  final d = Duration(milliseconds: ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

// ---------------------------------------------------------------------------
// App shell
// ---------------------------------------------------------------------------
class MusicApp extends StatelessWidget {
  const MusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MYGEE FLOW',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(
          primary: _accent,
          onPrimary: Colors.white,
          surface: _surface,
          onSurface: _text,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _bg,
          foregroundColor: _text,
          titleTextStyle:
              TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: _text),
        ),
        listTileTheme: const ListTileThemeData(
          iconColor: _accent,
          textColor: _text,
          subtitleTextStyle: TextStyle(color: _muted),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Home: folders
// ---------------------------------------------------------------------------
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Wordmark(),
            actions: [
              IconButton(
                tooltip: 'Sort songs into folders by name',
                icon: const Icon(Icons.auto_fix_high),
                onPressed: () async {
                  final n = await app.autoSort();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(n == 0
                        ? 'No songs matched a folder. Use the folder button on a song to sort it.'
                        : 'Sorted $n songs into folders.'),
                  ));
                },
              ),
              IconButton(
                tooltip: 'Rescan phone',
                icon: const Icon(Icons.refresh),
                onPressed: app.loadSongs,
              ),
            ],
          ),
          bottomNavigationBar: const MiniPlayer(),
          body: _body(context),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    if (app.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!app.hasPermission) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Allow access to music on your phone so the app can find your songs.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: app.loadSongs,
                child: const Text('Allow access'),
              ),
            ],
          ),
        ),
      );
    }
    if (app.songs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No songs found. Copy music files onto your phone, then tap the refresh button.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18),
          ),
        ),
      );
    }
    return ListView(
      children: [
        _tile(context, Icons.library_music, 'All songs', () => app.songs,
            app.songs.length, _accent),
        for (final g in app.groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(g.key,
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: groupColor(g.key))),
                ),
                IconButton(
                  tooltip: 'Add a folder to ${g.key}',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: () => _addFolderDialog(context, g.key),
                ),
              ],
            ),
          ),
          for (final f in g.value)
            _tile(
              context,
              Icons.folder,
              f,
              () => app.songsIn(app.folderId(g.key, f)),
              app.songsIn(app.folderId(g.key, f)).length,
              groupColor(g.key),
              title: '${g.key}: $f',
            ),
        ],
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 20, 4, 0),
          child: Text('Not sorted yet',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        ),
        _tile(context, Icons.inbox, 'Unsorted', () => app.unsorted,
            app.unsorted.length, _muted),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _tile(BuildContext context, IconData icon, String label,
      List<SongModel> Function() getSongs, int count, Color color,
      {String? title}) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: const TextStyle(fontSize: 18)),
      trailing: Text('$count', style: const TextStyle(color: _muted)),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              SongListScreen(title: title ?? label, getSongs: getSongs),
        ),
      ),
    );
  }

  Future<void> _addFolderDialog(BuildContext context, String group) async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('New folder in $group'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('Add folder')),
        ],
      ),
    );
    if (name != null) await app.addFolder(group, name);
  }
}

// ---------------------------------------------------------------------------
// Song list for one folder
// ---------------------------------------------------------------------------
class SongListScreen extends StatelessWidget {
  final String title;
  final List<SongModel> Function() getSongs;
  const SongListScreen({super.key, required this.title, required this.getSongs});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final songs = getSongs();
        return Scaffold(
          appBar: AppBar(title: Text(title)),
          bottomNavigationBar: const MiniPlayer(),
          body: songs.isEmpty
              ? const Center(
                  child: Text('No songs here yet.',
                      style: TextStyle(fontSize: 18, color: _muted)))
              : ListView.builder(
                  itemCount: songs.length,
                  itemBuilder: (context, i) {
                    final s = songs[i];
                    return ListTile(
                      title: Text(s.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(artistOf(s),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => app.playQueue(songs, i),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(fmt(s.duration ?? 0),
                              style: const TextStyle(color: _muted)),
                          IconButton(
                            tooltip: 'Move to folder',
                            icon: const Icon(Icons.drive_file_move_outline),
                            onPressed: () => _moveSheet(context, s),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        );
      },
    );
  }

  void _moveSheet(BuildContext context, SongModel s) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _surface,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Move "${s.title}" to',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            for (final id in app.allFolderIds)
              ListTile(
                leading: const Icon(Icons.folder),
                title: Text(id.replaceFirst('/', ': ')),
                selected: app.assigned['${s.id}'] == id,
                onTap: () {
                  app.assign(s, id);
                  Navigator.pop(ctx);
                },
              ),
            ListTile(
              leading: const Icon(Icons.inbox),
              title: const Text('Unsorted'),
              onTap: () {
                app.assign(s, null);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mini player (bottom bar)
// ---------------------------------------------------------------------------
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SequenceState?>(
      stream: player.sequenceStateStream,
      builder: (context, snap) {
        final tag = snap.data?.currentSource?.tag;
        if (tag is! MediaItem) return const SizedBox.shrink();
        return Material(
          color: _surface,
          child: InkWell(
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const NowPlayingScreen())),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tag.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                          Text(tag.artist ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _muted)),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: PlayPauseButton(size: 48),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Now playing
// ---------------------------------------------------------------------------
class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Now playing'),
        actions: [
          IconButton(
            tooltip: 'Equalizer',
            icon: const Icon(Icons.equalizer),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const EqualizerScreen())),
          ),
        ],
      ),
      body: StreamBuilder<SequenceState?>(
        stream: player.sequenceStateStream,
        builder: (context, snap) {
          final tag = snap.data?.currentSource?.tag;
          if (tag is! MediaItem) {
            return const Center(child: Text('Nothing playing'));
          }
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Center(
                  child: Container(
                    width: 230,
                    height: 230,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: _flow,
                    ),
                    child: const Icon(Icons.graphic_eq, size: 120, color: _bg),
                  ),
                ),
                const Spacer(),
                Text(tag.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 26, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(tag.artist ?? '',
                    style: const TextStyle(fontSize: 16, color: _muted)),
                const SizedBox(height: 16),
                StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (context, s) {
                    final pos = s.data ?? Duration.zero;
                    final dur = player.duration ?? Duration.zero;
                    final max = dur.inMilliseconds < 1
                        ? 1.0
                        : dur.inMilliseconds.toDouble();
                    final value = pos.inMilliseconds.toDouble().clamp(0.0, max);
                    return Column(
                      children: [
                        Slider(
                          value: value,
                          max: max,
                          onChanged: (v) =>
                              player.seek(Duration(milliseconds: v.round())),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(fmt(pos.inMilliseconds),
                                  style: const TextStyle(color: _muted)),
                              Text(fmt(dur.inMilliseconds),
                                  style: const TextStyle(color: _muted)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    StreamBuilder<bool>(
                      stream: player.shuffleModeEnabledStream,
                      builder: (context, s) {
                        final on = s.data ?? false;
                        return IconButton(
                          iconSize: 30,
                          tooltip: 'Shuffle',
                          color: on ? _accent : _muted,
                          icon: const Icon(Icons.shuffle),
                          onPressed: () async {
                            if (!on) await player.shuffle();
                            await player.setShuffleModeEnabled(!on);
                          },
                        );
                      },
                    ),
                    IconButton(
                      iconSize: 44,
                      icon: const Icon(Icons.skip_previous),
                      onPressed: player.seekToPrevious,
                    ),
                    const PlayPauseButton(size: 84),
                    IconButton(
                      iconSize: 44,
                      icon: const Icon(Icons.skip_next),
                      onPressed: player.seekToNext,
                    ),
                    StreamBuilder<LoopMode>(
                      stream: player.loopModeStream,
                      builder: (context, s) {
                        final mode = s.data ?? LoopMode.off;
                        return IconButton(
                          iconSize: 30,
                          tooltip: 'Repeat',
                          color: mode == LoopMode.off ? _muted : _accent,
                          icon: Icon(mode == LoopMode.one
                              ? Icons.repeat_one
                              : Icons.repeat),
                          onPressed: () => player.setLoopMode(
                            mode == LoopMode.off
                                ? LoopMode.all
                                : mode == LoopMode.all
                                    ? LoopMode.one
                                    : LoopMode.off,
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Equalizer
// ---------------------------------------------------------------------------
// Each preset is a curve from bass (left) to treble (right), from -1 to 1.
const _presets = <String, List<double>>{
  'Flat': [0, 0, 0, 0, 0],
  'Bass boost': [1, 0.7, 0, 0, 0],
  'Vocal': [-0.3, 0, 0.6, 0.5, 0],
  'Party': [0.8, 0.3, -0.2, 0.4, 0.7],
  'Treble boost': [0, 0, 0, 0.6, 1],
};

double _curveAt(List<double> c, double t) {
  final x = t * (c.length - 1);
  var i = x.floor();
  if (i > c.length - 2) i = c.length - 2;
  final f = x - i;
  return c[i] * (1 - f) + c[i + 1] * f;
}

String _hz(double f) {
  // centerFrequency is reported in Hz.
  if (f >= 1000) {
    final k = f / 1000;
    return '${k.toStringAsFixed(k == k.roundToDouble() ? 0 : 1)} kHz';
  }
  return '${f.round()} Hz';
}

class EqualizerScreen extends StatefulWidget {
  const EqualizerScreen({super.key});

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  AndroidEqualizerParameters? _params;
  String? _error;
  bool _enabled = false;
  double _boost = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p =
          await equalizer.parameters.timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() {
        _params = p;
        _enabled = equalizer.enabled;
        _boost = loudness.targetGain;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Play a song first, then open the equalizer.');
    }
  }

  Future<void> _applyPreset(List<double> curve) async {
    final p = _params!;
    final n = p.bands.length;
    for (var i = 0; i < n; i++) {
      final v = _curveAt(curve, n == 1 ? 0.0 : i / (n - 1)) * 0.8;
      final g = v >= 0 ? v * p.maxDecibels : -v * p.minDecibels;
      await p.bands[i].setGain(g);
    }
    if (!_enabled) {
      await equalizer.setEnabled(true);
      _enabled = true;
    }
    await app.saveEq(p);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = _params;
    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18)),
              ),
            )
          : p == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    SwitchListTile(
                      title: const Text('Equalizer on',
                          style: TextStyle(fontSize: 18)),
                      value: _enabled,
                      onChanged: (v) async {
                        await equalizer.setEnabled(v);
                        await app.saveEq(p);
                        setState(() => _enabled = v);
                      },
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final e in _presets.entries)
                          ActionChip(
                            label: Text(e.key),
                            onPressed: () => _applyPreset(e.value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    for (final band in p.bands)
                      StreamBuilder<double>(
                        stream: band.gainStream,
                        builder: (context, s) {
                          final g = (s.data ?? band.gain)
                              .clamp(p.minDecibels, p.maxDecibels)
                              .toDouble();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(left: 16),
                                child: Text(
                                  '${_hz(band.centerFrequency)}   ${g.toStringAsFixed(1)} dB',
                                  style: const TextStyle(color: _muted),
                                ),
                              ),
                              Slider(
                                value: g,
                                min: p.minDecibels,
                                max: p.maxDecibels,
                                onChanged: _enabled ? band.setGain : null,
                                onChangeEnd: (_) => app.saveEq(p),
                              ),
                            ],
                          );
                        },
                      ),
                    const Divider(height: 32),
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text(
                        'Loudness boost   ${_boost.toStringAsFixed(1)} dB',
                        style: const TextStyle(color: _muted),
                      ),
                    ),
                    Slider(
                      value: _boost,
                      min: 0,
                      max: 6,
                      onChanged: (v) async {
                        setState(() => _boost = v);
                        await loudness.setTargetGain(v);
                        await loudness.setEnabled(v > 0);
                      },
                      onChangeEnd: (_) => app.saveEq(p),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'If the sound starts to crackle, lower the loudness boost.',
                        style: TextStyle(color: _muted),
                      ),
                    ),
                  ],
                ),
    );
  }
}
