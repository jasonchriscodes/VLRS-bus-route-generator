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
    // Save the current state
    _stateHistory.add({
      'nextPoints': List.from(_nextPoints),
      'routes': List.from(_routes),
      'markers': List.from(_markers),
    });
  }

  void _undo() {
    if (_stateHistory.isNotEmpty) {
      // Restore the last saved state
      final previousState = _stateHistory.removeLast();
      setState(() {
        _nextPoints =
            List<Map<String, dynamic>>.from(previousState['nextPoints']);
        _routes = List<List<List<double>>>.from(previousState['routes']);
        _markers = List<Marker>.from(previousState['markers']);
        _polylines.clear();

        // Rebuild polylines
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
      final routeCoordinates = i < _routes.length ? _routes[i] : [];
      lines.add(
          'Next Point: ${point['location']} (${point['street']}) Route Coordinates: ${routeCoordinates.map((c) => "[${c[0]}, ${c[1]}]").join(', ')}');
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
        print('Fetched coordinates: $coordinates');
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
      _routes.clear(); // Clear previous routes
      for (int i = 0; i < _nextPoints.length; i++) {
        LatLng start = i == 0
            ? _startingLocation!
            : _nextPoints[i - 1]['location'] as LatLng;
        LatLng end = _nextPoints[i]['location'] as LatLng;

        try {
          final coordinates = await _fetchRouteCoordinates(start, end);
          if (coordinates.isNotEmpty) {
            print('Route from $start to $end: $coordinates');
            _routes.add(coordinates);
          } else {
            print('No coordinates fetched for route from $start to $end.');
          }
        } catch (e) {
          print('Error fetching coordinates for route from $start to $end: $e');
        }
      }
      if (_routes.isNotEmpty) {
        print('All routes added: $_routes');
      } else {
        print('No valid routes added.');
      }
      _updateRouteFile(); // Update route file
    } else {
      print('Starting point not chosen or invalid.');
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
          if (_nextPoints.length > 0) {
            LatLng start = _nextPoints.length == 1
                ? _startingLocation!
                : _nextPoints[_nextPoints.length - 2]['location'];
            LatLng end = _nextPoints[_nextPoints.length - 1]['location'];

            _fetchRouteCoordinates(start, end).then((coordinates) {
              if (coordinates.isNotEmpty) {
                setState(() {
                  _routes.add(coordinates);
                  _polylines.add(Polyline(
                    points: coordinates.map((c) => LatLng(c[1], c[0])).toList(),
                    strokeWidth: 4.0,
                    color: Colors.blue,
                  ));
                });
              } else {
                print('No coordinates returned for the route.');
              }
            });
          }
        }
      });

      _updateRouteFile(); // Update the route file
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
      } else if (line.contains('Route Coordinates:')) {
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
        _mapController.move(_startingLocation!, 16); // Zoom level 16
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Moved to starting point!')),
        );
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Starting point is not set!')),
      );
    }
  }

  void _deletePolylines() {
    setState(() {
      _polylines.clear(); // Clear all existing polylines
    });
    print('All polylines deleted.');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All polylines have been deleted!')),
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
                    decoration: const InputDecoration(
                      labelText: 'Search for a location',
                      border: OutlineInputBorder(),
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
                  userAgentPackageName: 'com.example.app',
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
                            }).toList()
                          ],
                          if (_importedContent.isNotEmpty) ...[
                            Text(
                              'Imported Data:',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            Container(
                              height:
                                  sectionHeight, // Adjust to fit within the designated height
                              decoration: BoxDecoration(
                                border: Border.all(
                                    color: Colors.grey), // Optional border
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Scrollbar(
                                thumbVisibility: true,
                                child: SingleChildScrollView(
                                  controller: _scrollController,
                                  child: TextField(
                                    controller: TextEditingController(
                                        text: _importedContent)
                                      ..selection = TextSelection.collapsed(
                                          offset: _importedContent.length),
                                    maxLines: null, // Allows multi-line text
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      contentPadding: EdgeInsets.all(
                                          8), // Padding inside the TextField
                                    ),
                                    onChanged: (value) {
                                      setState(() {
                                        _importedContent =
                                            value; // Update content dynamically
                                      });
                                    },
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
                        onPressed: _importFile, // Import functionality
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
                        onPressed: () {
                          setState(() {
                            _polylines.clear(); // Clear all polylines
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content:
                                    Text('All polylines have been deleted')),
                          );
                        },
                        child: const Text('Delete Route'),
                      ),
                      const SizedBox(width: 10), // Space between buttons
                      ElevatedButton(
                        onPressed: _showExportDialog, // Export functionality
                        child: const Text('Export'),
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
                        onPressed: () async {
                          try {
                            print('Copy button pressed');

                            // List to hold structured coordinate data
                            final List<Map<String, double>>
                                formattedCoordinates = [];

                            // Extract Route Coordinates from _routes
                            for (final routeCoordinates in _routes) {
                              for (final coordinate in routeCoordinates) {
                                if (coordinate.length == 2) {
                                  formattedCoordinates.add({
                                    "latitude": coordinate[1],
                                    "longitude": coordinate[0],
                                  });
                                }
                              }
                            }

                            // Extract Route Coordinates from _importedContent
                            final routeRegex = RegExp(
                                r'Route Coordinates:\s*(\[.*?\](?:, \[.*?\])*)');
                            final matches =
                                routeRegex.allMatches(_importedContent);
                            for (final match in matches) {
                              final rawCoordinates = match.group(1);
                              if (rawCoordinates != null) {
                                final coordinateRegex =
                                    RegExp(r'\[(.*?),(.*?)\]');
                                for (final coordinateMatch in coordinateRegex
                                    .allMatches(rawCoordinates)) {
                                  final latitude =
                                      double.parse(coordinateMatch.group(2)!);
                                  final longitude =
                                      double.parse(coordinateMatch.group(1)!);
                                  formattedCoordinates.add({
                                    "latitude": latitude,
                                    "longitude": longitude
                                  });
                                }
                              }
                            }

                            // Convert the list to JSON
                            final String jsonCoordinates =
                                jsonEncode(formattedCoordinates);

                            // Copy to clipboard
                            Clipboard.setData(
                                ClipboardData(text: jsonCoordinates));

                            // Show confirmation message
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Route Coordinates copied to clipboard in JSON format!'),
                              ),
                            );
                          } catch (e) {
                            print('Error: $e');
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Error: ${e.toString()}')),
                            );
                          }

                          // // Copy the whole description
                          // onPressed: () {
                          //   // Build the content dynamically from the displayed widgets
                          //   final StringBuffer content = StringBuffer();

                          //   if (_selectedLocation != null) {
                          //     content.writeln('Selected Location:');
                          //     content.writeln(
                          //         'Latitude: ${_selectedLocation!.latitude}, Longitude: ${_selectedLocation!.longitude}');
                          //     content.writeln(
                          //         'Street Name: ${_currentStreet ?? "Fetching..."}');
                          //   } else if (_startingLocation == null) {
                          //     content.writeln(
                          //         'Tap on the map to select a location or import data.');
                          //   }

                          //   if (_isStartingPointChosen && _startingLocation != null) {
                          //     content.writeln('Starting Point is chosen:');
                          //     content
                          //         .writeln('$_startingLocation at $_startingStreet');
                          //   }

                          //   if (_nextPoints.isNotEmpty) {
                          //     content.writeln('Next Points:');
                          //     for (int i = 0; i < _nextPoints.length; i++) {
                          //       final point = _nextPoints[i];
                          //       final routeCoordinates =
                          //           i < _routes.length ? _routes[i] : [];
                          //       content.writeln(
                          //           'Next Point: ${point['location']} at ${point['street']}');
                          //       if (routeCoordinates.isNotEmpty) {
                          //         content.writeln(
                          //             'Route Coordinates: ${routeCoordinates.map((c) => "[${c[0]}, ${c[1]}]").join(", ")}');
                          //       }
                          //     }
                          //   }

                          //   if (_importedContent.isNotEmpty) {
                          //     content.writeln('Imported Data:');
                          //     content.writeln(_importedContent);
                          //   }

                          //   // Copy the dynamically constructed content to clipboard
                          //   Clipboard.setData(
                          //       ClipboardData(text: content.toString()));

                          //   // Show confirmation message
                          //   ScaffoldMessenger.of(context).showSnackBar(
                          //     const SnackBar(
                          //         content:
                          //             Text('Displayed content copied to clipboard!')),
                          //   );
                        },
                        child: const Text('Copy'),
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
}
