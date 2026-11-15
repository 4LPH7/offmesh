import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import 'controls_page.dart';
import 'messages_page.dart';
import 'unit_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller, this.onPanicWipe});

  final ChatController controller;
  final Future<void> Function()? onPanicWipe;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedTab = 0;

  static const _titles = ['Messages', 'Unit', 'Controls'];

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('OffMesh'),
              Text(
                _titles[_selectedTab],
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: IndexedStack(
                index: _selectedTab,
                children: [
                  MessagesPage(
                    controller: controller,
                    onOpenUnit: () => setState(() => _selectedTab = 1),
                  ),
                  UnitPage(controller: controller),
                  ControlsPage(
                    controller: controller,
                    onPanicWipe: widget.onPanicWipe,
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedTab,
          onDestinationSelected: (index) =>
              setState(() => _selectedTab = index),
          destinations: const [
            NavigationDestination(
              key: Key('home-tab-messages'),
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Messages',
            ),
            NavigationDestination(
              key: Key('home-tab-unit'),
              icon: Icon(Icons.group_outlined),
              selectedIcon: Icon(Icons.group),
              label: 'Unit',
            ),
            NavigationDestination(
              key: Key('home-tab-controls'),
              icon: Icon(Icons.tune),
              label: 'Controls',
            ),
          ],
        ),
      ),
    );
  }
}
