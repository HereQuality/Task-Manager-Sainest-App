import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dashboard_screen.dart';
import 'tasks_screen.dart';
import 'calendar_screen.dart';
import 'profile_screen.dart';
import '../widgets/add_task_sheet.dart';

/// Bottom-nav shell every logged-in user lands on. Four real tabs --
/// Home, Tasks, Calendar, Profile -- plus a middle "+" slot that isn't a
/// tab at all: tapping it opens the "Add task" sheet on top of whatever
/// tab is currently showing, then returns to that same tab (so the "+"
/// never becomes the "selected" destination). Tickets moved to the
/// Profile menu to free up that slot; Notifications/Settings are already
/// one tap deeper the same way (bell icon / Profile menu).
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _pageIndex = 0;

  final _pages = const [
    DashboardScreen(),
    TasksScreen(),
    CalendarScreen(),
    ProfileScreen(),
  ];

  // Nav bar has 5 slots (Home, Tasks, +, Calendar, Profile) but only 4
  // correspond to a real page -- slot 2 is the "+" action. These two
  // helpers translate between "which page is showing" (_pageIndex, 0-3)
  // and "which nav slot is highlighted" (0,1,3,4 -- never 2).
  int _navIndexForPage(int pageIndex) => pageIndex < 2 ? pageIndex : pageIndex + 1;

  void _onDestinationSelected(int navIndex) {
    if (navIndex == 2) {
      showAddTaskSheet(context, ref);
      return;
    }
    setState(() => _pageIndex = navIndex < 2 ? navIndex : navIndex - 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _pageIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navIndexForPage(_pageIndex),
        onDestinationSelected: _onDestinationSelected,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.checklist_outlined), selectedIcon: Icon(Icons.checklist_rounded), label: 'Tasks'),
          NavigationDestination(icon: Icon(Icons.add_circle_outline_rounded), selectedIcon: Icon(Icons.add_circle_rounded), label: 'Add'),
          NavigationDestination(icon: Icon(Icons.calendar_today_outlined), selectedIcon: Icon(Icons.calendar_today_rounded), label: 'Calendar'),
          NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'Profile'),
        ],
      ),
    );
  }
}
