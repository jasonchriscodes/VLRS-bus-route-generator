import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:open_route_service/open_route_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Bus Stop Generator'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  Map<String, List<Map<String, double>>> routePoints = {};
  int index = 1;
  final startLatController = TextEditingController(text: '-36.780258');
  final startLngController = TextEditingController(text: '174.992506');
  final endLatController = TextEditingController(text: '-36.781447');
  final endLngController = TextEditingController(text: '175.006983');
  final indexController = TextEditingController();
  final formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
  }

  Future<void> generateRoute({
    required String startLatitude,
    required String startLongitude,
    required String endLatitude,
    required String endLongitude,
  }) async {
    // Initialize the openrouteservice with your API key.
    final OpenRouteService client = OpenRouteService(
        apiKey: '5b3ce3597851110001cf6248388ec6c4e06043d3b87eb77a95a06a02');
    double startLat = double.parse(startLatitude);
    double startLng = double.parse(startLongitude);
    double endLat = double.parse(endLatitude);
    double endLng = double.parse(endLongitude);

    final List<ORSCoordinate> routeCoordinates =
        await client.directionsRouteCoordsGet(
      startCoordinate: ORSCoordinate(latitude: startLat, longitude: startLng),
      endCoordinate: ORSCoordinate(latitude: endLat, longitude: endLng),
    );

    final List<LatLng> routePointsList = routeCoordinates
        .map((coordinate) => LatLng(coordinate.latitude, coordinate.longitude))
        .toList();

    List<Map<String, double>> data = [];
    data.add({'latitude': startLat, 'longitude': startLng}); // Add start point

    for (var element in routePointsList) {
      data.add({'latitude': element.latitude, 'longitude': element.longitude});
    }

    data.add({'latitude': endLat, 'longitude': endLng}); // Add end point

    setState(() {
      if (routePoints['$index'] == null) {
        routePoints['$index'] = data;
      } else {
        routePoints['$index']!.addAll(data);
      }
      index++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Form(
        key: formKey,
        child: Container(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              children: [
                _buildTextForm(
                  controller: startLatController,
                  labelText: 'Start Latitude',
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a valid latitude';
                    }
                    if (double.tryParse(value) == null) {
                      return 'Please enter a valid latitude';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),
                _buildTextForm(
                  controller: startLngController,
                  labelText: 'Start Longitude',
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a valid longitude';
                    }
                    if (double.tryParse(value) == null) {
                      return 'Please enter a valid longitude';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),
                _buildTextForm(
                  controller: endLatController,
                  labelText: 'End Latitude',
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a valid latitude';
                    }
                    if (double.tryParse(value) == null) {
                      return 'Please enter a valid latitude';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),
                _buildTextForm(
                  controller: endLngController,
                  labelText: 'End Longitude',
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a valid longitude';
                    }
                    if (double.tryParse(value) == null) {
                      return 'Please enter a valid longitude';
                    }
                    return null;
                  },
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: FutureBuilder(
                    future: Future.value(routePoints),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
                      }
                      if (snapshot.hasError) {
                        return const Center(
                          child: Text('Error'),
                        );
                      }
                      if (snapshot.data!.isEmpty) {
                        return const Center(
                          child: Text('No Route Points Found'),
                        );
                      }
                      return SelectableText(
                        snapshot.data.toString(),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (formKey.currentState!.validate()) {
            generateRoute(
              startLatitude: startLatController.text,
              startLongitude: startLngController.text,
              endLatitude: endLatController.text,
              endLongitude: endLngController.text,
            );
          }
        },
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }

  TextFormField _buildTextForm({
    TextEditingController? controller,
    String? labelText,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: labelText,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
      ),
      validator: validator,
    );
  }
}
