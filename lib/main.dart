import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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
  LatLng? _startingCoordinates;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Map Viewer')),
      body: Column(
        children: [
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
                    _startingCoordinates = point;
                  });
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.app',
                ),
                if (_startingCoordinates != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        width: 40,
                        height: 40,
                        point: _startingCoordinates!,
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
                if (_startingCoordinates != null)
                  Text(
                    'Starting Coordinate:\nLatitude: ${_startingCoordinates!.latitude}, Longitude: ${_startingCoordinates!.longitude}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16),
                  )
                else
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
