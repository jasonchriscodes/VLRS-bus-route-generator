import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

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
  LatLng _currentLocation = LatLng(-36.8485, 174.7633); // Auckland, New Zealand
  LatLng? _selectedLocation;
  LatLng? _startingLocation;
  String? _currentStreet;
  String? _startingStreet;
  bool _isStartingPointChosen = false;
  List<Map<String, dynamic>> _nextPoints = []; // Store next points and details

  List<Map<String, dynamic>> _suggestions =
      []; // Store suggestions with coordinates
  final TextEditingController _searchController = TextEditingController();

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
      }
    } catch (e) {
      setState(() {
        _suggestions = [];
      });
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

    // Move map to the selected location and zoom in
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Map Viewer')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: 'Search for a location',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => _fetchSuggestions(value),
                ),
                if (_suggestions.isNotEmpty)
                  ListView.builder(
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
              ],
            ),
          ),
          ElevatedButton(
            onPressed: _choosePoint,
            child: Text(_isStartingPointChosen
                ? 'Choose Next Point'
                : 'Choose Starting Point'),
          ),
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                center: _currentLocation,
                zoom: 14,
                maxZoom: 18,
                minZoom: 5,
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
          Container(
            padding: const EdgeInsets.all(10),
            color: Colors.white,
            child: Column(
              children: [
                if (_isStartingPointChosen && _startingLocation != null) ...[
                  Text(
                    'Starting Point is chosen: $_startingLocation at $_startingStreet',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                ],
                ..._nextPoints.map((point) => Text(
                      'Next Point is chosen: ${point['location']} at ${point['street']}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16),
                    )),
                if (_selectedLocation != null &&
                    !_nextPoints.any(
                        (point) => point['location'] == _selectedLocation)) ...[
                  Text(
                    'Next Point: Latitude: ${_selectedLocation!.latitude}, Longitude: ${_selectedLocation!.longitude}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16),
                  ),
                  Text(
                    'Next Street: ${_currentStreet ?? "Fetching..."}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16),
                  ),
                ] else if (_selectedLocation == null)
                  const Text(
                    'Tap on the map to select a location.',
                    style: TextStyle(fontSize: 16),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
