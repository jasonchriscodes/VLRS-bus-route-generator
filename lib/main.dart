import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart'; // Import for Clipboard
import 'package:url_launcher/url_launcher.dart';
import 'package:open_file/open_file.dart';
import 'dart:collection';

bool _isRouting = false;
bool _isPanelCollapsed = false;

String _importedContent = '';
List<Polyline> _polylines = [];

List<Marker> _markers = [];

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF47326C);
    final scheme = ColorScheme.fromSeed(seedColor: seed);

    return MaterialApp(
      title: 'Map Viewer',
      theme: ThemeData(
        // keep old compact metrics so layout doesn't shift
        useMaterial3: false,
        colorScheme: scheme,

        // ✅ Only color, not size
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: MaterialStatePropertyAll<Color>(scheme.primary),
            foregroundColor: MaterialStatePropertyAll<Color>(scheme.onPrimary),
            // keep buttons compact like before
            minimumSize: const MaterialStatePropertyAll(Size(0, 36)),
            padding: const MaterialStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ),

        // remove icon/text button themes to avoid affecting your Image.asset icon
        // (leave defaults so layout stays the same)
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final MapController _mapController = MapController();
  final ScrollController _scrollController = ScrollController();
  LatLng _currentLocation = LatLng(-36.8485, 174.7633); // Auckland, New Zealand
  LatLng? _selectedLocation;
  LatLng? _startingLocation;
  String? _currentStreet;
  String? _startingStreet;
  bool _isStartingPointChosen = false;
  List<Map<String, dynamic>> _nextPoints = []; // Store next points and details
  List<List<List<double>>> _routes = []; // Store route coordinates
  List<Map<String, dynamic>> _suggestions = [];
  final TextEditingController _searchController = TextEditingController();
  // Cache: start|end -> {'coordinates': List<List<double>>, 'duration': num}
  final Map<String, Map<String, dynamic>> _routeCache = {};

  static const double _collapsedHeight = 48; // height when collapsed
  static const Duration _panelAnimDur = Duration(milliseconds: 220);
  static const Curve _panelAnimCurve = Curves.easeInOut;

  String _segKey(LatLng a, LatLng b) =>
      '${a.latitude},${a.longitude}|${b.latitude},${b.longitude}';

  T _pick<T>(T a, T b) => a; // tiny helper if you need tuple-like selects later

  // Add a stack to store the history of states
  final List<Map<String, dynamic>> _stateHistory = [];

  void _togglePanel() {
    setState(() => _isPanelCollapsed = !_isPanelCollapsed);
  }

  void _saveState() {
    _stateHistory.add({
      'nextPoints': List.from(_nextPoints),
      'routes': List.from(_routes),
      'markers': List.from(_markers),
      'startingLocation': _startingLocation,
      'startingStreet': _startingStreet,
      'isStartingPointChosen': _isStartingPointChosen,
    });
  }

  void _undo() {
    if (_stateHistory.isNotEmpty) {
      final lastState = _stateHistory.removeLast();
      setState(() {
        _nextPoints = List<Map<String, dynamic>>.from(lastState['nextPoints']);
        _routes = List<List<List<double>>>.from(lastState['routes']);
        _markers = List<Marker>.from(lastState['markers']);
        _startingLocation = lastState['startingLocation'];
        _startingStreet = lastState['startingStreet'];
        _isStartingPointChosen = lastState['isStartingPointChosen'];

        // Rebuild polylines
        _polylines.clear();
        for (final route in _routes) {
          _polylines.add(
            Polyline(
              points: route.map((c) => LatLng(c[1], c[0])).toList(),
              strokeWidth: 4.0,
              color: Colors.blue,
            ),
          );
        }
      });

      _updateRouteFile(); // Update the route file after undo

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Undo successful!')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to undo!')),
      );
    }
  }

  Future<File> _getRouteFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/route.txt');
  }

  Future<void> _initializeRouteFile() async {
    final file = await _getRouteFile();
    if (await file.exists()) {
      _readRouteFile(file);
    } else {
      _writeRouteFile(file); // Create an empty route file if it doesn't exist
    }
  }

  Future<void> _readRouteFile(File file) async {
    try {
      final contents = await file.readAsString();
      print('Route file content:\n$contents');
    } catch (e) {
      print('Error reading route file: $e');
    }
  }

  Future<void> _writeRouteFile(File file) async {
    final String content = _generateRouteFileContent();
    try {
      await file.writeAsString(content);
      print('Route file updated.');
    } catch (e) {
      print('Error writing to route file: $e');
    }
  }

  String _generateRouteFileContent() {
    final List<String> lines = [];

    if (_isStartingPointChosen && _startingLocation != null) {
      lines.add('Starting Point: $_startingLocation ($_startingStreet)');
    }

    for (int i = 0; i < _nextPoints.length; i++) {
      final point = _nextPoints[i];
      final routeCoordinates =
          i < _routes.length ? _toDoublePairList(_routes[i]) : <List<double>>[];

      // Add starting point to the first route segment
      if (i == 0 && _isStartingPointChosen && _startingLocation != null) {
        routeCoordinates.insert(
            0, [_startingLocation!.longitude, _startingLocation!.latitude]);
      }

      // Add ending point to the last route segment
      if (i == _nextPoints.length - 1) {
        routeCoordinates
            .add([point['location'].longitude, point['location'].latitude]);
      }

      final durationMinutes = (point['duration'] ?? 0) / 60;

      lines.add(
          'Next Point: ${point['location']} (${point['street']}) Duration: ${durationMinutes.toStringAsFixed(1)} minutes Route Coordinates: ${routeCoordinates.map((c) => "[${c[0]}, ${c[1]}]").join(", ")}');
    }

    return lines.join('\n');
  }

  Future<void> _updateRouteFile() async {
    final file = await _getRouteFile();
    await _writeRouteFile(file);
  }

  @override
  void initState() {
    super.initState();
    requestStoragePermission();
  }

  void _showExportDialog() {
    final TextEditingController fileNameController =
        TextEditingController(text: 'route.txt');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Export File'),
          content: TextField(
            controller: fileNameController,
            decoration: const InputDecoration(labelText: 'File Name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final fileName = fileNameController.text.isNotEmpty
                    ? fileNameController.text
                    : 'route.txt';
                Navigator.of(context).pop();
                _exportRouteFile(fileName);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> requestStoragePermission() async {
    PermissionStatus status = await Permission.storage.request();

    if (status.isGranted) {
      print("Storage permission granted.");
    } else if (status.isDenied || status.isPermanentlyDenied) {
      print("Storage permission denied.");
    }
  }

  Future<void> testFileWrite(String fileName, String content) async {
    try {
      final directory = await getExternalStorageDirectory();
      if (directory == null)
        throw Exception("External storage directory not available");

      final file = File('${directory.path}/$fileName');
      await file.writeAsString(content);
      print('File written successfully to ${file.path}');
    } catch (e) {
      print('Failed to write file: $e');
    }
  }

  void checkPermissionStatus() async {
    var status = await Permission.storage.status;
    print("Storage permission status: $status");
  }

  Future<void> openAppSettingsIfNeeded() async {
    if (await Permission.storage.isPermanentlyDenied) {
      await openAppSettings();
    }
  }

  Future<File> getFilePath(String fileName) async {
    final directory = await getExternalStorageDirectory();
    final path = directory?.path;
    if (path == null) throw Exception("Storage directory not found");
    return File('$path/$fileName');
  }

  Future<void> _exportRouteFile(String fileName) async {
    try {
      final directory = await _safeExportDir();
      final file = File('${directory.path}/$fileName');
      final content = _generateRouteFileContent();

      await _atomicReplaceWrite(file, content);

      if (!mounted) return;
      setState(() {
        _importedContent = content; // reflect what was saved
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File exported to ${file.path}')),
      );
      print('TXT exported to: ${file.path}');
    } catch (e, st) {
      print('Error exporting TXT: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error exporting file: $e')),
      );
    }
  }

  String _buildRouteJsonString() {
    // Same structure as your existing "Copy" button
    List<Map<String, dynamic>> jsonData = [
      {
        "starting_point": _isStartingPointChosen && _startingLocation != null
            ? {
                "latitude": _startingLocation!.latitude,
                "longitude": _startingLocation!.longitude,
                "address": _startingStreet ?? "Unknown",
              }
            : null,
        "next_points": _nextPoints.asMap().entries.map((entry) {
          int index = entry.key;
          Map<String, dynamic> point = entry.value;
          List<List<double>> routeCoordinates = index < _routes.length
              ? _toDoublePairList(_routes[index])
              : <List<double>>[];

          return {
            "latitude": point["location"].latitude,
            "longitude": point["location"].longitude,
            "address": point["street"],
            "duration": point.containsKey("duration")
                ? "${(point["duration"] / 60).toStringAsFixed(1)} minutes"
                : "N/A",
            "route_coordinates": routeCoordinates,
          };
        }).toList(),
      }
    ];

    // Keep behavior identical to your old copy handler
    jsonData.removeWhere((element) => element["starting_point"] == null);

    return jsonEncode(jsonData);
  }

  Future<void> _exportJsonFile(String fileName) async {
    try {
      final directory = await _safeExportDir();
      final file = File('${directory.path}/$fileName');
      final jsonString = _buildRouteJsonString();

      await _atomicReplaceWrite(file, jsonString);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('JSON exported to ${file.path}')),
      );
    } catch (e, st) {
      print('Error exporting JSON: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error exporting JSON file: $e')),
      );
    }
  }

  void _showExportJsonDialog() {
    final TextEditingController fileNameController =
        TextEditingController(text: 'route.json');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Export JSON'),
          content: TextField(
            controller: fileNameController,
            decoration: const InputDecoration(labelText: 'File Name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final fileName = fileNameController.text.isNotEmpty
                    ? fileNameController.text
                    : 'route.json';
                Navigator.of(context).pop();
                _exportJsonFile(fileName);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _fetchStreetName(LatLng point) async {
    const apiKey = '5b3ce3597851110001cf624804ab2baa18644cc6b65c5829826b6117';
    final url =
        'https://api.openrouteservice.org/geocode/reverse?api_key=$apiKey&point.lat=${point.latitude}&point.lon=${point.longitude}';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final features = (data['features'] as List?) ?? const [];
        final props = features.isNotEmpty
            ? (features[0]['properties'] as Map<String, dynamic>?)
            : null;

        final street = props?['street']?.toString();
        final hn = props?['housenumber']?.toString();
        final label = _formatStreetLabel(street: street, housenumber: hn);

        setState(() => _currentStreet = label);
      } else {
        setState(() => _currentStreet = 'Unknown Street');
      }
    } catch (e) {
      setState(() => _currentStreet = 'Unknown Street');
    }
  }

  Future<Map<String, dynamic>> _fetchRouteCoordinatesWithDuration(
    LatLng start,
    LatLng end, {
    int retries = 2,
  }) async {
    final url = 'https://api.openrouteservice.org/v2/directions/driving-car'
        '?api_key=5b3ce3597851110001cf624804ab2baa18644cc6b65c5829826b6117'
        '&start=${start.longitude},${start.latitude}'
        '&end=${end.longitude},${end.latitude}'
        '&format=geojson';

    int attempt = 0;
    while (true) {
      attempt++;
      try {
        final resp = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 15)); // ⏱️ timeout

        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          final feats = (data['features'] as List?) ?? const [];
          if (feats.isEmpty) throw Exception('No features in response');

          final coords = (feats[0]['geometry']['coordinates'] as List)
              .map<List<double>>((c) => [c[0] as double, c[1] as double])
              .toList();

          final duration = feats[0]['properties']['segments'][0]['duration'];
          return {'coordinates': coords, 'duration': duration};
        } else if (resp.statusCode == 429) {
          // Rate limited → brief backoff
          await Future.delayed(const Duration(milliseconds: 600));
        } else {
          throw Exception('HTTP ${resp.statusCode}');
        }
      } catch (e) {
        if (attempt > retries) {
          // give up
          return {'coordinates': <List<double>>[], 'duration': 0};
        }
        // linear backoff
        await Future.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
  }

  Future<void> _rebuildAllSegments() async {
    if (!_isStartingPointChosen || _startingLocation == null) return;

    _ensureRoutesCapacity();

    // local working copies to avoid setState spam
    final List<List<List<double>>> newRoutes =
        List.generate(_nextPoints.length, (_) => <List<double>>[]);
    final List<dynamic> newDurations =
        List.filled(_nextPoints.length, 0, growable: false);

    // Build the list of segments we need
    final List<({int idx, LatLng start, LatLng end})> segments = [];
    for (int i = 0; i < _nextPoints.length; i++) {
      final LatLng start = (i == 0)
          ? _startingLocation!
          : _nextPoints[i - 1]['location'] as LatLng;
      final LatLng end = _nextPoints[i]['location'] as LatLng;
      segments.add((idx: i, start: start, end: end));
    }

    // Process in small batches (concurrency = 2)
    const int kBatch = 2;
    for (int offset = 0; offset < segments.length; offset += kBatch) {
      final batch = segments.sublist(
        offset,
        (offset + kBatch > segments.length) ? segments.length : offset + kBatch,
      );

      // Start all in the batch
      final futures = batch.map((seg) async {
        final key = _segKey(seg.start, seg.end);

        Map<String, dynamic>? result = _routeCache[key];
        if (result == null) {
          result = await _fetchRouteCoordinatesWithDuration(seg.start, seg.end);
          _routeCache[key] = result; // cache it
        }

// ---- NEW: make it non-null + null-safe field reads
        final Map<String, dynamic> r = result!;
        final coords =
            _toDoublePairList(r['coordinates'] ?? const <List<double>>[]);
        final duration = (r['duration'] as num?) ?? 0;

        if (seg.idx == 0) {
          coords.insert(0, [seg.start.longitude, seg.start.latitude]);
        }
        if (seg.idx == segments.length - 1) {
          coords.add([seg.end.longitude, seg.end.latitude]);
        }

        newRoutes[seg.idx] = coords;
        newDurations[seg.idx] = duration;
      }).toList();

      // Wait this batch
      await Future.wait(futures);

      // Gentle pause to avoid bursting
      await Future.delayed(const Duration(milliseconds: 50));
    }

    // Single UI update + polyline rebuild + file write
    setState(() {
      _routes = newRoutes;
      for (int i = 0; i < _nextPoints.length; i++) {
        _nextPoints[i]['duration'] = newDurations[i];
      }
      _rebuildPolylines();
    });

// Kick off file write without blocking the UI spinner.
    Future.microtask(_updateRouteFile);
  }

  Future<void> _fetchSuggestions(String query) async {
    if (query.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }

    // If it's lat,lon, just pan the map & clear suggestions (don’t change the text)
    if (_isLatLonText(query)) {
      final loc = _parseLatLon(query)!;
      setState(() {
        _selectedLocation = loc;
        _suggestions = [];
      });
      _mapController.move(loc, 16);
      return;
    }

    // ... keep your TomTom logic below unchanged
    const String apiKey = '7Lz8icqmjz4UvEALltZQALkwdQrVo2TO';
    final String url =
        'https://api.tomtom.com/search/2/search/$query.json?key=$apiKey&limit=5';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _suggestions = (data['results'] as List)
              .map((result) => {
                    'label': result['address']['freeformAddress'],
                    'coordinates': [
                      result['position']['lon'],
                      result['position']['lat']
                    ],
                  })
              .toList();
        });
      } else {
        setState(() {
          _suggestions = [];
          if (!_isLatLonText(query)) {
            _selectedLocation = null; // avoid reusing old selection
            _currentStreet = null;
          }
        });
      }
    } catch (e) {
      setState(() {
        _suggestions = [];
        if (!_isLatLonText(query)) {
          _selectedLocation = null;
          _currentStreet = null;
        }
      });
    }
  }

  void _selectSuggestion(Map<String, dynamic> suggestion) async {
    final List coords = suggestion['coordinates'];
    final double lon = coords[0];
    final double lat = coords[1];
    final LatLng location = LatLng(lat, lon);

    setState(() {
      _selectedLocation = location;
      _searchController.text = suggestion['label'];
      _currentStreet = suggestion['label']; // optimistic label
      _suggestions = [];
    });

    // refine with reverse geocode (will keep nice format / house number)
    await _fetchStreetName(location);

    _mapController.move(_selectedLocation!, 16);
  }

  void _choosePoint() {
    if (_selectedLocation == null) return;

    setState(() {
      _saveState(); // Save the current state for undo

      if (!_isStartingPointChosen) {
        _startingLocation = _selectedLocation;
        _startingStreet = _currentStreet;
        _isStartingPointChosen = true;

        _markers.add(Marker(
          width: 40,
          height: 40,
          point: _startingLocation!,
          child: const Icon(Icons.circle, color: Colors.red, size: 10),
        ));

        _selectedLocation = null;
        _currentStreet = null;
        _suggestions = [];
        _searchController.clear();
      } else {
        final LatLng chosen = _selectedLocation!;
        final String street = _currentStreet ?? 'Unknown Street';

        _saveState();

        _nextPoints.add({'location': chosen, 'street': street});

        _markers.add(Marker(
          width: 40,
          height: 40,
          point: chosen,
          child: const Icon(Icons.circle, color: Colors.red, size: 10),
        ));

        // clear transient selection
        _selectedLocation = null;
        _currentStreet = null;
        _searchController.clear();
        _suggestions = [];
      }
    });

    _updateRouteFile();
  }

  Future<void> _importFile() async {
    try {
      setState(() {
        _polylines.clear();
        _nextPoints.clear();
        _routes.clear();
        _markers.clear();
        _isStartingPointChosen = false;
        _startingLocation = null;
        _startingStreet = null;
      });

      // Open file picker to select the text file
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );

      if (result != null) {
        final filePath = result.files.single.path!;
        final file = File(filePath);

        // Read the content of the file
        final content = await file.readAsString();
        setState(() {
          _importedContent = content;
        });

        // Parse the imported content
        final lines = content.split('\n');
        LatLng? startingPoint;
        String? startingStreet;
        List<Map<String, dynamic>> parsedNextPoints = [];
        List<List<List<double>>> parsedRoutes = [];

        for (var line in lines) {
          if (line.startsWith('Starting Point:')) {
            final regex = RegExp(
                r'Starting Point: LatLng\(latitude:(.*?), longitude:(.*?)\) \((.*?)\)');
            final match = regex.firstMatch(line);
            if (match != null) {
              startingPoint = LatLng(
                double.parse(match.group(1)!),
                double.parse(match.group(2)!),
              );
              startingStreet = match.group(3);
            }
          } else if (line.startsWith('Next Point:')) {
            final regex = RegExp(
                r'Next Point: LatLng\(latitude:(.*?), longitude:(.*?)\) \((.*?)\) Duration: (.*?) minutes Route Coordinates: (.*?)$');
            final match = regex.firstMatch(line);
            if (match != null) {
              final point = LatLng(
                double.parse(match.group(1)!),
                double.parse(match.group(2)!),
              );
              final street = match.group(3);
              final duration =
                  double.parse(match.group(4)!) * 60; // Convert to seconds
              final routeCoordinatesString = match.group(5);

              // Parse route coordinates
              final coordinatesRegex = RegExp(r'\[(.*?),(.*?)\]');
              final routeCoordinates = coordinatesRegex
                  .allMatches(routeCoordinatesString!)
                  .map((m) => [
                        double.parse(m.group(1)!),
                        double.parse(m.group(2)!),
                      ])
                  .toList();

              parsedNextPoints.add({
                'location': point,
                'street': street,
                'duration': duration,
              });
              parsedRoutes.add(routeCoordinates);
            }
          }
        }

        // Update the map state
        setState(() {
          _saveState(); // Save current state for undo

          if (startingPoint != null) {
            _isStartingPointChosen = true;
            _startingLocation = startingPoint;
            _startingStreet = startingStreet;

            // Add marker for starting point
            _markers.add(
              Marker(
                width: 40,
                height: 40,
                point: startingPoint,
                child: const Icon(
                  Icons.circle,
                  color: Colors.red,
                  size: 10,
                ),
              ),
            );
          }

          for (int i = 0; i < parsedNextPoints.length; i++) {
            final nextPoint = parsedNextPoints[i];
            _nextPoints.add(nextPoint);

            // Add marker for each next point
            _markers.add(
              Marker(
                width: 40,
                height: 40,
                point: nextPoint['location'],
                child: const Icon(
                  Icons.circle,
                  color: Colors.red,
                  size: 10,
                ),
              ),
            );

            // Add route coordinates to the polyline
            if (i < parsedRoutes.length) {
              final routeCoordinates = _toDoublePairList(parsedRoutes[i]);
              _routes.add(routeCoordinates);
              _polylines.add(
                Polyline(
                  points:
                      routeCoordinates.map((c) => LatLng(c[1], c[0])).toList(),
                  strokeWidth: 4.0,
                  color: Colors.blue,
                ),
              );
            }
          }
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File imported successfully!')),
        );
      } else {
        print('No file selected');
      }
    } catch (e) {
      print('Error importing file: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error importing file')),
      );
    }
  }

  void makeRoutePolyline() {
    try {
      print('Making route polyline');

      // List to hold LatLng points for the polyline
      final List<LatLng> polylinePoints = [];

      // Extract Route Coordinates from _routes
      for (final routeCoordinates in _routes) {
        for (final coordinate in routeCoordinates) {
          if (coordinate.length == 2) {
            polylinePoints.add(LatLng(coordinate[1], coordinate[0]));
          }
        }
      }

      // Extract Route Coordinates from _importedContent
      final routeRegex =
          RegExp(r'Route Coordinates:\s*(\[.*?\](?:, \[.*?\])*)');
      final matches = routeRegex.allMatches(_importedContent);
      for (final match in matches) {
        final rawCoordinates = match.group(1);
        if (rawCoordinates != null) {
          final coordinateRegex = RegExp(r'\[(.*?),(.*?)\]');
          for (final coordinateMatch
              in coordinateRegex.allMatches(rawCoordinates)) {
            final latitude = double.parse(coordinateMatch.group(2)!);
            final longitude = double.parse(coordinateMatch.group(1)!);
            polylinePoints.add(LatLng(latitude, longitude));
          }
        }
      }

      if (polylinePoints.isNotEmpty) {
        setState(() {
          _polylines = [
            Polyline(
              points: polylinePoints,
              strokeWidth: 4.0,
              color: Colors.blue,
            ),
          ];
        });
        print('Polyline added with points: $polylinePoints');
      } else {
        print('No coordinates found to create polyline.');
      }
    } catch (e) {
      print('Error creating polyline: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error creating polyline: ${e.toString()}')),
      );
    }
  }

  void backToStart() {
    if (_startingLocation != null) {
      setState(() {
        _selectedLocation = _startingLocation;
        _currentStreet = _startingStreet;
        _mapController.move(_startingLocation!, 16); // Zoom level 16

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Moved to starting point! Selected location updated.')),
        );
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Starting point is not set!')),
      );
    }
  }

  void _deleteRoutes() {
    setState(() {
      // Clear all data structures and reset state variables
      _polylines.clear();
      _nextPoints.clear();
      _routes.clear();
      _markers.clear();

      // Reset flags and other related state
      _isStartingPointChosen = false;
      _startingLocation = null;
      _startingStreet = null;
      _selectedLocation = null;
      _currentStreet = null;
      _importedContent = '';

      // Reset the route file to ensure persistence
      _updateRouteFile();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content:
              Text('All routes, points, and descriptions have been cleared!')),
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content:
              Text('All routes, points, and descriptions have been cleared!')),
    );
  }

  Future<void> _openPDF() async {
    try {
      // Load PDF from assets
      final ByteData data =
          await rootBundle.load('assets/how-to-create-route.pdf');

      // Write the PDF to a temporary file
      final Directory tempDir = await getTemporaryDirectory();
      final File tempFile = File('${tempDir.path}/how-to-create-route.pdf');
      await tempFile.writeAsBytes(data.buffer.asUint8List());

      // Open the PDF file
      OpenFile.open(tempFile.path);
    } catch (e) {
      // Handle error gracefully
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the PDF file: $e')),
      );
    }
  }

  @override
  @override
  Widget build(BuildContext context) {
    final double sectionHeight = MediaQuery.of(context).size.height * 0.3;
    final double panelHeight =
        _isPanelCollapsed ? _collapsedHeight : sectionHeight;

    return Scaffold(
      appBar: AppBar(title: const Text('Map Viewer')),
      body: Column(
        children: [
          // Search bar row -----------------------------------------------------
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Flexible(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      labelText: 'Search for a location',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          setState(() {
                            _searchController.clear();
                            _suggestions = [];
                          });
                        },
                      ),
                    ),
                    onChanged: _fetchSuggestions,
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  children: [
                    CustomButton(
                      expanded: false,
                      label: _isStartingPointChosen
                          ? 'Choose Next Point'
                          : 'Choose Starting Point',
                      loading: _isRouting,
                      onTap: _isRouting ? null : _handleChooseTapped,
                    ),
                    const SizedBox(width: 10),
                    IconButton(
                      icon: Image.asset('assets/question.png'),
                      iconSize: 40.0,
                      onPressed: _openPDF,
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Suggestions list ---------------------------------------------------
          if (_suggestions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _suggestions.length,
                itemBuilder: (context, index) {
                  final suggestion = _suggestions[index];
                  return ListTile(
                    title: Text(suggestion['label']),
                    onTap: () => _selectSuggestion(suggestion),
                  );
                },
              ),
            ),

          // Map ---------------------------------------------------------------
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                center: _currentLocation,
                zoom: 14,
                onTap: (tapPosition, point) {
                  setState(() {
                    _selectedLocation = point;
                    _currentStreet = null;
                  });
                  _fetchStreetName(point);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  panBuffer: 0,
                  userAgentPackageName: 'com.jason.publisher',
                  tileProvider: NetworkTileProvider(
                    headers: Map<String, String>.from({
                      'User-Agent':
                          'BusFlow-Personal/0.1 (+mailto:vlrs13542@gmail.com)',
                    }),
                  ),
                ),
                PolylineLayer(polylines: _polylines),
                MarkerLayer(markers: _markers),
                if (_selectedLocation != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        width: 40,
                        height: 40,
                        point: _selectedLocation!,
                        child: Transform.translate(
                          offset: const Offset(0, -20),
                          child: Image.asset(
                            'assets/location-pin.png',
                            width: 40,
                            height: 40,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
              nonRotatedChildren: const [
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution(
                      'OpenStreetMap contributors',
                      prependCopyright: true,
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Bottom panel (collapsible) ----------------------------------------
          AnimatedContainer(
            duration: _panelAnimDur,
            curve: _panelAnimCurve,
            height: panelHeight,
            width: double.infinity,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Panel body
                Material(
                  elevation: 4,
                  color: Colors.white,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // LEFT: details
                      Expanded(
                        child: Container(
                          height: double.infinity,
                          color: Colors.white,
                          child: Scrollbar(
                            thumbVisibility: true,
                            controller: _scrollController,
                            child: SingleChildScrollView(
                              controller: _scrollController,
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (!_isPanelCollapsed) ...[
                                    if (_selectedLocation != null) ...[
                                      const Text(
                                        'Selected Location:',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        'Latitude: ${_selectedLocation!.latitude}, Longitude: ${_selectedLocation!.longitude}',
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                      Text(
                                        'Street Name: ${_currentStreet ?? "Fetching..."}',
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ] else if (_startingLocation == null) ...[
                                      const Text(
                                        'Tap on the map to select a location or import data.',
                                        style: TextStyle(fontSize: 14),
                                      ),
                                    ],
                                    if (_isStartingPointChosen &&
                                        _startingLocation != null) ...[
                                      const SizedBox(height: 10),
                                      const Text(
                                        'Starting Point is chosen:',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '$_startingLocation at $_startingStreet',
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ],
                                    if (_nextPoints.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      const Text(
                                        'Next Points:',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      ..._nextPoints
                                          .asMap()
                                          .entries
                                          .map((entry) {
                                        final int index = entry.key;
                                        final Map<String, dynamic> point =
                                            entry.value;
                                        final routeCoordinates =
                                            index < _routes.length
                                                ? _routes[index]
                                                : <List<double>>[];
                                        final durationMinutes =
                                            (point['duration'] ?? 0) / 60;
                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Next Point: ${point['location']} at ${point['street']}',
                                              style:
                                                  const TextStyle(fontSize: 14),
                                            ),
                                            Text(
                                              'Duration: ${durationMinutes.toStringAsFixed(1)} minutes',
                                              style: const TextStyle(
                                                fontSize: 14,
                                                color: Colors.black,
                                              ),
                                            ),
                                            if (routeCoordinates.isNotEmpty)
                                              Text(
                                                'Route Coordinates: ${routeCoordinates.map((c) => "[${c[0]}, ${c[1]}]").join(", ")}',
                                                style: const TextStyle(
                                                    fontSize: 12),
                                              ),
                                            const SizedBox(height: 8),
                                          ],
                                        );
                                      }).toList(),
                                    ],
                                    if (_importedContent.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      const Text(
                                        'Imported Data:',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Container(
                                        height: 200,
                                        decoration: BoxDecoration(
                                          border:
                                              Border.all(color: Colors.grey),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Scrollbar(
                                          thumbVisibility: true,
                                          child: SingleChildScrollView(
                                            controller: _scrollController,
                                            padding: const EdgeInsets.all(8),
                                            child: Text(
                                              _importedContent,
                                              style:
                                                  const TextStyle(fontSize: 14),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      // RIGHT: actions  ------------------------------------------------------------
                      AnimatedCrossFade(
                        duration: _panelAnimDur,
                        sizeCurve: _panelAnimCurve,
                        crossFadeState: _isPanelCollapsed
                            ? CrossFadeState.showSecond
                            : CrossFadeState.showFirst,
                        firstChild: Container(
                          width: 260,
                          color: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // Row 1
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(width: 10),
                                  CustomButton(
                                    label: 'Import',
                                    onTap: _importFile,
                                    leading: const Icon(Icons.file_open),
                                  ),
                                  const SizedBox(width: 10),
                                  CustomButton(
                                    label: 'Undo',
                                    onTap: _undo,
                                    leading: const Icon(Icons.undo),
                                  ),
                                  const SizedBox(width: 10),
                                  CustomButton(
                                    label: 'Refresh Routes',
                                    loading: _isRouting,
                                    onTap: _isRouting ? null : _onRefreshRoutes,
                                    leading: const Icon(Icons.refresh),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              // Row 2
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  CustomButton(
                                    label: 'Delete Routes',
                                    onTap: _deleteRoutes,
                                    leading: const Icon(Icons.delete_outline),
                                  ),
                                  const SizedBox(width: 10),
                                  CustomButton(
                                    label: 'Export txt',
                                    onTap:
                                        _isRouting ? null : _showExportDialog,
                                    leading: const Icon(Icons.save_alt),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              // Row 3
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  CustomButton(
                                    label: 'Back To Start',
                                    onTap: backToStart,
                                    leading: const Icon(Icons.undo_rounded),
                                  ),
                                  const SizedBox(width: 10),
                                  CustomButton(
                                    label: 'Export JSON',
                                    onTap: _isRouting
                                        ? null
                                        : _showExportJsonDialog,
                                    leading: const Icon(Icons.data_object),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        secondChild:
                            const SizedBox.shrink(), // hidden when collapsed
                      ),
                    ],
                  ),
                ),

                // Handle (expand/collapse)
                Positioned(
                  top: -16,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: _togglePanel,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: const [
                            BoxShadow(
                              blurRadius: 8,
                              color: Colors.black26,
                              offset: Offset(0, 2),
                            ),
                          ],
                          border: Border.all(color: Colors.black12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_isPanelCollapsed
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down),
                            const SizedBox(width: 6),
                            Text(_isPanelCollapsed ? 'Expand' : 'Collapse'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _isLatLonText(String s) {
    final coordinateRegex =
        RegExp(r'^\s*(-?\d+(\.\d+)?)\s*,\s*(-?\d+(\.\d+)?)\s*$');
    return coordinateRegex.hasMatch(s);
  }

  LatLng? _parseLatLon(String s) {
    final m =
        RegExp(r'^\s*(-?\d+(\.\d+)?)\s*,\s*(-?\d+(\.\d+)?)\s*$').firstMatch(s);
    if (m == null) return null;
    final lat = double.parse(m.group(1)!);
    final lon = double.parse(m.group(3)!);
    return LatLng(lat, lon);
  }

// Normalizes "street" + "housenumber" (avoids "N/A Unknown Street")
  String _formatStreetLabel({String? street, String? housenumber}) {
    final s = (street ?? '').trim();
    final h = (housenumber ?? '').trim();
    if (s.isEmpty) return 'Unknown Street';
    if (h.isEmpty || h.toUpperCase() == 'N/A') return s;
    return '$h $s';
  }

// Ask for latitude & longitude when user typed a name without picking a suggestion
  Future<LatLng?> _promptForLatLon({required String title}) async {
    final latCtl = TextEditingController();
    final lonCtl = TextEditingController();

    return showDialog<LatLng?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: latCtl,
              keyboardType:
                  TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration:
                  const InputDecoration(labelText: 'Latitude (e.g. -36.78008)'),
            ),
            TextField(
              controller: lonCtl,
              keyboardType:
                  TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(
                  labelText: 'Longitude (e.g. 174.99199)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              try {
                final lat = double.parse(latCtl.text.trim());
                final lon = double.parse(lonCtl.text.trim());
                Navigator.pop(ctx, LatLng(lat, lon));
              } catch (_) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Please enter valid numbers for lat/lon')),
                );
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

// Ask for a street/place name when user typed lat,lon without a suggestion
  Future<String?> _promptForStreetName(
      {required String title, String? prefill}) async {
    final nameCtl = TextEditingController(text: prefill ?? '');
    return showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: nameCtl,
          decoration: const InputDecoration(labelText: 'Street / Place name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(
                ctx, nameCtl.text.trim().isEmpty ? null : nameCtl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool> _ensureSelectedLocationAndStreetFromInput() async {
    final input = _searchController.text.trim();

// If selection equals the last committed point and the user typed a new name (not lat,lon),
// treat as no selection so we prompt for lat/lon (or street) properly.
    if (_selectedLocation != null &&
        input.isNotEmpty &&
        !_isLatLonText(input)) {
      final LatLng? lastCommitted = _nextPoints.isNotEmpty
          ? _nextPoints.last['location'] as LatLng
          : _startingLocation;
      if (lastCommitted != null && _selectedLocation == lastCommitted) {
        setState(() {
          _selectedLocation = null;
          _currentStreet = null;
        });
      }
    }

    // If user tapped the map / chose a suggestion but street is still empty/unknown,
    // ask for a street/place to avoid writing "Unknown Street".
    bool _needsStreetPrompt(String? s) {
      if (s == null) return true;
      final v = s.trim().toLowerCase();
      return v.isEmpty ||
          v == 'unknown street' ||
          v.startsWith('error fetching') ||
          v.startsWith('fetching...');
    }

    // Case 0: already have coordinates (map tap or suggestion)
    if (_selectedLocation != null) {
      if (_needsStreetPrompt(_currentStreet)) {
        final name =
            await _promptForStreetName(title: 'Enter Street / Place Name');
        if (name == null) return false;
        setState(() => _currentStreet = name);
      }
      return true;
    }

    // Case A: user typed lat,lon
    if (_isLatLonText(input)) {
      final coords = _parseLatLon(input)!;
      final name =
          await _promptForStreetName(title: 'Enter Street / Place Name');
      if (name == null) return false;

      setState(() {
        _selectedLocation = coords;
        _currentStreet = name;
        _mapController.move(coords, 16);
      });
      return true;
    }

    // Case B: user typed a name (no suggestion selected)
    if (input.isNotEmpty) {
      final coords = await _promptForLatLon(
          title: 'Enter Latitude & Longitude for "$input"');
      if (coords == null) return false;

      setState(() {
        _selectedLocation = coords;
        _currentStreet = input; // use typed name as label
        _mapController.move(coords, 16);
      });
      return true;
    }

    // Nothing usable
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text(
              'Type a name or "lat,lon", pick a suggestion, or tap the map.')),
    );
    return false;
  }

  Future<void> _handleChooseTapped() async {
    if (_isRouting) return;
    final ok = await _ensureSelectedLocationAndStreetFromInput();
    if (!ok) return;

    setState(() => _isRouting = true);
    try {
      _choosePoint(); // commit starting point or next point
      if (_isStartingPointChosen && _nextPoints.isNotEmpty) {
        // only fetch the newest leg
        await _addLastSegmentRoute();
      }
    } finally {
      if (!mounted) return;
      setState(() => _isRouting = false);
    }
  }

  Future<void> _onRefreshRoutes() async {
    if (!_isStartingPointChosen ||
        _startingLocation == null ||
        _nextPoints.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Nothing to refresh. Add a starting point and at least one next point.')),
      );
      return;
    }

    setState(() {
      _isRouting = true;
      _routeCache.clear();
    });

    try {
      await _rebuildAllSegments(); // <— renamed from _addRouteCoordinates()
      setState(() {
        _importedContent = _generateRouteFileContent();
      });
    } catch (e, st) {
      print('Refresh failed: $e\n$st');
    } finally {
      if (!mounted) return;
      setState(() => _isRouting = false);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Routes refreshed.')),
      );
    }
  }

  bool _isSegmentValid(List<List<double>> seg) =>
      seg.isNotEmpty && seg.length >= 2;

  void _ensureRoutesCapacity() {
    final need = _nextPoints.length;
    if (_routes.length != need) {
      _routes = List.generate(need, (_) => <List<double>>[]);
    }
  }

  void _rebuildPolylines() {
    _polylines.clear();
    for (final seg in _routes) {
      if (_isSegmentValid(seg)) {
        _polylines.add(
          Polyline(
            points: seg.map((c) => LatLng(c[1], c[0])).toList(),
            strokeWidth: 4.0,
            color: Colors.blue,
          ),
        );
      }
    }
  }

  Future<Directory> _safeExportDir() async {
    final dir = Directory('/storage/emulated/0/Documents');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _atomicReplaceWrite(File target, String content) async {
    // 1) delete old file if it exists
    if (await target.exists()) {
      try {
        await target.delete();
      } catch (e) {
        // if delete fails, bubble up so caller can show a toast
        rethrow;
      }
    }

    // 2) write to temp then rename (atomic-ish)
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, encoding: utf8, flush: true);
    // On Android this is effectively a move in the same filesystem
    await tmp.rename(target.path);

    return target;
  }

  List<List<double>> _toDoublePairList(dynamic v) {
    if (v is List) {
      return v.map<List<double>>((p) {
        final a = p as List;
        final x = (a[0] as num).toDouble();
        final y = (a[1] as num).toDouble();
        return <double>[x, y];
      }).toList();
    }
    return <List<double>>[];
  }

  Future<void> _addLastSegmentRoute() async {
    if (!_isStartingPointChosen ||
        _startingLocation == null ||
        _nextPoints.isEmpty) return;

    final int i = _nextPoints.length - 1;
    final LatLng start = (i == 0)
        ? _startingLocation!
        : _nextPoints[i - 1]['location'] as LatLng;
    final LatLng end = _nextPoints[i]['location'] as LatLng;

    // cache lookup
    final key = _segKey(start, end);
    Map<String, dynamic>? result = _routeCache[key];
    result ??= await _fetchRouteCoordinatesWithDuration(start, end);
    _routeCache[key] = result;

    // ---- NEW: make it non-null + null-safe field reads
    final Map<String, dynamic> r = result!;
    final coords =
        _toDoublePairList(r['coordinates'] ?? const <List<double>>[]);
    final duration = (r['duration'] as num?) ?? 0;

    // ensure the segment explicitly starts/ends at the chosen points
    if (i == 0) {
      coords.insert(0, [start.longitude, start.latitude]);
    }
    // always end at this last point
    if (coords.isEmpty ||
        coords.last[0] != end.longitude ||
        coords.last[1] != end.latitude) {
      coords.add([end.longitude, end.latitude]);
    }

    // extend internal arrays if needed
    if (_routes.length < _nextPoints.length) {
      _routes.addAll(List.generate(
          _nextPoints.length - _routes.length, (_) => <List<double>>[]));
    }

    setState(() {
      _routes[i] = coords;
      _nextPoints[i]['duration'] = duration;

      // append a new polyline for this last segment only
      _polylines.add(Polyline(
        points: coords.map((c) => LatLng(c[1], c[0])).toList(),
        strokeWidth: 4.0,
        color: Colors.blue,
      ));
    });

    // persist to file (non-blocking UI)
    Future.microtask(_updateRouteFile);
  }
}

// --- CustomButton ------------------------------------------------------------
class CustomButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool loading;
  final bool expanded;
  final EdgeInsets padding;
  final double minHeight;
  final double borderRadius;
  final Color? color; // background
  final Color? textColor; // label
  final Widget? leading; // optional leading icon

  const CustomButton({
    super.key,
    required this.label,
    required this.onTap,
    this.loading = false,
    this.expanded = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.minHeight = 36,
    this.borderRadius = 10,
    this.color,
    this.textColor,
    this.leading,
  });

  @override
  State<CustomButton> createState() => _CustomButtonState();
}

class _CustomButtonState extends State<CustomButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null && !widget.loading;

    final bg =
        widget.color ?? (enabled ? scheme.primary : scheme.surfaceVariant);
    final fg = widget.textColor ??
        (enabled ? scheme.onPrimary : scheme.onSurfaceVariant);

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.loading)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(fg)),
          )
        else if (widget.leading != null) ...[
          Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconTheme(
                  data: IconThemeData(size: 18, color: fg),
                  child: widget.leading!)),
        ],
        Flexible(
          child: Text(
            widget.label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: .2,
            ),
          ),
        ),
      ],
    );

    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: widget.padding,
      constraints: BoxConstraints(minHeight: widget.minHeight),
      decoration: BoxDecoration(
        color: bg.withOpacity(_pressed ? 0.92 : 1),
        borderRadius: BorderRadius.circular(widget.borderRadius),
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : [],
        border: Border.all(
          color: enabled ? scheme.primary : scheme.outlineVariant,
          width: 1,
        ),
      ),
      child: content,
    );

    final tappable = GestureDetector(
      onTapDown: (_) {
        if (enabled) setState(() => _pressed = true);
      },
      onTapCancel: () {
        if (_pressed) setState(() => _pressed = false);
      },
      onTapUp: (_) {
        if (_pressed) setState(() => _pressed = false);
      },
      onTap: enabled ? widget.onTap : null,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 80),
        scale: _pressed ? 0.98 : 1.0,
        child: child,
      ),
    );

    return widget.expanded
        ? SizedBox(width: double.infinity, child: tappable)
        : tappable;
  }
}
