import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Map Viewer',
      theme: ThemeData(primarySwatch: Colors.blue),
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
      final routeCoordinates = i < _routes.length ? _routes[i] : [];
      lines.add(
          'Next Point: ${point['location']} (${point['street']}) Route: ${routeCoordinates.map((c) => "[${c[0]}, ${c[1]}]").join(', ')}');
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
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final fileName = fileNameController.text.isEmpty
                    ? 'route.txt'
                    : fileNameController.text;
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
      // Inform the user and optionally navigate to app settings
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Storage permission is required to save the file.')),
      );
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
      // Use scoped storage for Android 11+
      final directory = Directory('/storage/emulated/0/Documents');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final file = File('${directory.path}/$fileName');
      final String content = _generateRouteFileContent();

      await file.writeAsString(content);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File exported to ${file.path}')),
      );
    } catch (e) {
      print('Error exporting file: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error exporting file')),
      );
    }
  }

  Future<void> _fetchStreetName(LatLng point) async {
    const String apiKey =
        '5b3ce3597851110001cf624804ab2baa18644cc6b65c5829826b6117';
    final String url =
        'https://api.openrouteservice.org/geocode/reverse?api_key=$apiKey&point.lat=${point.latitude}&point.lon=${point.longitude}';

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _currentStreet = data['features'][0]['properties']['street'] ??
              'Street name not available';
        });
      } else {
        setState(() {
          _currentStreet = 'Error retrieving street name';
        });
      }
    } catch (e) {
      setState(() {
        _currentStreet = 'Error retrieving street name';
      });
    }
  }

  Future<List<List<double>>> _fetchRouteCoordinates(
      LatLng start, LatLng end) async {
    final String url =
        'http://43.226.218.99:8080/ors/v2/directions/driving-car?start=${start.longitude},${start.latitude}&end=${end.longitude},${end.latitude}&format=geojson';

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final coordinates =
            (data['features'][0]['geometry']['coordinates'] as List)
                .map<List<double>>(
                    (coord) => [coord[0] as double, coord[1] as double])
                .toList();
        return coordinates;
      } else {
        print('Error fetching route: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Error fetching route: $e');
      return [];
    }
  }

  Future<void> _addRouteCoordinates() async {
    if (_isStartingPointChosen && _startingLocation != null) {
      _routes.clear(); // Clear previous routes to avoid duplication
      for (int i = 0; i < _nextPoints.length; i++) {
        LatLng start = i == 0
            ? _startingLocation!
            : _nextPoints[i - 1]['location'] as LatLng;
        LatLng end = _nextPoints[i]['location'] as LatLng;
        final coordinates = await _fetchRouteCoordinates(start, end);
        setState(() {
          _routes.add(coordinates);
        });
      }
      _updateRouteFile(); // Update the file when route coordinates are added
    }
  }

  Future<void> _fetchSuggestions(String query) async {
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
      });
      return;
    }

    const String apiKey =
        '5b3ce3597851110001cf624804ab2baa18644cc6b65c5829826b6117';
    final String url =
        'https://api.openrouteservice.org/geocode/search?api_key=$apiKey&text=$query&size=5';

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _suggestions = (data['features'] as List)
              .map((feature) => {
                    'label': feature['properties']['label'] as String,
                    'coordinates': feature['geometry']['coordinates'] as List
                  })
              .toList();
        });
      } else {
        setState(() {
          _suggestions = [];
        });
      }
    } catch (e) {
      setState(() {
        _suggestions = [];
      });
      print('Error fetching suggestions: $e');
    }
  }

  void _selectSuggestion(Map<String, dynamic> suggestion) {
    final List coordinates = suggestion['coordinates'];
    final double lon = coordinates[0];
    final double lat = coordinates[1];

    setState(() {
      _selectedLocation = LatLng(lat, lon);
      _searchController.text = suggestion['label'];
      _suggestions = [];
    });

    // Move the map to the selected location and zoom in
    _mapController.move(_selectedLocation!, 16); // Zoom level 16
  }

  void _choosePoint() {
    if (_selectedLocation != null) {
      setState(() {
        if (!_isStartingPointChosen) {
          // Set starting point
          _startingLocation = _selectedLocation;
          _startingStreet = _currentStreet;
          _isStartingPointChosen = true;
        } else {
          // Add next point
          _nextPoints.add({
            'location': _selectedLocation!,
            'street': _currentStreet ?? 'Unknown Street',
          });
        }
      });
      _updateRouteFile(); // Update route file
    }
  }

  @override
  Widget build(BuildContext context) {
    final double sectionHeight =
        MediaQuery.of(context).size.height * 0.1; // Adjust section height

    return Scaffold(
      appBar: AppBar(title: const Text('Map Viewer')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Flexible(
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: 'Search for a location',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => _fetchSuggestions(value),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: () {
                    _choosePoint();
                    _addRouteCoordinates();
                  },
                  child: Text(_isStartingPointChosen
                      ? 'Choose Next Point'
                      : 'Choose Starting Point'),
                ),
              ],
            ),
          ),
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
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                center: _currentLocation,
                zoom: 14,
                onTap: (tapPosition, point) {
                  setState(() {
                    _selectedLocation = point;
                    _currentStreet = null; // Reset street name
                  });
                  _fetchStreetName(point);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.app',
                ),
                if (_selectedLocation != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        width: 40,
                        height: 40,
                        point: _selectedLocation!,
                        child: Transform.translate(
                          offset: const Offset(0, -20), // Move anchor to bottom
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
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Container(
                  height: sectionHeight,
                  color: Colors.white,
                  child: Scrollbar(
                    thumbVisibility: true,
                    controller: _scrollController,
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_isStartingPointChosen &&
                              _startingLocation != null) ...[
                            Text(
                              'Starting Point is chosen: $_startingLocation at $_startingStreet',
                              textAlign: TextAlign.left,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ],
                          ..._nextPoints.asMap().entries.map((entry) {
                            int index = entry.key;
                            Map<String, dynamic> point = entry.value;
                            final routeCoordinates =
                                index < _routes.length ? _routes[index] : [];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Next Point is chosen: ${point['location']} at ${point['street']}',
                                  textAlign: TextAlign.left,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                if (routeCoordinates.isNotEmpty)
                                  Text(
                                    'Route Coordinates: ${routeCoordinates.map((c) => "[${c[0]}, ${c[1]}]").join(", ")}',
                                    textAlign: TextAlign.left,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                              ],
                            );
                          }).toList(),
                          if (_selectedLocation != null &&
                              !_nextPoints.any((point) =>
                                  point['location'] == _selectedLocation)) ...[
                            Text(
                              'Next Point: Latitude: ${_selectedLocation!.latitude}, Longitude: ${_selectedLocation!.longitude}',
                              textAlign: TextAlign.left,
                              style: const TextStyle(fontSize: 14),
                            ),
                            Text(
                              'Next Street: ${_currentStreet ?? "Fetching..."}',
                              textAlign: TextAlign.left,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ] else if (_selectedLocation == null)
                            const Text(
                              'Tap on the map to select a location.',
                              style: TextStyle(fontSize: 14),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: _showExportDialog,
                child: const Text('Export'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
