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

String _importedContent = '';

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

  void _copyRouteCoordinates() {
    // Format the coordinates as JSON
    final formattedCoordinates = _routes
        .expand((route) => route)
        .map((coord) => {
              "latitude": coord[1],
              "longitude": coord[0],
            })
        .toList();

    final jsonString = jsonEncode(formattedCoordinates);

    // Copy to clipboard
    Clipboard.setData(ClipboardData(text: jsonString));

    // Show confirmation message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Route coordinates copied to clipboard!')),
    );
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

  Future<void> _importFile() async {
    try {
      // Open the file picker
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'], // Allow only .txt files
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);

        // Read file content
        final content = await file.readAsString();

        // Parse content to update state
        _parseImportedContent(content);

        // Display the content in the container
        setState(() {
          _importedContent = content;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File imported successfully')),
        );
      } else {
        // User canceled file selection
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No file selected')),
        );
      }
    } catch (e) {
      print('Error importing file: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error importing file')),
      );
    }
  }

  void _parseImportedContent(String content) {
    final lines = content.split('\n'); // Split content into lines
    _startingLocation = null; // Clear starting location
    _nextPoints.clear(); // Clear next points
    _routes.clear(); // Clear routes

    Map<String, dynamic>?
        currentPoint; // Hold the current point being processed
    List<List<double>> currentRoute =
        []; // Hold the route for the current point

    for (final line in lines) {
      if (line.startsWith('Starting Point:')) {
        // Extract starting point and street
        final regex =
            RegExp(r'LatLng\(latitude:(.*?), longitude:(.*?)\) \((.*?)\)');
        final match = regex.firstMatch(line);
        if (match != null) {
          final lat = double.parse(match.group(1)!);
          final lon = double.parse(match.group(2)!);
          final street = match.group(3);
          _startingLocation = LatLng(lat, lon);
          _startingStreet = street;
          _isStartingPointChosen = true;
        }
      } else if (line.startsWith('Next Point:')) {
        // Save the previous point and its route before processing a new point
        if (currentPoint != null) {
          _nextPoints.add(currentPoint);
          _routes.add(currentRoute);
        }

        // Extract next point and street
        final regex =
            RegExp(r'LatLng\(latitude:(.*?), longitude:(.*?)\) \((.*?)\)');
        final match = regex.firstMatch(line);
        if (match != null) {
          final lat = double.parse(match.group(1)!);
          final lon = double.parse(match.group(2)!);
          final street = match.group(3);
          currentPoint = {
            'location': LatLng(lat, lon),
            'street': street,
          };
          currentRoute = []; // Reset current route for the new point
        }
      } else if (line.contains('Route:')) {
        // Extract route coordinates
        final regex = RegExp(r'\[(.*?)\]');
        final matches = regex.allMatches(line);
        final route = matches.map((match) {
          final coords = match.group(1)!.split(', ').map(double.parse).toList();
          return coords;
        }).toList();

        currentRoute = route; // Assign the route to the current point
      }
    }

    // Add the last point and its route after the loop
    if (currentPoint != null) {
      _nextPoints.add(currentPoint);
      _routes.add(currentRoute);
    }

    // Update _importedContent to display all imported data
    final List<String> importedLines = [];
    if (_startingLocation != null) {
      importedLines.add(
          'Starting Point: LatLng(latitude:${_startingLocation!.latitude}, longitude:${_startingLocation!.longitude}) ($_startingStreet)');
    }

    for (int i = 0; i < _nextPoints.length; i++) {
      final point = _nextPoints[i];
      final routeCoordinates = i < _routes.length ? _routes[i] : [];
      importedLines.add(
          'Next Point: LatLng(latitude:${point['location'].latitude}, longitude:${point['location'].longitude}) (${point['street']}) Route: ${routeCoordinates.map((c) => "[${c[0]}, ${c[1]}]").join(", ")}');
    }

    setState(() {
      _importedContent =
          importedLines.join('\n'); // Update imported content for display
    });
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
                    _currentStreet = null; // Reset street name for fetching
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
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Next Point: ${point['location']} at ${point['street']}',
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  if (routeCoordinates.isNotEmpty)
                                    Text(
                                      'Route Coordinates: ${routeCoordinates.map((c) => "[${c[0]}, ${c[1]}]").join(", ")}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                ],
                              );
                            }).toList(),
                          ],
                          if (_importedContent.isNotEmpty) ...[
                            Text(
                              'Imported Data:',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              _importedContent,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                children: [
                  ElevatedButton(
                    onPressed: _importFile,
                    child: const Text('Import'),
                  ),
                  const SizedBox(height: 10), // Add spacing between buttons
                  ElevatedButton(
                    onPressed: _showExportDialog,
                    child: const Text('Export'),
                  ),
                  const SizedBox(height: 10), // Add spacing between buttons
                  ElevatedButton(
                    // onPressed: _copyRouteCoordinates,
                    onPressed: () {
                      // Build the content dynamically from the displayed widgets
                      final StringBuffer content = StringBuffer();

                      if (_selectedLocation != null) {
                        content.writeln('Selected Location:');
                        content.writeln(
                            'Latitude: ${_selectedLocation!.latitude}, Longitude: ${_selectedLocation!.longitude}');
                        content.writeln(
                            'Street Name: ${_currentStreet ?? "Fetching..."}');
                      } else if (_startingLocation == null) {
                        content.writeln(
                            'Tap on the map to select a location or import data.');
                      }

                      if (_isStartingPointChosen && _startingLocation != null) {
                        content.writeln('Starting Point is chosen:');
                        content
                            .writeln('$_startingLocation at $_startingStreet');
                      }

                      if (_nextPoints.isNotEmpty) {
                        content.writeln('Next Points:');
                        for (int i = 0; i < _nextPoints.length; i++) {
                          final point = _nextPoints[i];
                          final routeCoordinates =
                              i < _routes.length ? _routes[i] : [];
                          content.writeln(
                              'Next Point: ${point['location']} at ${point['street']}');
                          if (routeCoordinates.isNotEmpty) {
                            content.writeln(
                                'Route Coordinates: ${routeCoordinates.map((c) => "[${c[0]}, ${c[1]}]").join(", ")}');
                          }
                        }
                      }

                      if (_importedContent.isNotEmpty) {
                        content.writeln('Imported Data:');
                        content.writeln(_importedContent);
                      }

                      // Copy the dynamically constructed content to clipboard
                      Clipboard.setData(
                          ClipboardData(text: content.toString()));

                      // Show confirmation message
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content:
                                Text('Displayed content copied to clipboard!')),
                      );
                    },
                    child: const Text('Copy'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
