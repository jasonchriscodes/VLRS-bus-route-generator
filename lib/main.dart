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

  // Add a stack to store the history of states
  final List<Map<String, dynamic>> _stateHistory = [];

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
          i < _routes.length ? List<List<double>>.from(_routes[i]) : [];

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
        TextEditingController(text: 'busRouteData.json');

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
                var fileName = fileNameController.text.trim();
                if (fileName.isEmpty) fileName = 'busRouteData.json';
                if (!fileName.toLowerCase().endsWith('.json')) {
                  fileName = '$fileName.json';
                }
                Navigator.of(context).pop();
                _exportRouteJson(fileName);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _exportRouteJson(String fileName) async {
    try {
      if (_startingLocation == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please choose a starting point first.')),
        );
        return;
      }

      // Build ONE route object exactly like your expected schema
      final Map<String, dynamic> routeObj = {
        "starting_point": {
          "latitude": _startingLocation!.latitude,
          "longitude": _startingLocation!.longitude,
          "address": _startingStreet ?? "Unknown",
        },
        "next_points": List.generate(_nextPoints.length, (i) {
          final point = _nextPoints[i];

          // clone [lon, lat] pairs for this segment
          final List<List<double>> coords = i < _routes.length
              ? _routes[i].map<List<double>>((c) => [c[0], c[1]]).toList()
              : <List<double>>[];

          // ensure first segment starts at starting_point
          if (i == 0) {
            final sLon = _startingLocation!.longitude;
            final sLat = _startingLocation!.latitude;
            if (coords.isEmpty ||
                coords.first[0] != sLon ||
                coords.first[1] != sLat) {
              coords.insert(0, [sLon, sLat]);
            }
          } else {
            // later segments should start at previous next_point
            final prev = _nextPoints[i - 1]['location'] as LatLng;
            if (coords.isEmpty ||
                coords.first[0] != prev.longitude ||
                coords.first[1] != prev.latitude) {
              coords.insert(0, [prev.longitude, prev.latitude]);
            }
          }

          // ensure each segment ends at its next point
          final eLon = (point["location"] as LatLng).longitude;
          final eLat = (point["location"] as LatLng).latitude;
          if (coords.isEmpty ||
              coords.last[0] != eLon ||
              coords.last[1] != eLat) {
            coords.add([eLon, eLat]);
          }

          final durationMin = (point["duration"] ?? 0) / 60.0;

          return {
            "latitude": eLat,
            "longitude": eLon,
            "address": point["street"],
            "duration": "${durationMin.toStringAsFixed(1)} minutes",
            "route_coordinates": coords,
          };
        }),
      };

      // Save/append to /Documents/<fileName> as an array
      final directory = Directory('/storage/emulated/0/Documents');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final file = File('${directory.path}/$fileName');

      List<dynamic> payload = <dynamic>[];
      if (await file.exists()) {
        try {
          final existing = jsonDecode(await file.readAsString());
          if (existing is List) {
            payload = existing;
          }
        } catch (_) {
          // if invalid JSON, start fresh
          payload = <dynamic>[];
        }
      }
      payload.add(routeObj);

      await file.writeAsString(jsonEncode(payload));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported to ${file.path}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error exporting JSON: $e')),
      );
    }
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
      final directory = Directory('/storage/emulated/0/Documents');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final file = File('${directory.path}/$fileName');
      await file.writeAsString(_generateRouteFileContent());
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
    const apiKey = '5b3ce3597851110001cf624804ab2baa18644cc6b65c5829826b6117';
    final url =
        'https://api.openrouteservice.org/geocode/reverse?api_key=$apiKey&point.lat=${point.latitude}&point.lon=${point.longitude}';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _currentStreet =
              data['features'][0]['properties']['street'] ?? 'Unknown Street';
          final streetNo =
              data['features'][0]['properties']['housenumber'] ?? 'N/A';
          _currentStreet = '$streetNo $_currentStreet';
        });
      } else {
        throw Exception(
            'Failed to fetch street name. HTTP Status: ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _currentStreet = 'Error fetching street name';
      });
      print('Error fetching street name: $e');
    }
  }

  Future<Map<String, dynamic>> _fetchRouteCoordinatesWithDuration(
      LatLng start, LatLng end) async {
    final url =
        // 'http://43.226.218.99:8080/ors/v2/directions/driving-car?start=${start.longitude},${start.latitude}&end=${end.longitude},${end.latitude}&format=geojson';

        'https://api.openrouteservice.org/v2/directions/driving-car?api_key=5b3ce3597851110001cf624804ab2baa18644cc6b65c5829826b6117&start=${start.longitude},${start.latitude}&end=${end.longitude},${end.latitude}&format=geojson';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['features'] == null || data['features'].isEmpty) {
          throw Exception('No route data available.');
        }
        final coordinates =
            (data['features'][0]['geometry']['coordinates'] as List)
                .map<List<double>>(
                    (coord) => [coord[0] as double, coord[1] as double])
                .toList();
        final duration =
            data['features'][0]['properties']['segments'][0]['duration'];
        return {'coordinates': coordinates, 'duration': duration};
      } else {
        throw Exception(
            'Failed to fetch route. HTTP Status: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching route: $e');
      return {'coordinates': [], 'duration': 0};
    }
  }

  Future<void> _addRouteCoordinates() async {
    if (_isStartingPointChosen && _startingLocation != null) {
      _routes.clear();
      _polylines.clear();

      for (int i = 0; i < _nextPoints.length; i++) {
        LatLng start =
            i == 0 ? _startingLocation! : _nextPoints[i - 1]['location'];
        LatLng end = _nextPoints[i]['location'];

        try {
          final result = await _fetchRouteCoordinatesWithDuration(start, end);

          if (result['coordinates'].isNotEmpty) {
            // Add start point at the beginning of the first segment
            if (i == 0) {
              result['coordinates']
                  .insert(0, [start.longitude, start.latitude]);
            }

            // Add end point at the end of the last segment
            if (i == _nextPoints.length - 1) {
              result['coordinates'].add([end.longitude, end.latitude]);
            }

            _routes.add(result['coordinates']);
            setState(() {
              _nextPoints[i]['duration'] = result['duration'];
            });
          }
        } catch (e) {
          print('Error adding route coordinates for segment $i: $e');
        }
      }

      setState(() {
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

      await _updateRouteFile();
    }
  }

  Future<void> _fetchSuggestions(String query) async {
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
      });
      return;
    }

    // Check if the query matches a latitude, longitude pattern
    final coordinateRegex = RegExp(r'^(-?\d+(\.\d+)?),\s*(-?\d+(\.\d+)?)$');
    if (coordinateRegex.hasMatch(query)) {
      final match = coordinateRegex.firstMatch(query)!;
      final double lat = double.parse(match.group(1)!);
      final double lon = double.parse(match.group(3)!);

      // Move the map to the entered coordinates
      final LatLng location = LatLng(lat, lon);
      setState(() {
        _selectedLocation = location;
        _searchController.text = 'Lat: $lat, Lon: $lon';
        _suggestions = [];
      });

      _mapController.move(_selectedLocation!, 16); // Zoom level 16
      return; // No need to continue with API suggestions
    }

    // Existing suggestion logic using TomTom API
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
        });
        print('Error fetching suggestions: ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _suggestions = [];
      });
      print('Error fetching suggestions: $e');
    }
  }

  void _selectSuggestion(Map<String, dynamic> suggestion) async {
    final List coordinates = suggestion['coordinates'];
    final double lon = coordinates[0];
    final double lat = coordinates[1];
    final LatLng location = LatLng(lat, lon);

    setState(() {
      _selectedLocation = location;
      _searchController.text = suggestion['label'];
      _suggestions = [];
    });

    // Fetch the street name and number for the selected location
    await _fetchStreetName(location);

    // Move the map to the selected location and zoom in
    _mapController.move(_selectedLocation!, 16); // Zoom level 16
  }

  void _choosePoint() {
    if (_selectedLocation != null) {
      setState(() {
        _saveState(); // Save the current state for undo

        if (!_isStartingPointChosen) {
          // Set the starting point
          _startingLocation = _selectedLocation;
          _startingStreet = _currentStreet;
          _isStartingPointChosen = true;

          // Add marker for the starting point
          _markers.add(Marker(
            width: 40,
            height: 40,
            point: _startingLocation!,
            child: const Icon(
              Icons.circle,
              color: Colors.red,
              size: 10,
            ),
          ));
        } else {
          // Add the next point
          _nextPoints.add({
            'location': _selectedLocation!,
            'street': _currentStreet ?? 'Unknown Street',
          });

          // Add marker for the next point
          _markers.add(Marker(
            width: 40,
            height: 40,
            point: _selectedLocation!,
            child: const Icon(
              Icons.circle,
              color: Colors.red,
              size: 10,
            ),
          ));

          // Fetch route coordinates and update the polyline
          if (_nextPoints.isNotEmpty) {
            LatLng start = _nextPoints.length == 1
                ? _startingLocation!
                : _nextPoints[_nextPoints.length - 2]['location'];
            LatLng end = _nextPoints.last['location'];

            _fetchRouteCoordinatesWithDuration(start, end).then((result) {
              final coordinates = result['coordinates'];
              final duration = result['duration'];

              if (coordinates.isNotEmpty) {
                setState(() {
                  _routes.add(coordinates);
                  _polylines.add(
                    Polyline(
                      points:
                          coordinates.map((c) => LatLng(c[1], c[0])).toList(),
                      strokeWidth: 4.0,
                      color: Colors.blue,
                    ),
                  );

                  // Update the duration for the respective point
                  if (_nextPoints.isNotEmpty) {
                    _nextPoints.last['duration'] = duration;
                  }
                });
              }
            });
          }
        }
      });

      _updateRouteFile(); // Update the route file
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
  Widget build(BuildContext context) {
    final double sectionHeight =
        MediaQuery.of(context).size.height * 0.3; // Adjust section height

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
                    decoration: InputDecoration(
                      labelText: 'Search for a location',
                      border: OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(Icons.clear),
                        onPressed: () {
                          setState(() {
                            _searchController.clear(); // Clear the text field
                            _suggestions = []; // Clear search suggestions
                          });
                        },
                      ),
                    ),
                    onChanged: (value) => _fetchSuggestions(value),
                  ),
                ),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        _choosePoint();
                        _addRouteCoordinates();
                      },
                      child: Text(_isStartingPointChosen
                          ? 'Choose Next Point'
                          : 'Choose Starting Point'),
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
                    _currentStreet = null; // Reset street name for fetching
                  });
                  _fetchStreetName(point);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  // Reduce extra tile requests
                  panBuffer: 0,
                  // Use your actual Android applicationId / iOS bundle id:
                  userAgentPackageName: 'com.jason.publisher',
                  // Add a clear, contactable User-Agent (mailto is fine if no website)
                  tileProvider: NetworkTileProvider(
                    headers: {
                      'User-Agent':
                          'BusFlow-Personal/0.1 (+mailto:vlrs13542@gmail.com)',
                    },
                  ),
                ),
                PolylineLayer(
                  polylines: _polylines,
                ),
                MarkerLayer(
                  markers: _markers, // Display markers from the `_markers` list
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
              nonRotatedChildren: [
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution(
                      'OpenStreetMap contributors',
                      prependCopyright: true,
                      onTap: () => launchUrl(
                        Uri.parse('https://www.openstreetmap.org/copyright'),
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
                          if (_selectedLocation != null) ...[
                            Text(
                              'Selected Location:',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold),
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
                            Text(
                              'Starting Point is chosen:',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              '$_startingLocation at $_startingStreet',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ],
                          if (_nextPoints.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              'Next Points:',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            ..._nextPoints.asMap().entries.map((entry) {
                              int index = entry.key;
                              Map<String, dynamic> point = entry.value;
                              final routeCoordinates =
                                  index < _routes.length ? _routes[index] : [];
                              final durationMinutes =
                                  (point['duration'] ?? 0) / 60;
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Next Point: ${point['location']} at ${point['street']}',
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  Text(
                                    'Duration: ${durationMinutes.toStringAsFixed(1)} minutes',
                                    style: const TextStyle(
                                        fontSize: 14, color: Colors.black),
                                  ),
                                  if (routeCoordinates.isNotEmpty)
                                    Text(
                                      'Route Coordinates: ${routeCoordinates.map((c) => "[${c[0]}, ${c[1]}]").join(", ")}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                ],
                              );
                            }).toList()
                          ],
                          if (_importedContent.isNotEmpty) ...[
                            Text(
                              'Imported Data:',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            Container(
                              height: sectionHeight,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Scrollbar(
                                thumbVisibility: true,
                                child: SingleChildScrollView(
                                  controller: _scrollController,
                                  child: Text(
                                    _importedContent,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                              ),
                            ),
                          ]
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(width: 10), // Space between buttons
                      ElevatedButton(
                        onPressed:
                            _importJsonFile, // ← use the new JSON importer
                        child: const Text('Import'),
                      ),
                      const SizedBox(width: 10), // Space between buttons
                      ElevatedButton(
                        onPressed: _undo, // Undo functionality
                        child: const Text('Undo'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10), // Add spacing between rows
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: _deleteRoutes, // Updated method name
                        child: const Text('Delete Routes'),
                      ),

                      const SizedBox(width: 10), // Space between buttons
                      ElevatedButton(
                        onPressed: _showExportDialog, // Export functionality
                        child: const Text('Export JSON'),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: backToStart, // Move to starting point
                        child: const Text('Back To Start'),
                      ),
                      const SizedBox(width: 10), // Space between buttons
                      ElevatedButton(
                        onPressed: _downloadRouteJson,
                        child: const Text('Download JSON'),
                      ),
                    ],
                  )
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _downloadRouteJson() async {
    try {
      if (_startingLocation == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please choose a starting point first.')),
        );
        return;
      }

      // Build ONE route object in the required format
      final Map<String, dynamic> routeObj = {
        "starting_point": {
          "latitude": _startingLocation!.latitude,
          "longitude": _startingLocation!.longitude,
          "address": _startingStreet ?? "Unknown",
        },
        "next_points": List.generate(_nextPoints.length, (i) {
          final point = _nextPoints[i];
          // Clone route coordinates (lon, lat pairs)
          final List<List<double>> coords = i < _routes.length
              ? _routes[i].map<List<double>>((c) => [c[0], c[1]]).toList()
              : <List<double>>[];

          // Ensure first segment starts at starting_point
          if (i == 0) {
            final sLon = _startingLocation!.longitude;
            final sLat = _startingLocation!.latitude;
            if (coords.isEmpty ||
                coords.first[0] != sLon ||
                coords.first[1] != sLat) {
              coords.insert(0, [sLon, sLat]);
            }
          }

          // Ensure each segment ends at this next point
          final eLon = point["location"].longitude as double;
          final eLat = point["location"].latitude as double;
          if (coords.isEmpty ||
              coords.last[0] != eLon ||
              coords.last[1] != eLat) {
            coords.add([eLon, eLat]);
          }

          final durationMin = (point["duration"] ?? 0) / 60.0;

          return {
            "latitude": eLat,
            "longitude": eLon,
            "address": point["street"],
            "duration": "${durationMin.toStringAsFixed(1)} minutes",
            "route_coordinates": coords,
          };
        }),
      };

      // Prepare Documents/in.json and append (or create) array
      final dir = Directory('/storage/emulated/0/Documents');
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}/busRouteData.json');

      List<dynamic> payload = <dynamic>[];
      if (await file.exists()) {
        try {
          final existing = jsonDecode(await file.readAsString());
          if (existing is List) payload = existing;
        } catch (_) {
          // If the existing file isn’t valid JSON array, start fresh
          payload = <dynamic>[];
        }
      }
      payload.add(routeObj);

      await file.writeAsString(jsonEncode(payload));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to ${file.path}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  double _parseDurationToSeconds(dynamic value) {
    // Accepts "2.3 minutes", "2 minutes", 2.3, 2 (minutes)
    if (value == null) return 0.0;
    if (value is num) return value.toDouble() * 60.0; // already minutes
    if (value is String) {
      final m = RegExp(r'([0-9]+(?:\.[0-9]+)?)\s*minutes?')
          .firstMatch(value.toLowerCase());
      if (m != null) {
        return double.parse(m.group(1)!) * 60.0;
      }
      // If it's a plain number in a string, treat as minutes
      final n = double.tryParse(value);
      if (n != null) return n * 60.0;
    }
    return 0.0;
  }

  double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.parse(v);
    throw ArgumentError('Expected number, got $v');
  }

  Future<void> _importJsonFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null) {
        print('No file selected');
        return;
      }

      final filePath = result.files.single.path!;
      final file = File(filePath);
      final raw = await file.readAsString();

      // Keep a visible copy for the UI panel
      setState(() => _importedContent = raw);

      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) {
        throw FormatException('Top-level JSON must be a non-empty array.');
      }
      final root = decoded.first; // we use the first route object
      if (root is! Map) throw FormatException('Array item must be an object.');

      final sp = root['starting_point'];
      final nps = root['next_points'];
      if (sp == null || nps == null) {
        throw FormatException('Missing "starting_point" or "next_points".');
      }

      // Clear current state before loading
      _polylines.clear();
      _routes.clear();
      _markers.clear();
      _nextPoints.clear();

      // Starting point
      final sLat = _asDouble(sp['latitude']);
      final sLon = _asDouble(sp['longitude']);
      final sAddr = (sp['address'] ?? 'Unknown').toString();
      final startLL = LatLng(sLat, sLon);

      setState(() {
        _isStartingPointChosen = true;
        _startingLocation = startLL;
        _startingStreet = sAddr;
        _markers.add(Marker(
          width: 40,
          height: 40,
          point: startLL,
          child: const Icon(Icons.circle, color: Colors.red, size: 10),
        ));
      });

      if (nps is! List || nps.isEmpty) {
        // No next points; center map and finish
        _mapController.move(startLL, 16);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Imported starting point (no next points).')),
        );
        return;
      }

      // Build points, routes, markers, polylines
      final List<List<List<double>>> importedRoutes = [];
      final List<Map<String, dynamic>> importedNextPoints = [];

      for (var i = 0; i < nps.length; i++) {
        final np = nps[i] as Map;
        final pLat = _asDouble(np['latitude']);
        final pLon = _asDouble(np['longitude']);
        final pAddr = (np['address'] ?? 'Unknown Street').toString();
        final pDurSecs = _parseDurationToSeconds(np['duration']);

        // Build a *new* map (don’t reuse the decoded JSON map)
        importedNextPoints.add({
          'location': LatLng(pLat, pLon),
          'street': pAddr,
          'duration': pDurSecs, // store in seconds (your UI divides by 60)
        });

        // route_coordinates are [lon, lat] pairs
        final rawCoords = (np['route_coordinates'] as List?) ?? const [];
        final coords = <List<double>>[];
        for (final c in rawCoords) {
          if (c is List && c.length == 2) {
            final lon = _asDouble(c[0]);
            final lat = _asDouble(c[1]);
            coords.add([lon, lat]);
          }
        }

        // Ensure the first segment begins at starting point
        if (i == 0) {
          if (coords.isEmpty ||
              coords.first[0] != sLon ||
              coords.first[1] != sLat) {
            coords.insert(0, [sLon, sLat]);
          }
        } else {
          // For later segments, ensure it starts at the previous next_point
          final prev = importedNextPoints[i - 1]['location'] as LatLng;
          if (coords.isEmpty ||
              coords.first[0] != prev.longitude ||
              coords.first[1] != prev.latitude) {
            coords.insert(0, [prev.longitude, prev.latitude]);
          }
        }

        // Ensure each segment ends at its point
        if (coords.isEmpty ||
            coords.last[0] != pLon ||
            coords.last[1] != pLat) {
          coords.add([pLon, pLat]);
        }

        importedRoutes.add(coords);
      }

      // Apply everything to UI
      setState(() {
        _nextPoints.addAll(importedNextPoints);
        _routes.addAll(importedRoutes);

        // Add markers for each next point
        for (final np in importedNextPoints) {
          final LatLng ll = np['location'];
          _markers.add(Marker(
            width: 40,
            height: 40,
            point: ll,
            child: const Icon(Icons.circle, color: Colors.red, size: 10),
          ));
        }

        // Build polylines
        for (final route in importedRoutes) {
          _polylines.add(
            Polyline(
              points: route.map((c) => LatLng(c[1], c[0])).toList(),
              strokeWidth: 4.0,
              color: Colors.blue,
            ),
          );
        }
      });

      // Center/zoom
      _mapController.move(startLL, 14);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Imported ${importedNextPoints.length} segment(s) from JSON.')),
      );
    } catch (e) {
      print('Error importing JSON: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error importing JSON: $e')),
      );
    }
  }
}
